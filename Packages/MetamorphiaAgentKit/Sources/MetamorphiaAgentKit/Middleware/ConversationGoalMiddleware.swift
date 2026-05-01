import Foundation

/// Tracks the evolving conversation goal across agent loop iterations.
///
/// As the LLM executes tools over multiple iterations, context can be lost — especially
/// after pruning. This middleware maintains a lightweight goal model that:
///   1. Extracts the initial goal from the user's command
///   2. Tracks accomplished steps and remaining work
///   3. Injects a brief goal summary before each LLM call
///   4. Detects goal drift (topic changes vs. follow-ups)
public final class ConversationGoalMiddleware: AgentMiddleware {
    public let name = "ConversationGoal"

    public init() {}

    // MARK: - Storage Keys

    private static let goalKey = "ConversationGoal.goal"
    private static let stepsKey = "ConversationGoal.steps"
    private static let phaseKey = "ConversationGoal.phase"
    private static let keywordsKey = "ConversationGoal.keywords"

    // MARK: - Goal Model

    public struct GoalState {
        public var summary: String
        public var completedSteps: [String]
        public var activeStep: String?
        public var phase: Phase
        public var coreKeywords: Set<String>

        public enum Phase: String {
            case understanding
            case executing
            case refining
            case complete
        }

        public func promptSection() -> String {
            var lines = ["## Conversation Goal"]
            lines.append("**Goal:** \(summary)")

            if !completedSteps.isEmpty {
                let recent = completedSteps.suffix(5)
                lines.append("**Done:** \(recent.joined(separator: " → "))")
            }

            if let active = activeStep {
                lines.append("**Now:** \(active)")
            }

            if phase == .refining {
                lines.append("**Phase:** Refining — focus on polish and user satisfaction.")
            }

            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        guard ctx.iteration > 0 else {
            let goal = extractGoal(from: ctx.command)
            let state = GoalState(
                summary: goal.summary,
                completedSteps: [],
                activeStep: nil,
                phase: .understanding,
                coreKeywords: goal.keywords
            )
            saveState(state, to: ctx)
            return .continue
        }

        guard let state = loadState(from: ctx) else { return .continue }

        let section = state.promptSection()
        let goalMessage = ChatMessage(role: "user", content: "[SYSTEM CONTEXT]\n\(section)")

        if let lastUserIdx = ctx.messages.lastIndex(where: { $0.role == "user" }) {
            ctx.messages.insert(goalMessage, at: lastUserIdx)
        }

        return .continue
    }

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        guard var state = loadState(from: ctx) else { return .continue }

        for (call, result) in zip(toolCalls, results) {
            let toolName = call.function.name
            let succeeded = !result.result.lowercased().contains("error")
                         && !result.result.lowercased().contains("failed")

            if succeeded {
                let step = summarizeToolAction(toolName: toolName, args: call.function.arguments)
                state.completedSteps.append(step)
            }
        }

        if state.completedSteps.count >= 1 && state.phase == .understanding {
            state.phase = .executing
        }

        if state.completedSteps.count >= 3 {
            let lastTools = toolCalls.map { $0.function.name }
            let refinementTools = Set(["edit_file", "ffmpeg_edit_video", "run_script"])
            if lastTools.contains(where: { refinementTools.contains($0) }) {
                state.phase = .refining
            }
        }

        if state.completedSteps.count > 10 {
            let summary = state.completedSteps.prefix(5).joined(separator: ", ")
            state.completedSteps = ["Earlier: \(summary)"] + Array(state.completedSteps.suffix(5))
        }

        saveState(state, to: ctx)
        return .continue
    }

    // MARK: - Goal Extraction

    private func extractGoal(from command: String) -> (summary: String, keywords: Set<String>) {
        let summary: String
        if command.count <= 120 {
            summary = command
        } else {
            let separators = CharacterSet(charactersIn: ".!?\n")
            let firstClause = command.components(separatedBy: separators).first ?? command
            summary = String(firstClause.prefix(120))
        }

        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "can", "shall", "to", "of", "in", "for",
            "on", "with", "at", "by", "from", "as", "into", "through", "during",
            "before", "after", "above", "below", "between", "and", "but", "or",
            "not", "no", "so", "if", "then", "than", "too", "very", "just",
            "about", "up", "out", "that", "this", "it", "its", "my", "your",
            "me", "i", "we", "you", "he", "she", "they", "them", "his", "her",
            "our", "their", "what", "which", "who", "when", "where", "how", "all",
            "each", "every", "both", "few", "more", "most", "some", "any", "please",
        ]
        let words = command.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
        let keywords = Set(words.prefix(15))

        return (summary, keywords)
    }

    private func summarizeToolAction(toolName: String, args: String) -> String {
        let detail: String
        if let data = args.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let identifiers = ["path", "file_path", "topic", "title", "name", "query", "url", "text"]
            let match = identifiers.lazy.compactMap { key -> String? in
                guard let val = dict[key] as? String else { return nil }
                return String(val.prefix(40))
            }.first
            detail = match ?? ""
        } else {
            detail = ""
        }

        let actionMap: [String: String] = [
            "create_presentation": "Created presentation",
            "create_word_document": "Created document",
            "create_spreadsheet": "Created spreadsheet",
            "create_video": "Created video",
            "quick_video": "Created video",
            "create_podcast": "Created podcast",
            "create_audio": "Created audio",
            "create_blender_model": "Created 3D model",
            "run_script": "Ran script",
            "read_file": "Read file",
            "write_file": "Wrote file",
            "edit_file": "Edited file",
            "search_images": "Found images",
            "capture_screen": "Captured screen",
            "search_web": "Searched web",
            "click_element": "Clicked element",
            "type_text": "Typed text",
            "open_app": "Opened app",
            "ffmpeg_edit_video": "Edited video",
            "ffmpeg_probe": "Probed media",
            "download_youtube": "Downloaded media",
            "save_memory": "Saved memory",
            "notion_create_page": "Created Notion page",
            "notion_search": "Searched Notion",
        ]

        let action = actionMap[toolName] ?? toolName.replacingOccurrences(of: "_", with: " ")
        return detail.isEmpty ? action : "\(action) (\(detail))"
    }

    // MARK: - State Persistence

    private func saveState(_ state: GoalState, to ctx: MiddlewareContext) {
        ctx.storage[Self.goalKey] = state.summary
        ctx.storage[Self.stepsKey] = state.completedSteps
        ctx.storage[Self.phaseKey] = state.phase.rawValue
        ctx.storage[Self.keywordsKey] = state.coreKeywords
    }

    private func loadState(from ctx: MiddlewareContext) -> GoalState? {
        guard let summary = ctx.storage[Self.goalKey] as? String else { return nil }
        return GoalState(
            summary: summary,
            completedSteps: ctx.storage[Self.stepsKey] as? [String] ?? [],
            activeStep: nil,
            phase: GoalState.Phase(rawValue: ctx.storage[Self.phaseKey] as? String ?? "executing") ?? .executing,
            coreKeywords: ctx.storage[Self.keywordsKey] as? Set<String> ?? []
        )
    }
}
