import Foundation

/// Per-app executor inspired by Microsoft UFO's AppAgent.
///
/// Receives a scoped subtask + tool subset + blackboard context and runs its own
/// mini agent loop. The HostAgent (`SubAgentCoordinator`) spawns one of these for
/// each subtask in a decomposed plan.
///
/// Ported from Executer with two changes:
/// - **`onStateChange: @MainActor @escaping (InputBarState) -> Void`** → optional
///   ``AgentDisplayStateSink``. The sink emits ``AgentDisplayEvent`` cases.
/// - **`AgentLoop.executeToolCalls(...)`** call uses the package's actor-based
///   AgentLoop static helper (already actor-friendly).
public enum AppAgent {

    // MARK: - Config

    public struct Config: Sendable {
        public let subtaskId: String
        public let subtaskDescription: String
        public let targetApp: String?
        public let toolHints: [String]
        public let maxIterations: Int
        public let maxTokens: Int
        public let hostMessage: String?

        public init(
            subtaskId: String,
            subtaskDescription: String,
            targetApp: String?,
            toolHints: [String],
            maxIterations: Int = 8,
            maxTokens: Int = 2048,
            hostMessage: String? = nil
        ) {
            self.subtaskId = subtaskId
            self.subtaskDescription = subtaskDescription
            self.targetApp = targetApp
            self.toolHints = toolHints
            self.maxIterations = maxIterations
            self.maxTokens = maxTokens
            self.hostMessage = hostMessage
        }

        public static let `default` = Config(
            subtaskId: "0",
            subtaskDescription: "",
            targetApp: nil,
            toolHints: [],
            maxIterations: 8,
            maxTokens: 2048,
            hostMessage: nil
        )
    }

    public struct Result: Sendable {
        public let subtaskId: String
        public let output: String
        public let sharedData: [String: String]
        public let toolsUsed: [String]
        public let success: Bool
    }

    // MARK: - App-specific tool scoping

    private static let appToolMapping: [String: [ToolCategory]] = [
        "Pages": [.files, .fileContent, .clipboard, .keyboard, .cursor],
        "Numbers": [.files, .fileContent, .clipboard, .keyboard, .cursor],
        "Keynote": [.files, .fileContent, .documents, .clipboard, .keyboard, .cursor],
        "Microsoft Word": [.files, .fileContent, .documents, .clipboard, .keyboard, .cursor],
        "Microsoft Excel": [.files, .fileContent, .documents, .clipboard, .keyboard, .cursor],
        "Microsoft PowerPoint": [.files, .fileContent, .documents, .clipboard, .keyboard, .cursor],
        "TextEdit": [.files, .fileContent, .clipboard, .keyboard, .cursor],
        "Notes": [.productivity, .clipboard, .keyboard, .cursor],
        "Safari": [.web, .webContent, .browser, .clipboard],
        "Google Chrome": [.web, .webContent, .browser, .clipboard],
        "Arc": [.web, .webContent, .browser, .clipboard],
        "Firefox": [.web, .webContent, .browser, .clipboard],
        "Messages": [.messaging, .clipboard],
        "WeChat": [.messaging, .clipboard],
        "Mail": [.productivity, .clipboard, .keyboard, .cursor],
        "Slack": [.messaging, .clipboard, .keyboard, .cursor],
        "Terminal": [.terminal, .files, .fileContent, .fileSearch],
        "Xcode": [.terminal, .files, .fileContent, .fileSearch, .clipboard],
        "Visual Studio Code": [.terminal, .files, .fileContent, .fileSearch, .clipboard],
        "Finder": [.files, .fileSearch, .windows],
        "System Preferences": [.systemSettings],
        "System Settings": [.systemSettings],
    ]

    private static let commonCategories: [ToolCategory] = [
        .appControl, .clipboard, .notifications, .memory, .screenshot
    ]

    // MARK: - Execution

    /// Run the AppAgent's scoped agent loop for a single subtask.
    public static func execute(
        config: Config,
        blackboard: TaskBlackboard,
        service: LLMServiceProtocol,
        registry: ToolRegistry,
        displayStateSink: AgentDisplayStateSink? = nil,
        progressSink: AgentProgressSink? = nil,
        trace: AgentTrace? = nil
    ) async -> Result {
        let startTime = CFAbsoluteTimeGetCurrent()
        var toolsUsed: [String] = []
        var sharedDataCollected: [String: String] = [:]

        let blackboardContext = await blackboard.contextForSubTask(id: config.subtaskId)
        await blackboard.markRunning(id: config.subtaskId)

        let tools = scopeTools(
            targetApp: config.targetApp,
            toolHints: config.toolHints,
            registry: registry
        )

        let systemPrompt = buildSystemPrompt(config: config, blackboardContext: blackboardContext)

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: config.subtaskDescription)
        ]

        var finalText = ""

        for iteration in 0..<config.maxIterations {
            if Task.isCancelled { break }

            let label = config.targetApp ?? "Sub-agent"
            await displayStateSink?.emit(.executing(
                toolName: "\(label): step \(iteration + 1)",
                step: iteration + 1,
                total: config.maxIterations
            ))

            guard let response = try? await service.sendChatRequest(
                messages: messages,
                tools: tools,
                maxTokens: config.maxTokens
            ) else {
                finalText = "Error: LLM request failed"
                break
            }

            trace?.append(TraceEntry(kind: .llmCall(
                messageCount: messages.count,
                responseLength: response.text?.count ?? 0,
                hasToolCalls: response.toolCalls != nil && !(response.toolCalls?.isEmpty ?? true),
                reasoning: response.rawMessage.reasoning_content
            )))

            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                finalText = response.text ?? "Done."
                break
            }

            messages.append(response.rawMessage)

            let results = await AgentLoop.executeToolCalls(
                toolCalls,
                registry: registry,
                iteration: iteration,
                maxIterations: config.maxIterations,
                command: config.subtaskDescription,
                displayStateSink: displayStateSink,
                progressSink: progressSink,
                trace: trace
            )

            for r in results {
                messages.append(ChatMessage(
                    role: "tool",
                    content: r.result,
                    tool_call_id: r.toolCallId
                ))
                toolsUsed.append(r.toolName)

                extractSharedData(toolName: r.toolName, result: r.result, into: &sharedDataCollected)
            }

            for call in toolCalls {
                let resultText = results.first(where: { $0.toolCallId == call.id })?.result ?? ""
                await blackboard.recordAction(
                    agent: config.targetApp ?? "app_agent",
                    action: call.function.name,
                    result: String(resultText.prefix(200))
                )
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let success = !finalText.lowercased().contains("error")

        if success {
            await blackboard.completeSubTask(
                id: config.subtaskId,
                result: finalText,
                sharedData: sharedDataCollected
            )
        } else {
            await blackboard.failSubTask(id: config.subtaskId, reason: finalText)
        }

        trace?.append(TraceEntry(kind: .subAgentComplete(
            id: config.subtaskId,
            app: config.targetApp,
            durationMs: duration * 1000,
            success: success
        )))

        print("[AppAgent] \(config.targetApp ?? "agent") completed in \(String(format: "%.1f", duration))s — \(toolsUsed.count) tool calls")

        return Result(
            subtaskId: config.subtaskId,
            output: finalText,
            sharedData: sharedDataCollected,
            toolsUsed: toolsUsed,
            success: success
        )
    }

    // MARK: - Tool Scoping

    private static func scopeTools(
        targetApp: String?,
        toolHints: [String],
        registry: ToolRegistry
    ) -> [[String: AnyCodable]] {
        var categories = Set(commonCategories)

        if let app = targetApp, let appCats = appToolMapping[app] {
            categories.formUnion(appCats)
        }

        for hint in toolHints {
            if let cat = ToolCategory(rawValue: hint) {
                categories.insert(cat)
            }
        }

        if targetApp == nil {
            categories.formUnion([.files, .fileContent, .web, .webContent, .terminal, .keyboard, .cursor])
        }

        let schemas = registry.filteredToolDefinitions(categories: categories)
        print("[AppAgent] Scoped to \(schemas.count) tools for \(targetApp ?? "general")")
        return schemas
    }

    // MARK: - System Prompt

    private static func buildSystemPrompt(config: Config, blackboardContext: String) -> String {
        var prompt = """
        You are an AppAgent — a focused executor for a specific subtask. \
        Complete your assigned subtask efficiently using the available tools. \
        Do not attempt work outside your subtask scope.

        \(blackboardContext)
        """

        if let app = config.targetApp {
            prompt += "\n\nYou are working in \(app). Use tools appropriate for this application."
        }

        if let hostMsg = config.hostMessage {
            prompt += "\n\nHost agent tips: \(hostMsg)"
        }

        return prompt
    }

    // MARK: - Shared Data Extraction

    private static func extractSharedData(toolName: String, result: String, into data: inout [String: String]) {
        switch toolName {
        case "get_clipboard_text", "set_clipboard_text":
            if result.count < 2000 {
                data["clipboard_content"] = result
            }
        case "read_file", "read_document":
            data["last_read_content"] = String(result.prefix(1000))
        case "find_files":
            data["found_files"] = result
        case "browser_extract", "browser_task":
            data["browser_result"] = String(result.prefix(1500))
        case "capture_screen", "capture_window":
            data["last_screenshot_path"] = result
        case "search_web", "instant_search":
            data["search_results"] = String(result.prefix(1500))
        default:
            break
        }
    }
}
