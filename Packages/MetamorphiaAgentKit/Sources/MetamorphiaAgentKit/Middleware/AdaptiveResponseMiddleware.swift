import Foundation

/// Adapts the LLM's response style based on the nature of the user's query.
///
/// Different question types warrant different response depths:
///   - **Philosophical/open-ended** → thoughtful, multi-perspective, can be longer
///   - **Transactional** → brief confirmation, execute immediately
///   - **Debugging** → diagnostic, step-by-step, empathetic about frustration
///   - **Creative** → inspirational, suggest options, show enthusiasm
///   - **Follow-up** → concise, builds on prior context, avoids repetition
///
/// The middleware also tracks engagement signals to learn which response depth
/// the user prefers over time (e.g., do they read long responses or skip ahead?).
///
/// The engagement profile is persisted to a user-supplied URL. The original Executer
/// version hardcoded `~/Library/Application Support/Executer/`; the app target now
/// passes in the appropriate Metamorphia path at construction time.
public final class AdaptiveResponseMiddleware: AgentMiddleware, @unchecked Sendable {
    public let name = "AdaptiveResponse"

    // MARK: - Storage Keys

    private static let queryTypeKey = "AdaptiveResponse.queryType"
    private static let depthKey = "AdaptiveResponse.depth"
    private static let prevLengthKey = "AdaptiveResponse.prevLength"

    // MARK: - Query Classification

    public enum QueryType: String {
        case philosophical
        case transactional
        case debugging
        case creative
        case followUp
        case informational
        case emotional
    }

    public enum ResponseDepth: String {
        case minimal
        case concise
        case standard
        case thorough
    }

    // MARK: - Classification Patterns

    private static let patterns: [(keywords: [String], type: QueryType, weight: Double)] = [
        (["what is the meaning", "why do we", "what makes", "how does one", "philosophy",
          "in your opinion", "do you think", "thoughts on", "perspective on"],
         .philosophical, 0.9),
        (["what is", "what are", "why is", "why does", "how come", "explain",
          "what do you mean", "elaborate"],
         .philosophical, 0.5),
        (["open", "close", "launch", "quit", "create", "delete", "move", "copy",
          "set", "change", "toggle", "turn on", "turn off", "enable", "disable",
          "play", "pause", "stop", "send", "save", "download", "install"],
         .transactional, 0.7),
        (["error", "bug", "crash", "broken", "doesn't work", "not working",
          "failed", "failing", "fix", "debug", "why isn't", "why won't",
          "can't", "cannot", "issue", "problem", "wrong", "unexpected"],
         .debugging, 0.8),
        (["design", "make it look", "style", "aesthetic", "beautiful", "creative",
          "artistic", "visual", "layout", "theme", "color scheme", "brand",
          "inspiration", "brainstorm", "ideas for"],
         .creative, 0.7),
        (["also", "and then", "what about", "one more", "another"],
         .followUp, 0.4),
        (["how do i", "how to", "what are the steps", "tutorial", "guide",
          "show me how", "walk me through", "instructions"],
         .informational, 0.7),
        (["thank", "thanks", "awesome", "great job", "perfect", "love it",
          "amazing", "frustrated", "annoyed", "ugh", "why the hell",
          "come on", "seriously", "for the love of"],
         .emotional, 0.6),
    ]

    // MARK: - Engagement Learning

    private struct EngagementProfile: Codable {
        var shortResponseCount: Int = 0
        var longResponseCount: Int = 0
        var skipCount: Int = 0
        var totalInteractions: Int = 0

        var preferredDepth: String {
            guard totalInteractions >= 5 else { return "standard" }
            let engagementRatio = Double(shortResponseCount) / Double(max(totalInteractions, 1))
            if engagementRatio > 0.6 { return "concise" }
            let skipRatio = Double(skipCount) / Double(max(totalInteractions, 1))
            if skipRatio > 0.3 { return "concise" }
            return "standard"
        }
    }

    private var engagement = EngagementProfile()
    private let engagementLock = NSLock()
    private let storageURL: URL?

    /// - Parameter engagementStorageURL: where to persist the JSON engagement profile.
    ///   Pass `nil` to disable persistence (engagement learning still works in-memory
    ///   for the session).
    public init(engagementStorageURL: URL?) {
        self.storageURL = engagementStorageURL
        if let url = engagementStorageURL {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        loadEngagement()
    }

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        guard let lastUserMsg = ctx.messages.last(where: { $0.role == "user" }),
              let content = lastUserMsg.content,
              !content.hasPrefix("[SYSTEM CONTEXT]") else {
            return .continue
        }

        let queryType = classifyQuery(content, context: ctx)
        let depth = determineDepth(for: queryType)

        ctx.storage[Self.queryTypeKey] = queryType.rawValue
        ctx.storage[Self.depthKey] = depth.rawValue

        let guidance = formatGuidance(queryType: queryType, depth: depth)
        if !guidance.isEmpty {
            if let sysIdx = ctx.messages.firstIndex(where: { $0.role == "system" }),
               let existing = ctx.messages[sysIdx].content {
                ctx.messages[sysIdx] = ChatMessage(role: "system", content: existing + "\n\n" + guidance)
            }
        }

        if ctx.iteration > 0, let prevLength = ctx.storage[Self.prevLengthKey] as? Int {
            trackEngagement(userMessageLength: content.count, previousResponseLength: prevLength)
        }

        return .continue
    }

    public func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal {
        if let text = response.text {
            ctx.storage[Self.prevLengthKey] = text.count
        }
        return .continue
    }

    // MARK: - Classification

    private func classifyQuery(_ query: String, context ctx: MiddlewareContext) -> QueryType {
        let lower = query.lowercased()
        let wordCount = query.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count

        if ctx.iteration > 0 && wordCount <= 4 {
            return .followUp
        }

        if ctx.iteration > 0 && wordCount <= 8 {
            let pronouns: Set<String> = ["it", "that", "this", "those", "these", "them"]
            let queryWords = Set(lower.components(separatedBy: .alphanumerics.inverted))
            if !queryWords.intersection(pronouns).isEmpty {
                return .followUp
            }
        }

        var typeScores: [QueryType: Double] = [:]
        for (keywords, type, weight) in Self.patterns {
            let matchCount = keywords.filter { lower.contains($0) }.count
            if matchCount > 0 {
                let score = Double(matchCount) * weight / Double(keywords.count) + weight * 0.5
                typeScores[type, default: 0] += score
            }
        }

        let frustrationWords: Set<String> = ["ugh", "seriously", "come on", "again",
                                              "still", "why the hell", "for the love"]
        let hasFrustration = frustrationWords.contains { lower.contains($0) }

        if let (bestType, bestScore) = typeScores.max(by: { $0.value < $1.value }), bestScore > 0.3 {
            if hasFrustration && bestType == .debugging {
                return .debugging
            }
            return bestType
        }

        if wordCount <= 8 && lower.first?.isLetter == true {
            let startsWithVerb = ["open", "create", "make", "show", "find", "get", "do",
                                  "run", "set", "check", "list", "search"]
            if startsWithVerb.contains(where: { lower.hasPrefix($0) }) {
                return .transactional
            }
        }

        return .informational
    }

    private func determineDepth(for queryType: QueryType) -> ResponseDepth {
        let baseDepth: ResponseDepth
        switch queryType {
        case .transactional:   baseDepth = .minimal
        case .followUp:        baseDepth = .concise
        case .debugging:       baseDepth = .standard
        case .informational:   baseDepth = .standard
        case .creative:        baseDepth = .standard
        case .philosophical:   baseDepth = .thorough
        case .emotional:       baseDepth = .concise
        }

        engagementLock.lock()
        let preferred = engagement.preferredDepth
        engagementLock.unlock()

        if preferred == "concise" && baseDepth == .thorough {
            return .standard
        }

        return baseDepth
    }

    // MARK: - Guidance Formatting

    private func formatGuidance(queryType: QueryType, depth: ResponseDepth) -> String {
        var lines: [String] = []

        switch queryType {
        case .philosophical:
            lines.append("## Response Style: Thoughtful")
            lines.append("This is an open-ended question. Consider multiple perspectives.")
            lines.append("It's OK to be longer and more nuanced here.")
        case .transactional:
            lines.append("## Response Style: Execute")
            lines.append("This is a direct command. Execute it and confirm briefly.")
            lines.append("Keep your text response under 2 sentences.")
        case .debugging:
            lines.append("## Response Style: Diagnostic")
            lines.append("The user is troubleshooting. Be systematic and empathetic.")
            lines.append("Acknowledge the issue, then diagnose step by step.")
        case .creative:
            lines.append("## Response Style: Inspirational")
            lines.append("This is a creative request. Suggest options where appropriate.")
            lines.append("Show enthusiasm for the creative direction.")
        case .followUp:
            lines.append("## Response Style: Continuation")
            lines.append("This is a follow-up. Build on the prior context.")
            lines.append("Don't repeat what was already covered. Be concise.")
        case .informational:
            return ""
        case .emotional:
            lines.append("## Response Style: Empathetic")
            lines.append("Acknowledge the user's emotion before addressing the content.")
            lines.append("Match their energy — celebrate if they're happy, empathize if frustrated.")
        }

        switch depth {
        case .minimal:
            lines.append("Response length: VERY brief (1-2 sentences max).")
        case .concise:
            lines.append("Response length: Brief but informative.")
        case .standard:
            break
        case .thorough:
            lines.append("Response length: Detailed exploration is welcome.")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Engagement Tracking

    private func trackEngagement(userMessageLength: Int, previousResponseLength: Int) {
        engagementLock.lock()

        engagement.totalInteractions += 1

        if previousResponseLength > 500 {
            if userMessageLength < 30 {
                engagement.shortResponseCount += 1
            } else if userMessageLength > 100 {
                engagement.longResponseCount += 1
            }
        }

        if userMessageLength > 50 && previousResponseLength > 200 {
            engagement.skipCount += 1
        }

        // Snapshot the profile while still holding the lock, then release and
        // encode/persist the COPY. Encoding after the unlock (the previous `defer`)
        // raced a concurrent mutation of `engagement`.
        let snapshot = engagement
        engagementLock.unlock()

        saveEngagement(snapshot)
    }

    // MARK: - Persistence

    private func loadEngagement() {
        guard let url = storageURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            engagement = try JSONDecoder().decode(EngagementProfile.self, from: data)
        } catch {
            print("[AdaptiveResponse] Failed to load engagement: \(error)")
        }
    }

    /// Persist a snapshot of the engagement profile. Callers must pass a value
    /// captured under `engagementLock` so encoding never races a live mutation.
    private func saveEngagement(_ snapshot: EngagementProfile) {
        guard let url = storageURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[AdaptiveResponse] Failed to save engagement: \(error)")
        }
    }
}
