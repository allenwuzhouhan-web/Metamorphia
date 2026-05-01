import Foundation

/// As conversations grow longer, intelligently compresses older history while
/// preserving recent and relevant context. Uses importance scoring to decide
/// what to keep in detail vs. what to summarize.
///
/// Strategy:
/// - Recent messages (last 6): keep full
/// - Important messages (tool results with data): keep but truncate
/// - Old messages: summarize into a compact recap
/// - System message: always preserved in full
public final class ContextWindowOptimizer: AgentMiddleware {
    public let name = "ContextOptimizer"

    private let tokenThreshold: Int
    private let recentWindowSize: Int
    private let maxMessageTokens: Int

    public init(
        tokenThreshold: Int = 80_000,
        recentWindowSize: Int = 6,
        maxMessageTokens: Int = 2000
    ) {
        self.tokenThreshold = tokenThreshold
        self.recentWindowSize = recentWindowSize
        self.maxMessageTokens = maxMessageTokens
    }

    // MARK: - Storage Keys

    private static let compressionCountKey = "ContextOpt.compressionCount"
    private static let summaryKey = "ContextOpt.historySummary"

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        let estimatedTokens = estimateTokens(ctx.messages)

        guard estimatedTokens > tokenThreshold else { return .continue }

        let compressionCount = (ctx.storage[Self.compressionCountKey] as? Int ?? 0) + 1
        ctx.storage[Self.compressionCountKey] = compressionCount

        let (compressed, summary) = compressMessages(
            ctx.messages,
            iteration: ctx.iteration,
            existingSummary: ctx.storage[Self.summaryKey] as? String
        )
        ctx.messages = compressed
        ctx.storage[Self.summaryKey] = summary

        let newEstimate = estimateTokens(ctx.messages)
        print("[ContextOptimizer] Compressed: ~\(estimatedTokens) -> ~\(newEstimate) tokens (compression #\(compressionCount))")

        return .continue
    }

    // MARK: - Token Estimation

    private func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, msg in
            total + ((msg.content?.count ?? 0) / 4) + 4
        }
    }

    // MARK: - Message Compression

    private func compressMessages(
        _ messages: [ChatMessage],
        iteration: Int,
        existingSummary: String?
    ) -> (messages: [ChatMessage], summary: String) {
        guard messages.count > recentWindowSize + 2 else {
            return (messages, existingSummary ?? "")
        }

        let systemMessage = messages.first(where: { $0.role == "system" })
        let nonSystem = messages.filter { $0.role != "system" }

        let splitPoint = max(0, nonSystem.count - recentWindowSize)
        let oldMessages = Array(nonSystem[..<splitPoint])
        let recentMessages = Array(nonSystem[splitPoint...])

        let scored = oldMessages.map { msg -> (ChatMessage, Double) in
            (msg, scoreImportance(msg))
        }

        var summaryParts: [String] = []
        if let existing = existingSummary, !existing.isEmpty {
            summaryParts.append(existing)
        }

        for (msg, score) in scored {
            if score > 0.7 {
                let content = msg.content ?? ""
                summaryParts.append("[\(msg.role)] \(String(content.prefix(200)))")
            } else if score > 0.3 {
                let content = msg.content ?? ""
                let firstLine = content.components(separatedBy: "\n").first ?? content
                summaryParts.append("[\(msg.role)] \(String(firstLine.prefix(100)))")
            }
        }

        let summaryText = summaryParts.joined(separator: "\n")

        let maxSummaryChars = 4000
        let finalSummary: String
        if summaryText.count > maxSummaryChars {
            finalSummary = String(summaryText.suffix(maxSummaryChars))
        } else {
            finalSummary = summaryText
        }

        var compressed: [ChatMessage] = []
        if let sys = systemMessage {
            compressed.append(sys)
        }

        if !finalSummary.isEmpty {
            compressed.append(ChatMessage(
                role: "user",
                content: "[COMPRESSED HISTORY — earlier conversation summarized]\n\(finalSummary)"
            ))
        }

        for msg in recentMessages {
            compressed.append(truncateMessage(msg))
        }

        return (compressed, finalSummary)
    }

    // MARK: - Importance Scoring

    private func scoreImportance(_ message: ChatMessage) -> Double {
        var score: Double = 0.0
        let content = message.content ?? ""

        switch message.role {
        case "system":
            return 1.0
        case "user":
            score += 0.4
        case "assistant":
            score += 0.3
        case "tool":
            score += 0.2
        default:
            break
        }

        let lower = content.lowercased()

        if lower.contains("error") || lower.contains("failed") || lower.contains("denied") {
            score += 0.3
        }

        if lower.contains("no,") || lower.contains("not that") || lower.contains("instead") ||
           lower.contains("wrong") || lower.contains("undo") {
            score += 0.4
        }

        if lower.contains("plan") || lower.contains("goal") || lower.contains("my plan:") {
            score += 0.3
        }

        if content.count < 100 {
            score += 0.1
        }

        if message.role == "tool" && content.count > 2000 {
            score -= 0.2
        }

        if content.contains("/Users/") || content.contains("~/") {
            score += 0.1
        }

        return min(1.0, max(0.0, score))
    }

    // MARK: - Message Truncation

    private func truncateMessage(_ message: ChatMessage) -> ChatMessage {
        guard let content = message.content, content.count > maxMessageTokens * 4 else {
            return message
        }

        let keepChars = maxMessageTokens * 4
        let halfKeep = keepChars / 2
        let start = String(content.prefix(halfKeep))
        let end = String(content.suffix(halfKeep))
        let truncated = "\(start)\n\n...[truncated \(content.count - keepChars) chars]...\n\n\(end)"

        return ChatMessage(
            role: message.role,
            content: truncated,
            tool_calls: message.tool_calls,
            tool_call_id: message.tool_call_id
        )
    }

    // MARK: - Public API

    public static func compressionCount(from storage: [String: Any]) -> Int {
        storage[compressionCountKey] as? Int ?? 0
    }

    public static func historySummary(from storage: [String: Any]) -> String? {
        storage[summaryKey] as? String
    }
}
