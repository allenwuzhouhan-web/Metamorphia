import Foundation

// MARK: - Trace Entry Kind

/// Categorizes each event captured during agent execution.
public enum TraceEntryKind: Sendable {
    case llmCall(messageCount: Int, responseLength: Int, hasToolCalls: Bool, reasoning: String?)
    case toolCall(name: String, arguments: String, result: String, durationMs: Double, success: Bool)
    case planning(output: String)
    case subAgentDecomposition(taskCount: Int)
    case webScrape(url: String, contentPreview: String)
    case error(source: String, message: String)
    case contextPrune(beforeTokens: Int, afterTokens: Int)
    case retry(toolName: String, attempt: Int, reason: String)
    case selfEvaluation(passed: Bool, feedback: String)
    case subAgentComplete(id: String, app: String?, durationMs: Double, success: Bool)
    case hostAgentRouting(subtaskCount: Int, apps: [String])
}

// MARK: - Trace Entry

/// A single event in the agent execution timeline.
public struct TraceEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: TraceEntryKind
    public let durationMs: Double?

    public init(
        kind: TraceEntryKind,
        durationMs: Double? = nil,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.durationMs = durationMs
    }

    /// One-line summary for timeline display.
    public var summary: String {
        switch kind {
        case .llmCall(let msgCount, let respLen, let hasTools, _):
            return "LLM call (\(msgCount) msgs → \(respLen) chars\(hasTools ? ", tool calls" : ""))"
        case .toolCall(let name, _, _, let ms, let success):
            return "\(success ? "OK" : "FAIL") \(name) (\(Int(ms))ms)"
        case .planning:
            return "Planning phase"
        case .subAgentDecomposition(let count):
            return "Decomposed into \(count) sub-agents"
        case .webScrape(let url, _):
            return "Web scrape: \(url)"
        case .error(let source, let message):
            return "Error [\(source)]: \(message)"
        case .contextPrune(let before, let after):
            return "Context pruned: ~\(before) → ~\(after) tokens"
        case .retry(let name, let attempt, _):
            return "Retry #\(attempt) for \(name)"
        case .selfEvaluation(let passed, _):
            return "Self-eval: \(passed ? "passed" : "failed")"
        case .subAgentComplete(let id, let app, let ms, let success):
            return "\(success ? "OK" : "FAIL") AppAgent[\(app ?? id)] (\(Int(ms))ms)"
        case .hostAgentRouting(let count, let apps):
            return "HostAgent routing → \(count) subtasks (\(apps.joined(separator: ", ")))"
        }
    }

    /// Color identifier for timeline dots (UI picks the actual SwiftUI Color).
    public var colorName: String {
        switch kind {
        case .llmCall: return "purple"
        case .toolCall(_, _, _, _, let success): return success ? "blue" : "red"
        case .planning: return "teal"
        case .subAgentDecomposition: return "teal"
        case .webScrape: return "orange"
        case .error: return "red"
        case .contextPrune: return "gray"
        case .retry: return "yellow"
        case .selfEvaluation(let passed, _): return passed ? "green" : "red"
        case .subAgentComplete(_, _, _, let success): return success ? "green" : "red"
        case .hostAgentRouting: return "teal"
        }
    }
}

// MARK: - Agent Trace

/// Complete execution trace for one agent task.
/// In-memory only — never persisted to disk at this layer (traces may contain sensitive data).
/// The app target can wrap this and save snapshots if desired.
public final class AgentTrace: @unchecked Sendable {

    public enum Outcome: Sendable {
        case success
        case failure(String)
        case cancelled
    }

    public let id: UUID
    public let goal: String
    public let startTime: Date
    public var endTime: Date?
    public var planOutput: String?
    public var finalOutcome: Outcome?

    private let lock = NSLock()
    private var _entries: [TraceEntry] = []

    public var entries: [TraceEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    public init(goal: String, id: UUID = UUID(), startTime: Date = Date()) {
        self.id = id
        self.goal = goal
        self.startTime = startTime
    }

    /// Thread-safe append — called from detached tasks and TaskGroups.
    public func append(_ entry: TraceEntry) {
        lock.lock()
        defer { lock.unlock() }
        _entries.append(entry)
    }

    // MARK: Computed Helpers

    public var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    public var toolCallCount: Int {
        entries.filter {
            if case .toolCall = $0.kind { return true }
            return false
        }.count
    }

    public var failedToolCalls: [TraceEntry] {
        entries.filter {
            if case .toolCall(_, _, _, _, let success) = $0.kind { return !success }
            return false
        }
    }

    public var errorEntries: [TraceEntry] {
        entries.filter {
            if case .error = $0.kind { return true }
            return false
        }
    }

    public var webScrapes: [TraceEntry] {
        entries.filter {
            if case .webScrape = $0.kind { return true }
            return false
        }
    }

    public var llmCallCount: Int {
        entries.filter {
            if case .llmCall = $0.kind { return true }
            return false
        }.count
    }

    public var formattedDuration: String {
        let d = duration
        if d < 1 { return "<1s" }
        if d < 60 { return String(format: "%.1fs", d) }
        return String(format: "%.0fm %.0fs", (d / 60).rounded(.down), d.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Export

    /// Build a human-readable dump of the trace for copying to the clipboard or bug reports.
    /// Sensitive patterns (API keys, passwords, card numbers) are redacted via `TraceRedactor`.
    public func formattedString() -> String {
        var lines: [String] = []
        let iso = ISO8601DateFormatter()

        lines.append("# Agent Trace")
        lines.append("")
        lines.append("**Goal:** \(goal)")
        lines.append("**Started:** \(iso.string(from: startTime))")
        if let end = endTime {
            lines.append("**Ended:** \(iso.string(from: end))")
        }
        lines.append("**Duration:** \(formattedDuration)")
        switch finalOutcome {
        case .success: lines.append("**Outcome:** SUCCESS")
        case .failure(let msg): lines.append("**Outcome:** FAILED — \(TraceRedactor.redact(msg))")
        case .cancelled: lines.append("**Outcome:** CANCELLED")
        case .none: lines.append("**Outcome:** (still running)")
        }
        lines.append("**LLM calls:** \(llmCallCount)   **Tool calls:** \(toolCallCount)   **Errors:** \(errorEntries.count)")
        lines.append("")

        if let plan = planOutput, !plan.isEmpty {
            lines.append("## Plan")
            lines.append("```")
            lines.append(TraceRedactor.redact(plan))
            lines.append("```")
            lines.append("")
        }

        lines.append("## Timeline")
        lines.append("")
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        for (idx, entry) in entries.enumerated() {
            let ts = fmt.string(from: entry.timestamp)
            let n = String(format: "%03d", idx + 1)
            switch entry.kind {
            case .llmCall(let msgCount, let respLen, let hasTools, let reasoning):
                lines.append("[\(n)] \(ts)  LLM  msgs=\(msgCount) respChars=\(respLen)\(hasTools ? " +tools" : "")")
                if let r = reasoning, !r.isEmpty {
                    let redacted = TraceRedactor.redact(r)
                    lines.append("      reasoning: \(redacted.prefix(800))")
                }
            case .toolCall(let name, let args, let result, let ms, let success):
                let status = success ? "OK " : "FAIL"
                lines.append("[\(n)] \(ts)  TOOL \(status) \(name) (\(Int(ms))ms)")
                let redactedArgs = TraceRedactor.redact(args)
                lines.append("      args: \(redactedArgs.prefix(1200))")
                let redactedResult = TraceRedactor.redact(result)
                lines.append("      result: \(redactedResult.prefix(1200))")
            case .planning(let output):
                lines.append("[\(n)] \(ts)  PLAN")
                lines.append("      \(TraceRedactor.redact(output).prefix(1200))")
            case .subAgentDecomposition(let count):
                lines.append("[\(n)] \(ts)  DECOMPOSE  into \(count) sub-agents")
            case .webScrape(let url, let preview):
                lines.append("[\(n)] \(ts)  WEB  \(url)")
                lines.append("      \(TraceRedactor.redact(preview).prefix(400))")
            case .error(let source, let message):
                lines.append("[\(n)] \(ts)  ERROR [\(source)] \(TraceRedactor.redact(message))")
            case .contextPrune(let before, let after):
                lines.append("[\(n)] \(ts)  PRUNE  \(before) → \(after) tokens")
            case .retry(let name, let attempt, let reason):
                lines.append("[\(n)] \(ts)  RETRY  \(name) #\(attempt) — \(reason)")
            case .selfEvaluation(let passed, let feedback):
                lines.append("[\(n)] \(ts)  SELF-EVAL  \(passed ? "PASS" : "FAIL") — \(TraceRedactor.redact(feedback).prefix(400))")
            case .subAgentComplete(let id, let app, let ms, let success):
                lines.append("[\(n)] \(ts)  SUBAGENT \(success ? "OK" : "FAIL") [\(app ?? id)] (\(Int(ms))ms)")
            case .hostAgentRouting(let count, let apps):
                lines.append("[\(n)] \(ts)  ROUTE  \(count) subtasks → \(apps.joined(separator: ", "))")
            }
        }
        lines.append("")

        if !errorEntries.isEmpty {
            lines.append("## Errors")
            for entry in errorEntries {
                if case .error(let source, let message) = entry.kind {
                    lines.append("- [\(source)] \(TraceRedactor.redact(message))")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
