import Foundation

/// Confidence-scored intent classification.
///
/// Wraps `ToolRegistry.classifyQueryIntent` with weighted scores, historical learning,
/// and session context. Three signals combine:
///   1. **Keyword match** — weighted by match quality (length, word boundary, count).
///   2. **Historical learning** — patterns of which tools were actually used for
///      similar queries, persisted to `intent_history.json`.
///   3. **Session context** — recently-used tools bias related categories.
///
/// Ported from Executer. Hardcoded `~/Library/Application Support/Executer/` path
/// → configurable URL at init. `ToolRegistry.shared` static dependency →
/// `ToolRegistry` injected via init.
public final class IntentScorer: @unchecked Sendable {

    // MARK: - Scored Result

    public struct ScoredCategory: Comparable, Sendable {
        public let category: ToolCategory
        public let score: Double
        public let sources: Set<Source>

        public enum Source: String, Sendable {
            case keyword
            case history
            case session
            case alwaysOn
        }

        public static func < (lhs: ScoredCategory, rhs: ScoredCategory) -> Bool {
            lhs.score < rhs.score
        }

        public init(category: ToolCategory, score: Double, sources: Set<Source>) {
            self.category = category
            self.score = score
            self.sources = sources
        }
    }

    // MARK: - Historical Learning

    /// Per-pattern memory of which tool categories tended to satisfy queries
    /// of this shape. Conforms to `Potentiated` so weights decay over time
    /// and reinforce on recall — patterns you used last year don't dominate
    /// today's tool routing.
    private struct PatternHistory: Codable, Potentiated {
        var categoryWeights: [String: SynapticStrength]
        var totalQueries: Int
        var strength: SynapticStrength
        var lastAccessed: Date
        var accessCount: Int
        var createdAt: Date

        static var decayTau: TimeInterval { SynapseDefaults.tauProcedural }

        /// Decay the pattern strength AND every category weight in lockstep.
        /// The default `lazilyDecay` only touches the pattern itself; this
        /// extends decay to the per-category synapses since they were all
        /// reinforced together (Hebbian) and should fade together with disuse.
        mutating func ageAll(now: Date = Date()) {
            let elapsed = now.timeIntervalSince(lastAccessed)
            guard elapsed > 0 else { return }
            let tau = Self.decayTau
            strength.decay(elapsed: elapsed, tau: tau)
            for key in categoryWeights.keys {
                categoryWeights[key]?.decay(elapsed: elapsed, tau: tau)
            }
            lastAccessed = now
        }
    }

    private var history: [String: PatternHistory] = [:]
    private let historyLock = NSLock()
    private let storageURL: URL?
    private let maxPatterns = 500

    // MARK: - Session Context

    private var sessionToolNames: [String] = []
    private let sessionLock = NSLock()

    // MARK: - Registry Reference

    private let registry: ToolRegistry

    /// - Parameters:
    ///   - registry: The tool registry to query categories from.
    ///   - storageURL: Where to persist the learned-history JSON, or `nil` to run
    ///     in-memory only. The app target passes a Metamorphia-specific path.
    public init(registry: ToolRegistry, storageURL: URL? = nil) {
        self.registry = registry
        self.storageURL = storageURL
        loadHistory()
    }

    // MARK: - Public API

    /// Score all categories for a query. Higher score = more confident.
    public func scoreIntent(query: String, recentTools: [String] = []) -> [ScoredCategory] {
        let lower = query.lowercased()
        var scores: [ToolCategory: (score: Double, sources: Set<ScoredCategory.Source>)] = [:]

        for cat in ToolCategory.allCases {
            scores[cat] = (0.0, [])
        }

        // 1. Keyword scoring
        for entry in ToolRegistry.intentKeywords {
            var matchStrength = 0.0
            var matchCount = 0

            for keyword in entry.keywords {
                if lower.contains(keyword) {
                    matchCount += 1
                    let lengthBonus = min(Double(keyword.count) / 20.0, 0.3)
                    let wordBoundary = isWordBoundaryMatch(query: lower, keyword: keyword)
                    let boundaryBonus = wordBoundary ? 0.2 : 0.0
                    matchStrength += 0.4 + lengthBonus + boundaryBonus
                }
            }

            if matchCount > 0 {
                let groupScore = min(matchStrength, 1.0)
                for cat in entry.categories {
                    let current = scores[cat] ?? (0.0, [])
                    scores[cat] = (max(current.score, groupScore), current.sources.union([.keyword]))
                }
            }
        }

        // 2. Historical learning — age the pattern (and its per-category
        //    synapses) so stale weights fade before scoring. Snapshot under
        //    lock, mutate in place.
        let pattern = normalizePattern(query)
        let now = Date()
        historyLock.lock()
        if history[pattern] != nil {
            history[pattern]!.ageAll(now: now)
        }
        let patternHist = history[pattern]
        historyLock.unlock()

        if let hist = patternHist, hist.totalQueries >= 2 {
            for (catRaw, weight) in hist.categoryWeights {
                guard let cat = ToolCategory(rawValue: catRaw) else { continue }
                let histScore = weight.value * 0.8
                let current = scores[cat] ?? (0.0, [])
                let blended = max(current.score, histScore) + min(current.score, histScore) * 0.2
                scores[cat] = (min(blended, 1.0), current.sources.union([.history]))
            }
        }

        // 3. Session context
        sessionLock.lock()
        let recentSessionTools = sessionToolNames
        sessionLock.unlock()
        let allRecent = recentTools + recentSessionTools

        if !allRecent.isEmpty {
            let recentCategories = allRecent.compactMap { registry.categoryForTool($0) }
            let catCounts = Dictionary(recentCategories.map { ($0, 1) }, uniquingKeysWith: +)

            for (cat, count) in catCounts {
                let sessionScore = min(Double(count) * 0.15, 0.4)
                let current = scores[cat] ?? (0.0, [])
                scores[cat] = (min(current.score + sessionScore, 1.0), current.sources.union([.session]))
            }
        }

        // 4. Always-included baseline
        let alwaysOn: Set<ToolCategory> = [.memory, .skills, .clipboard, .mcp]
        for cat in alwaysOn {
            let current = scores[cat] ?? (0.0, [])
            scores[cat] = (max(current.score, 0.5), current.sources.union([.alwaysOn]))
        }

        // 5. Cross-category rules
        applyRules(&scores)

        return scores.map { ScoredCategory(category: $0.key, score: $0.value.score, sources: $0.value.sources) }
            .sorted(by: >)
    }

    /// Filter to categories above a confidence threshold.
    public func classifyWithConfidence(
        query: String,
        threshold: Double = 0.25,
        recentTools: [String] = []
    ) -> Set<ToolCategory> {
        let scored = scoreIntent(query: query, recentTools: recentTools)
        var result = Set(scored.filter { $0.score >= threshold }.map { $0.category })

        let alwaysOn: Set<ToolCategory> = [.memory, .skills, .clipboard, .mcp]
        if result.subtracting(alwaysOn).isEmpty {
            result.formUnion([
                .files, .fileContent, .fileSearch,
                .appControl, .windows, .keyboard, .cursor,
                .terminal, .systemBash, .systemInfo,
                .productivity, .documents, .screenshot,
            ])
        }

        return result
    }

    // MARK: - Learning

    /// Record which tools were used for a query. Reinforces both the pattern
    /// itself (familiarity) and each matched category's weight (LTP).
    public func recordOutcome(query: String, toolsUsed: [String]) {
        guard !toolsUsed.isEmpty else { return }
        let pattern = normalizePattern(query)

        let categories = Set(toolsUsed.compactMap { registry.categoryForTool($0) })
        guard !categories.isEmpty else { return }

        let now = Date()
        historyLock.lock()
        var entry = history[pattern] ?? PatternHistory(
            categoryWeights: [:],
            totalQueries: 0,
            strength: SynapticStrength(SynapseDefaults.baseline),
            lastAccessed: now,
            accessCount: 0,
            createdAt: now
        )
        entry.ageAll(now: now)
        entry.totalQueries += 1
        entry.reinforceOnRecall(now: now)
        for cat in categories {
            var w = entry.categoryWeights[cat.rawValue] ?? SynapticStrength(SynapseDefaults.baseline)
            w.reinforce()
            entry.categoryWeights[cat.rawValue] = w
        }
        history[pattern] = entry

        if history.count > maxPatterns {
            // Forgetting curve: drop the weakest patterns, not the oldest.
            let sorted = history.sorted { $0.value.strength.value < $1.value.strength.value }
            let toDrop = sorted.prefix(history.count - maxPatterns)
            for (key, _) in toDrop {
                history.removeValue(forKey: key)
            }
        }

        historyLock.unlock()
        saveHistory()
    }

    public func updateSessionTools(_ tools: [String]) {
        sessionLock.lock()
        sessionToolNames = Array(tools.suffix(20))
        sessionLock.unlock()
    }

    public func resetSession() {
        sessionLock.lock()
        sessionToolNames.removeAll()
        sessionLock.unlock()
    }

    // MARK: - Cross-Category Rules

    private func applyRules(_ scores: inout [ToolCategory: (score: Double, sources: Set<ScoredCategory.Source>)]) {
        if (scores[.media]?.score ?? 0) > 0.3 {
            scores[.web] = (0.0, [])
            scores[.webContent] = (0.0, [])
            scores[.browser] = (0.0, [])
        }

        if (scores[.web]?.score ?? 0) > 0.3 || (scores[.webContent]?.score ?? 0) > 0.3 {
            let boost: (Double, Set<ScoredCategory.Source>) = (0.5, [.keyword])
            for cat: ToolCategory in [.cursor, .keyboard, .browser] {
                let current = scores[cat] ?? (0.0, [])
                if current.score < boost.0 {
                    scores[cat] = (boost.0, current.sources.union(boost.1))
                }
            }
        }

        let uiCategories: [ToolCategory] = [.cursor, .appControl, .windows, .browser, .screenshot]
        if uiCategories.contains(where: { (scores[$0]?.score ?? 0) > 0.3 }) {
            let current = scores[.keyboard] ?? (0.0, [])
            if current.score < 0.5 {
                scores[.keyboard] = (0.5, current.sources.union([.keyword]))
            }
        }
    }

    // MARK: - Pattern Normalization

    private func normalizePattern(_ query: String) -> String {
        var words = query.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 2 }

        words = words.filter { word in
            if word.allSatisfy({ $0.isNumber }) { return false }
            if word.hasPrefix(".") { return false }
            return true
        }

        let canonical = words.sorted().prefix(8)
        return canonical.joined(separator: " ")
    }

    private func isWordBoundaryMatch(query: String, keyword: String) -> Bool {
        guard let range = query.range(of: keyword) else { return false }

        let beforeOK = range.lowerBound == query.startIndex
            || !query[query.index(before: range.lowerBound)].isLetter
        let afterOK = range.upperBound == query.endIndex
            || !query[range.upperBound].isLetter

        return beforeOK && afterOK
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let url = storageURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            history = try JSONDecoder().decode([String: PatternHistory].self, from: data)
            print("[IntentScorer] Loaded \(history.count) learned patterns")
        } catch {
            print("[IntentScorer] Failed to load history: \(error)")
        }
    }

    private func saveHistory() {
        guard let url = storageURL else { return }
        // Snapshot under the lock so `JSONEncoder.encode` doesn't read the
        // dictionary concurrently with a `recordOutcome` call on another
        // thread. The encode itself is done outside the critical section.
        historyLock.lock()
        let snapshot = history
        historyLock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[IntentScorer] Failed to save history: \(error)")
        }
    }
}
