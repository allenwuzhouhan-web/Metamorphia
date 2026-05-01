import Foundation

/// Detects when the user corrects the LLM and stores corrections as high-weight memories.
///
/// Correction detection happens at two points:
///   1. **afterToolExecution** — scans tool result messages for correction signals
///      (the user might have typed "no, I meant..." in a follow-up)
///   2. **beforeModelCall** — checks the latest user message for correction patterns
///      and injects relevant past corrections into context
///
/// Corrections are persisted via the injected ``MemoryStore`` with category `.correction`
/// and high recall weight, ensuring the same mistake is not repeated across sessions.
public final class CorrectionDetectorMiddleware: AgentMiddleware {
    public let name = "CorrectionDetector"

    // MARK: - Storage Keys

    private static let correctionsKey = "CorrectionDetector.corrections"
    private static let lastUserMsgKey = "CorrectionDetector.lastUserMsg"
    private static let injectedKey = "CorrectionDetector.injected"

    // MARK: - Dependencies

    private let memoryStore: MemoryStore

    public init(memoryStore: MemoryStore) {
        self.memoryStore = memoryStore
    }

    // MARK: - Correction Model

    public struct CorrectionRecord: Codable, Sendable {
        public let original: String
        public let correction: String
        public let timestamp: Date
        public let toolContext: String?
    }

    // MARK: - Correction Patterns

    private static let correctionPatterns: [(pattern: String, weight: Double)] = [
        ("no, i meant", 0.95),
        ("no i meant", 0.95),
        ("that's not what i", 0.95),
        ("thats not what i", 0.95),
        ("i said", 0.8),
        ("i asked for", 0.85),
        ("i wanted", 0.8),
        ("i need you to", 0.7),
        ("what i actually", 0.9),
        ("not that", 0.8),
        ("wrong one", 0.85),
        ("wrong file", 0.85),
        ("wrong app", 0.85),
        ("the other", 0.7),
        ("the correct", 0.75),
        ("don't do that", 0.9),
        ("stop doing", 0.9),
        ("never do that", 0.95),
        ("please don't", 0.75),
        ("you shouldn't", 0.75),
        ("don't use", 0.8),
        ("stop using", 0.85),
        ("never use", 0.9),
        ("actually,", 0.6),
        ("actually ", 0.5),
        ("no,", 0.5),
        ("nope", 0.6),
        ("instead,", 0.65),
        ("instead ", 0.55),
        ("rather,", 0.6),
        ("try again", 0.7),
        ("redo ", 0.75),
        ("do it again", 0.7),
        ("that's wrong", 0.9),
        ("thats wrong", 0.9),
        ("you got it wrong", 0.95),
        ("that was incorrect", 0.9),
        ("not what i asked", 0.9),
    ]

    private static let amplifiers: Set<String> = [
        "not", "don't", "never", "wrong", "incorrect", "no", "stop",
        "shouldn't", "instead", "actually", "but", "however"
    ]

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        guard let lastUserMsg = ctx.messages.last(where: { $0.role == "user" }),
              let content = lastUserMsg.content else {
            return .continue
        }

        if content.hasPrefix("[SYSTEM CONTEXT]") { return .continue }

        if ctx.iteration > 0 {
            let detection = detectCorrection(in: content, previousContext: ctx)
            if let correction = detection {
                var corrections = ctx.storage[Self.correctionsKey] as? [[String: String]] ?? []
                corrections.append([
                    "original": correction.original,
                    "correction": correction.correction,
                    "tool": correction.toolContext ?? ""
                ])
                ctx.storage[Self.correctionsKey] = corrections

                persistCorrection(correction)
            }
        }

        let pastCorrections = recallCorrections(for: ctx.command)
        if !pastCorrections.isEmpty {
            let alreadyInjected = ctx.storage[Self.injectedKey] as? Bool ?? false
            if !alreadyInjected {
                let section = formatCorrections(pastCorrections)
                if let sysIdx = ctx.messages.firstIndex(where: { $0.role == "system" }),
                   let existing = ctx.messages[sysIdx].content {
                    ctx.messages[sysIdx] = ChatMessage(role: "system", content: existing + "\n\n" + section)
                }
                ctx.storage[Self.injectedKey] = true
            }
        }

        ctx.storage[Self.lastUserMsgKey] = content

        return .continue
    }

    // MARK: - Detection

    private func detectCorrection(in message: String, previousContext ctx: MiddlewareContext) -> CorrectionRecord? {
        let lower = message.lowercased()

        var maxWeight = 0.0
        for (pattern, weight) in Self.correctionPatterns {
            if lower.contains(pattern) {
                maxWeight = max(maxWeight, weight)
            }
        }

        let words = Set(lower.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty })
        let amplifierCount = words.intersection(Self.amplifiers).count
        let amplifierBoost = min(Double(amplifierCount) * 0.1, 0.3)
        maxWeight = min(maxWeight + amplifierBoost, 1.0)

        guard maxWeight >= 0.6 else { return nil }

        let original = extractOriginalContext(from: ctx)
        let correction = message

        let recentTool = ctx.messages.reversed()
            .compactMap { $0.tool_calls?.first?.function.name }
            .first

        return CorrectionRecord(
            original: String(original.prefix(200)),
            correction: String(correction.prefix(200)),
            timestamp: Date(),
            toolContext: recentTool
        )
    }

    private func extractOriginalContext(from ctx: MiddlewareContext) -> String {
        if let lastAssistant = ctx.messages.reversed().first(where: { $0.role == "assistant" }) {
            if let text = lastAssistant.content, !text.isEmpty {
                return text
            }
            if let calls = lastAssistant.tool_calls {
                return calls.map { $0.function.name }.joined(separator: ", ")
            }
        }
        return ctx.command
    }

    // MARK: - Memory Integration

    private func persistCorrection(_ correction: CorrectionRecord) {
        let content: String
        if let tool = correction.toolContext {
            content = "CORRECTION (tool: \(tool)): User said \"\(correction.correction)\" — " +
                      "was wrong about: \"\(correction.original)\""
        } else {
            content = "CORRECTION: User said \"\(correction.correction)\" — " +
                      "was wrong about: \"\(correction.original)\""
        }

        let allText = "\(correction.original) \(correction.correction)"
        let keywords = allText.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .prefix(10)

        memoryStore.add(MemoryInput(
            content: String(content.prefix(500)),
            category: .correction,
            keywords: Array(keywords)
        ))

        print("[CorrectionDetector] Stored correction: \(content.prefix(100))...")
    }

    private func recallCorrections(for query: String) -> [MemoryRecord] {
        let all = memoryStore.recall(query: query, category: .correction, limit: 5)
        let queryWords = Set(query.lowercased().components(separatedBy: .alphanumerics.inverted))
        return all.filter { correction in
            let corrWords = Set(correction.keywords)
            return !corrWords.intersection(queryWords).isEmpty
        }
    }

    private func formatCorrections(_ corrections: [MemoryRecord]) -> String {
        var lines = ["## Past Corrections (learn from these)"]
        lines.append("The user has previously corrected you on these points. Avoid repeating these mistakes:")
        for correction in corrections {
            lines.append("- \(correction.content)")
        }
        return lines.joined(separator: "\n")
    }
}
