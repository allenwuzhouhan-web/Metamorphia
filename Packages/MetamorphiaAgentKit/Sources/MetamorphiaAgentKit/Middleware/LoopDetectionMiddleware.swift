import Foundation

/// Detects when the agent is stuck in a loop — repeating the same tool calls.
///
/// Uses a hash-based sliding window over recent tool calls. When the same
/// tool+args signature appears repeatedly:
///   - **3 hits** → injects a warning message ("you're repeating yourself, try a different approach")
///   - **5 hits** → forces the loop to stop
///
/// Hashing strategy: tool name + salient argument fields (path, url, query, command,
/// need, topic, search) — NOT the full arguments blob. This catches semantic loops
/// (same intent, slightly different phrasing) while ignoring irrelevant variation
/// (timestamps, request IDs).
public final class LoopDetectionMiddleware: AgentMiddleware {
    public let name = "LoopDetection"

    /// Number of identical calls before injecting a warning.
    private let warnThreshold: Int
    /// Number of identical calls before force-stopping the loop.
    private let stopThreshold: Int

    public init(warnThreshold: Int = 3, stopThreshold: Int = 5) {
        self.warnThreshold = warnThreshold
        self.stopThreshold = stopThreshold
    }

    // MARK: - Storage Keys

    private static let countsKey = "LoopDetection.counts"      // [String: Int]
    private static let warnedKey = "LoopDetection.warned"      // Set<String>

    // MARK: - Hooks

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        var counts = ctx.storage[Self.countsKey] as? [String: Int] ?? [:]
        var warned = ctx.storage[Self.warnedKey] as? Set<String> ?? []

        var maxCount = 0
        var worstOffender = ""
        var worstSignature = ""

        for call in toolCalls {
            let sig = Self.signature(call)
            counts[sig, default: 0] += 1
            let c = counts[sig, default: 0]
            if c > maxCount {
                maxCount = c
                worstOffender = call.function.name
                worstSignature = sig
            }
        }

        ctx.storage[Self.countsKey] = counts
        ctx.storage[Self.warnedKey] = warned

        // Force stop — agent is hopelessly looping
        if maxCount >= stopThreshold {
            let reason = "Loop detected: \(worstOffender) called \(maxCount) times with same arguments. Stopping to prevent infinite loop."
            print("[Middleware/LoopDetection] STOP — \(reason)")
            ctx.trace?.append(TraceEntry(kind: .error(source: "LoopDetection", message: reason)))
            return .stop(reason: reason)
        }

        // Warn — give the LLM a chance to self-correct
        if maxCount >= warnThreshold && !worstSignature.isEmpty {
            // Only warn once per signature to avoid spam
            guard !warned.contains(worstSignature) else { return .continue }
            warned.insert(worstSignature)
            ctx.storage[Self.warnedKey] = warned

            let warning = ChatMessage(
                role: "user",
                content: "You have called \(worstOffender) \(maxCount) times with the same arguments. " +
                         "You appear to be stuck in a loop. Try a DIFFERENT approach — use a different tool, " +
                         "different arguments, or re-evaluate whether the task is already complete."
            )
            print("[Middleware/LoopDetection] WARN — \(worstOffender) repeated \(maxCount)x")
            ctx.trace?.append(TraceEntry(kind: .error(
                source: "LoopDetection",
                message: "Warning injected: \(worstOffender) repeated \(maxCount)x"
            )))
            return .injectMessages([warning])
        }

        return .continue
    }

    // MARK: - Signature Hashing

    /// Salient fields used for loop detection — if two calls share the same tool name
    /// and the same values for these fields, they're considered duplicates.
    private static let salientKeys: [String] = [
        "path", "file_path", "file", "filename",            // file operations
        "source", "source_file", "source_path",             // copy/move source
        "destination", "dest", "target", "target_path",     // copy/move destination
        "url", "uri", "href", "link",                        // web/fetch operations
        "query", "search", "q", "keyword", "term",           // search operations
        "command", "cmd", "script",                          // execution operations
        "need", "topic", "name",                             // meta / request operations
        "tool_name", "selector", "css_selector",             // browser / tool operations
        "to", "from", "recipient",                           // messaging: who
        "subject", "body", "message", "text",                // messaging: content
        "page_id", "pageId", "block_id", "blockId",          // Notion IDs
        "database_id", "databaseId", "parent_id",            // Notion containers
        "channel", "channel_id",                             // Slack
    ]

    /// Build a deterministic signature from tool name + salient argument values.
    public static func signature(_ call: ToolCall) -> String {
        let name = call.function.name

        guard let data = call.function.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "\(name)|\(stableHash(call.function.arguments))"
        }

        var parts: [String] = [name]
        for key in salientKeys {
            if let val = dict[key] {
                parts.append("\(escape(key))=\(escape("\(val)"))")
            }
        }

        if parts.count == 1 {
            parts.append(stableHash(call.function.arguments))
        }

        return parts.joined(separator: "|")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
    }

    /// Stable string hash (not Swift's per-process-random Hasher).
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
