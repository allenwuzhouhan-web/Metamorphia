import Foundation

/// Saves conversation state at key decision points, enabling users to:
/// - Undo the last action or group of actions
/// - Branch the conversation to try a different approach
/// - Rewind to a previous checkpoint and start fresh
///
/// Works by snapshotting the message array and tracking reversible operations.
/// File-level undo is handled by recording inverse operations.
///
/// Note: the `UndoLastActionTool` is deferred to a later phase because it
/// invokes `ToolRegistry.shared.execute(...)` which lives in the app target.
/// `ListCheckpointsTool` is included here since it only reads middleware storage.
public final class ConversationBranchManager: AgentMiddleware {
    public let name = "ConversationBranch"

    public init() {}

    // MARK: - Storage Keys

    private static let checkpointsKey = "Branch.checkpoints"
    private static let undoStackKey = "Branch.undoStack"
    private static let branchesKey = "Branch.branches"

    // MARK: - Models

    public struct Checkpoint: Codable, Sendable {
        public let id: String
        public let iteration: Int
        public let timestamp: Date
        public let messageCount: Int
        public let description: String
        /// Serialized messages at this point.
        public let messagesSnapshot: Data?

        public static func create(
            iteration: Int,
            messages: [ChatMessage],
            description: String
        ) -> Checkpoint {
            let data = try? JSONEncoder().encode(messages)
            return Checkpoint(
                id: UUID().uuidString,
                iteration: iteration,
                timestamp: Date(),
                messageCount: messages.count,
                description: description,
                messagesSnapshot: data
            )
        }
    }

    public struct UndoableAction: Codable, Sendable {
        public let toolName: String
        public let arguments: String
        public let result: String
        public let inverseAction: InverseAction?
        public let iteration: Int

        public struct InverseAction: Codable, Sendable {
            public let toolName: String
            public let arguments: String
            public let description: String
        }
    }

    public struct Branch: Codable, Sendable {
        public let id: String
        public let name: String
        public let checkpointId: String
        public let createdAt: Date
    }

    // MARK: - Inverse Action Map

    private static func inverseAction(toolName: String, arguments: String, result: String) -> UndoableAction.InverseAction? {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch toolName {
        case "file_operation":
            let action = args["action"] as? String ?? ""
            switch action {
            case "move":
                if let source = args["path"] as? String, let dest = args["destination"] as? String {
                    let inverseArgs = try? JSONSerialization.data(
                        withJSONObject: ["action": "move", "path": dest, "destination": source]
                    )
                    return UndoableAction.InverseAction(
                        toolName: "file_operation",
                        arguments: inverseArgs.flatMap { String(data: $0, encoding: .utf8) } ?? "{}",
                        description: "Move back to original location"
                    )
                }
            case "rename":
                if let path = args["path"] as? String, let newName = args["new_name"] as? String {
                    let dir = (path as NSString).deletingLastPathComponent
                    let oldName = (path as NSString).lastPathComponent
                    let newPath = (dir as NSString).appendingPathComponent(newName)
                    let inverseArgs = try? JSONSerialization.data(
                        withJSONObject: ["action": "rename", "path": newPath, "new_name": oldName]
                    )
                    return UndoableAction.InverseAction(
                        toolName: "file_operation",
                        arguments: inverseArgs.flatMap { String(data: $0, encoding: .utf8) } ?? "{}",
                        description: "Rename back to '\(oldName)'"
                    )
                }
            default:
                return nil
            }

        default:
            return nil
        }

        return nil
    }

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        if ctx.iteration == 0 {
            ctx.storage[Self.checkpointsKey] = [Checkpoint]()
            ctx.storage[Self.undoStackKey] = [UndoableAction]()
            ctx.storage[Self.branchesKey] = [Branch]()

            let checkpoint = Checkpoint.create(
                iteration: 0,
                messages: ctx.messages,
                description: "Session start"
            )
            ctx.storage[Self.checkpointsKey] = [checkpoint]
        }
        return .continue
    }

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        var undoStack = ctx.storage[Self.undoStackKey] as? [UndoableAction] ?? []
        var checkpoints = ctx.storage[Self.checkpointsKey] as? [Checkpoint] ?? []

        for (call, result) in zip(toolCalls, results) {
            let inverse = Self.inverseAction(
                toolName: call.function.name,
                arguments: call.function.arguments,
                result: result.result
            )

            undoStack.append(UndoableAction(
                toolName: call.function.name,
                arguments: call.function.arguments,
                result: String(result.result.prefix(500)),
                inverseAction: inverse,
                iteration: ctx.iteration
            ))
        }

        let significantTools: Set<String> = [
            "file_operation", "create_presentation", "create_word_document",
            "notion_create_page", "create_calendar_event", "run_script",
            "ffmpeg_edit_video", "create_video", "batch_rename_files",
        ]
        let hasSignificantAction = toolCalls.contains { significantTools.contains($0.function.name) }

        if ctx.iteration % 5 == 4 || hasSignificantAction {
            let desc = toolCalls.map { $0.function.name }.joined(separator: ", ")
            let checkpoint = Checkpoint.create(
                iteration: ctx.iteration,
                messages: ctx.messages,
                description: "After: \(String(desc.prefix(100)))"
            )
            checkpoints.append(checkpoint)

            if checkpoints.count > 10 {
                checkpoints = Array(checkpoints.suffix(10))
            }
        }

        if undoStack.count > 50 {
            undoStack = Array(undoStack.suffix(50))
        }

        ctx.storage[Self.undoStackKey] = undoStack
        ctx.storage[Self.checkpointsKey] = checkpoints
        return .continue
    }

    // MARK: - Public API

    public static func undoStack(from storage: [String: Any]) -> [UndoableAction] {
        storage[undoStackKey] as? [UndoableAction] ?? []
    }

    public static func checkpoints(from storage: [String: Any]) -> [Checkpoint] {
        storage[checkpointsKey] as? [Checkpoint] ?? []
    }

    public static func lastUndoableAction(from storage: [String: Any]) -> UndoableAction? {
        (storage[undoStackKey] as? [UndoableAction])?.last(where: { $0.inverseAction != nil })
    }
}

// MARK: - List Checkpoints Tool

/// LLM-callable tool to list available conversation checkpoints.
public struct ListCheckpointsTool: ToolDefinition {
    public let name = "list_checkpoints"
    public let description = "List available conversation checkpoints. Checkpoints are saved at key decision points and can be used to understand the execution history."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    public var storageProvider: (@Sendable () -> [String: Any])?

    public init(storageProvider: (@Sendable () -> [String: Any])? = nil) {
        self.storageProvider = storageProvider
    }

    public func execute(arguments: String) async throws -> String {
        guard let storage = storageProvider?() else {
            return "No checkpoints available."
        }

        let checkpoints = ConversationBranchManager.checkpoints(from: storage)
        if checkpoints.isEmpty {
            return "No checkpoints have been created yet."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        var result = "Conversation Checkpoints:\n\n"
        for (i, cp) in checkpoints.enumerated() {
            result += "\(i + 1). [\(formatter.string(from: cp.timestamp))] Iteration \(cp.iteration) — \(cp.description) (\(cp.messageCount) messages)\n"
        }

        let undoStack = ConversationBranchManager.undoStack(from: storage)
        let reversible = undoStack.filter { $0.inverseAction != nil }.count
        result += "\nUndo stack: \(undoStack.count) actions (\(reversible) reversible)"

        return result
    }
}
