import Foundation

/// Tracks all tool calls, results, decisions, and state changes throughout a session.
/// The LLM can reference past actions ("what did I do earlier?"), avoid repeating work,
/// and build on previous results. Memory persists across iterations within a session
/// and survives context pruning.
///
/// Storage model: lightweight event log with timestamps and semantic summaries.
/// Injected as a compact recap before each LLM call (after iteration 0).
public final class ConversationMemoryMiddleware: AgentMiddleware {
    public let name = "ConversationMemory"

    public init() {}

    // MARK: - Storage Keys

    private static let eventsKey = "ConversationMemory.events"
    private static let summaryKey = "ConversationMemory.summary"
    private static let toolResultsKey = "ConversationMemory.toolResults"

    // MARK: - Event Model

    public struct MemoryEvent: Codable, Sendable {
        public let timestamp: Date
        public let type: EventType
        public let summary: String
        public let details: String?

        public enum EventType: String, Codable, Sendable {
            case toolCall
            case toolResult
            case decision
            case userInput
            case error
            case stateChange
        }
    }

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        if ctx.iteration == 0 {
            ctx.storage[Self.eventsKey] = [MemoryEvent]()
            ctx.storage[Self.toolResultsKey] = [String: String]()
            return .continue
        }

        guard let events = ctx.storage[Self.eventsKey] as? [MemoryEvent], !events.isEmpty else {
            return .continue
        }

        let recap = buildRecap(events: events, maxLength: 1500)
        if !recap.isEmpty {
            ctx.storage[Self.summaryKey] = recap

            let recapPrefix = "[Session Recap]\n"
            // Strip any prior recap injection to avoid accumulation across iterations.
            ctx.messages.removeAll { $0.content?.hasPrefix(recapPrefix) == true }
            // The recap embeds truncated tool OUTPUT (line items in the activity
            // log), which is untrusted — a tool result could contain an injection
            // payload. Frame it as data so the model doesn't treat recalled tool
            // output as instructions.
            let framedRecap = ExternalContentFraming.wrap(recap, source: "session activity log (tool output)")
            // Seat the recap immediately after the system prompt at index 0.
            let insertIdx = ctx.messages.isEmpty ? 0 : 1
            ctx.messages.insert(
                ChatMessage(role: "system", content: recapPrefix + framedRecap),
                at: insertIdx
            )
        }

        return .continue
    }

    public func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal {
        var events = ctx.storage[Self.eventsKey] as? [MemoryEvent] ?? []

        if let text = response.text, !text.isEmpty {
            let summary = String(text.prefix(200))
            events.append(MemoryEvent(
                timestamp: Date(),
                type: .decision,
                summary: "AI response: \(summary)",
                details: nil
            ))
        }

        if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
            let names = toolCalls.map { $0.function.name }
            events.append(MemoryEvent(
                timestamp: Date(),
                type: .toolCall,
                summary: "Called: \(names.joined(separator: ", "))",
                details: toolCalls.count > 1 ? "\(toolCalls.count) tools in batch" : nil
            ))
        }

        ctx.storage[Self.eventsKey] = events
        return .continue
    }

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        var events = ctx.storage[Self.eventsKey] as? [MemoryEvent] ?? []
        var toolResults = ctx.storage[Self.toolResultsKey] as? [String: String] ?? [:]

        for result in results {
            let isError = result.result.hasPrefix("Error")
            let truncated = String(result.result.prefix(300))

            events.append(MemoryEvent(
                timestamp: Date(),
                type: isError ? .error : .toolResult,
                summary: "\(result.toolName): \(truncated)",
                details: nil
            ))

            toolResults[result.toolName] = String(result.result.prefix(1000))
        }

        if events.count > 50 {
            events = Array(events.suffix(50))
        }

        ctx.storage[Self.eventsKey] = events
        ctx.storage[Self.toolResultsKey] = toolResults
        return .continue
    }

    // MARK: - Recap Builder

    private func buildRecap(events: [MemoryEvent], maxLength: Int) -> String {
        var recap = "## Session Activity Log\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let toolCalls = events.filter { $0.type == .toolCall }
        let errors = events.filter { $0.type == .error }

        if !toolCalls.isEmpty {
            let recent = toolCalls.suffix(10)
            recap += "**Actions taken (\(toolCalls.count) total):**\n"
            for event in recent {
                recap += "- [\(formatter.string(from: event.timestamp))] \(event.summary)\n"
            }
        }

        if !errors.isEmpty {
            recap += "**Errors (\(errors.count)):**\n"
            for event in errors.suffix(3) {
                recap += "- \(event.summary)\n"
            }
        }

        if recap.count > maxLength {
            recap = String(recap.prefix(maxLength)) + "\n...(truncated)"
        }

        return recap
    }

    // MARK: - Public Query API

    public static func queryEvents(from storage: [String: Any], matching query: String) -> [MemoryEvent] {
        guard let events = storage[eventsKey] as? [MemoryEvent] else { return [] }
        if query.isEmpty { return Array(events.suffix(20)) }

        let lower = query.lowercased()
        return events.filter { event in
            event.summary.lowercased().contains(lower) ||
            (event.details?.lowercased().contains(lower) ?? false)
        }
    }

    public static func lastToolResult(from storage: [String: Any], toolName: String) -> String? {
        guard let results = storage[toolResultsKey] as? [String: String] else { return nil }
        return results[toolName]
    }

    public static func eventCount(from storage: [String: Any]) -> Int {
        (storage[eventsKey] as? [MemoryEvent])?.count ?? 0
    }
}

// MARK: - Session History Tool

/// LLM-callable tool that queries the conversation memory within the current session.
/// Allows the AI to answer "What did I do earlier?" or "Did I already check emails?"
public struct SessionHistoryTool: ToolDefinition {
    public let name = "session_history"
    public let description = "Query the current session's activity history. Use this to check what actions have been taken, what tools were called, what results were returned, and what errors occurred during this session. Useful for avoiding duplicate work and answering follow-up questions about past actions."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search term to filter history (e.g., 'email', 'calendar', 'file'). Leave empty to get recent activity summary."),
            "type": JSONSchema.enumString(description: "Filter by event type", values: ["all", "tool_calls", "errors", "decisions"]),
            "last_n": JSONSchema.integer(description: "Return only the last N events", minimum: 1, maximum: 50),
        ], required: [])
    }

    /// Reference to the middleware chain's persistent storage — set at registration.
    public var storageProvider: (@Sendable () -> [String: Any])?

    public init(storageProvider: (@Sendable () -> [String: Any])? = nil) {
        self.storageProvider = storageProvider
    }

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = optionalString("query", from: args) ?? ""
        let typeFilter = optionalString("type", from: args) ?? "all"
        let lastN = optionalInt("last_n", from: args) ?? 20

        guard let storage = storageProvider?() else {
            return "No session history available yet."
        }

        var events = ConversationMemoryMiddleware.queryEvents(from: storage, matching: query)

        switch typeFilter {
        case "tool_calls":
            events = events.filter { $0.type == .toolCall || $0.type == .toolResult }
        case "errors":
            events = events.filter { $0.type == .error }
        case "decisions":
            events = events.filter { $0.type == .decision }
        default:
            break
        }

        events = Array(events.suffix(lastN))

        if events.isEmpty {
            return query.isEmpty
                ? "No actions have been taken in this session yet."
                : "No events matching '\(query)' found in this session."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        var result = "Session History (\(events.count) events"
        if !query.isEmpty { result += " matching '\(query)'" }
        result += "):\n\n"

        for event in events {
            let icon: String
            switch event.type {
            case .toolCall: icon = ">"
            case .toolResult: icon = "<"
            case .decision: icon = "*"
            case .userInput: icon = "?"
            case .error: icon = "!"
            case .stateChange: icon = "~"
            }
            result += "\(icon) [\(formatter.string(from: event.timestamp))] \(event.summary)\n"
            if let details = event.details {
                result += "  \(details)\n"
            }
        }

        let totalCount = ConversationMemoryMiddleware.eventCount(from: storage)
        result += "\nTotal session events: \(totalCount)"

        return result
    }
}
