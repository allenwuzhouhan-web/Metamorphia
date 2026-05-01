import Foundation

// MARK: - ContinuationProposal

/// A scored, human-readable recommendation to surface a story to the user.
/// High-score proposals represent genuine continuations of active threads in
/// the interest graph + recent conversation; low-score proposals are filtered
/// before returning from `propose(since:maxResults:)`.
public struct ContinuationProposal: Sendable, Hashable, Identifiable {
    public var id: UUID { story.id }
    public let story: Story
    /// Composite relevance score, roughly [0, 1] (may slightly exceed 1 before
    /// the ubiquity penalty is applied; clipped at call sites when needed).
    public let score: Double
    /// Human-readable reasons, shortest first, max 3.
    public let reasons: [String]
    /// The canonical entity that drove the highest interest-graph contribution.
    public let primaryEntity: String?
    /// True when at least one story entity has a non-zero interest-graph score.
    public let hasInterestSignal: Bool
    /// True when at least one story entity appears in recent conversation turns.
    public let hasMemorySignal: Bool

    public init(
        story: Story,
        score: Double,
        reasons: [String],
        primaryEntity: String?,
        hasInterestSignal: Bool,
        hasMemorySignal: Bool
    ) {
        self.story = story
        self.score = score
        self.reasons = reasons
        self.primaryEntity = primaryEntity
        self.hasInterestSignal = hasInterestSignal
        self.hasMemorySignal = hasMemorySignal
    }

    // MARK: - Hashable / Equatable

    public static func == (lhs: ContinuationProposal, rhs: ContinuationProposal) -> Bool {
        lhs.story.id == rhs.story.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(story.id)
    }
}

// MARK: - ThreadContinuationEngine

/// Scores stories from `StoryTracker` against the user's interest graph and
/// recent conversation turns to produce `ContinuationProposal`s. Only stories
/// that connect to an active thread in the graph *or* were mentioned recently
/// in conversation are ever surfaced; purely trending stories with no user
/// signal are dropped.
///
/// Scoring formula (all components are [0, 1]):
/// ```
/// interestWeight = Σ interestGraph.score(e) for e in story.entities
/// memoryHit      = 1.0 if any story entity appears in recent turn entities
/// novelty        = min(1.0, newEntities / max(1, story.entities.count))
/// ubiquity       = min(1.0, story.articles.count / ubiquityThreshold)
///
/// score = alpha  * normalize(interestWeight, cap: 3.0)
///       + beta   * memoryHit
///       + gamma  * novelty
///       - delta  * ubiquity
/// ```
///
/// Filter: drop any story with `score < 0.2` OR with zero interest + zero
/// memory hit. This enforces the "never surface without a thread" principle.
public actor ThreadContinuationEngine {

    // MARK: - Configuration

    private let storyTracker: StoryTracker
    private let interestGraph: InterestGraphStore
    private let conversationTurnsProvider: @Sendable () async -> [String]
    private let aliasStore: EntityAliasStore
    private let termFrequency: RollingTermFrequency

    /// Weight applied to the normalized interest-graph sum.
    private let alpha: Double
    /// Weight applied to the memory-hit flag.
    private let beta: Double
    /// Weight applied to the novelty bonus.
    private let gamma: Double
    /// Penalty subtracted for ubiquitous (widely-reported) stories.
    private let delta: Double

    private let recentTurnsWindowDays: Int
    /// Number of articles in a story above which it is considered ubiquitous.
    private let ubiquityThreshold: Int

    // MARK: - Lifecycle

    public init(
        stories: StoryTracker,
        interestGraph: InterestGraphStore,
        conversationTurnsProvider: @Sendable @escaping () async -> [String] = { [] },
        aliasStore: EntityAliasStore = EntityAliasStore(),
        termFrequency: RollingTermFrequency = RollingTermFrequency(),
        alpha: Double = 0.5,
        beta: Double = 0.3,
        gamma: Double = 0.15,
        delta: Double = 0.2,
        recentTurnsWindowDays: Int = 14,
        ubiquityThreshold: Int = 5
    ) {
        self.storyTracker = stories
        self.interestGraph = interestGraph
        self.conversationTurnsProvider = conversationTurnsProvider
        self.aliasStore = aliasStore
        self.termFrequency = termFrequency
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
        self.delta = delta
        self.recentTurnsWindowDays = recentTurnsWindowDays
        self.ubiquityThreshold = ubiquityThreshold
    }

    // MARK: - Public API

    /// Score every story currently tracked by `StoryTracker`. Returns ALL
    /// scored proposals sorted descending — no threshold filter applied here,
    /// which is intentional for downstream testing and debugging.
    public func scoreAll(maxResults: Int = 20) async -> [ContinuationProposal] {
        let allStories = await storyTracker.allStories()
        let (recentTurnText, recentTurnEntities) = await buildRecentTurnContext()

        var proposals: [ContinuationProposal] = []
        for story in allStories {
            let proposal = await score(story: story,
                                       recentTurnText: recentTurnText,
                                       recentTurnEntities: recentTurnEntities)
            proposals.append(proposal)
        }

        proposals.sort { $0.score > $1.score }
        return Array(proposals.prefix(maxResults))
    }

    /// Score and filter stories whose `lastArticleAt` is on or after `cutoff`
    /// (defaults to 7 days ago). Applies the `score < 0.2` and zero-signal
    /// drop rules. This is the "morning brief" API.
    public func propose(since cutoff: Date? = nil, maxResults: Int = 5) async -> [ContinuationProposal] {
        let effectiveCutoff = cutoff ?? Date().addingTimeInterval(-7 * 86_400)
        let allStories = await storyTracker.allStories()
        let recent = allStories.filter { $0.lastArticleAt >= effectiveCutoff }

        let (recentTurnText, recentTurnEntities) = await buildRecentTurnContext()

        var proposals: [ContinuationProposal] = []
        for story in recent {
            let proposal = await score(story: story,
                                       recentTurnText: recentTurnText,
                                       recentTurnEntities: recentTurnEntities)

            // Filter 1: must exceed minimum relevance threshold.
            guard proposal.score >= 0.2 else { continue }

            // Filter 2: must have at least one signal (interest or memory).
            // This enforces "never show news without a thread" at the API level.
            guard proposal.hasInterestSignal || proposal.hasMemorySignal else { continue }

            proposals.append(proposal)
        }

        proposals.sort { $0.score > $1.score }
        return Array(proposals.prefix(maxResults))
    }

    /// Score a single story against supplied turn context. Useful for ad-hoc
    /// "is this story relevant right now?" probes.
    public func score(
        story: Story,
        recentTurnText: String,
        recentTurnEntities: Set<String>
    ) async -> ContinuationProposal {

        let entities = story.entities

        // --- interestWeight: top-3 entity scores, batched via TaskGroup -------
        // Using the top-3 sum rather than the full sum prevents stories with
        // many peripheral entities from outscoring stories with one strong anchor.
        // The TaskGroup also amortises actor-hop cost for large entity lists.
        let topScores: [(String, Double)] = await withTaskGroup(of: (String, Double).self) { group in
            for entity in entities {
                group.addTask { (entity, await self.interestGraph.score(entity: entity)) }
            }
            var results: [(String, Double)] = []
            for await pair in group { results.append(pair) }
            return results
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)
        .map { $0 }

        let interestWeight = topScores.reduce(0.0) { $0 + $1.1 }
        let topEntity: String? = topScores.first?.0

        // --- memoryHit --------------------------------------------------------
        let memoryHit: Double = entities.intersection(recentTurnEntities).isEmpty ? 0.0 : 1.0

        // The entity that drove the memory hit (for reason text).
        let memoryEntity: String? = {
            guard memoryHit > 0 else { return nil }
            return entities.intersection(recentTurnEntities).sorted().first
        }()

        // --- novelty: entities not present before story.userLastCheckedAt -----
        /// Novelty is 1.0 for brand-new stories the user has never checked.
        /// This is intentional: we want new stories to be *potentially* surfaceable
        /// on their first appearance. The other gates (interestWeight > 0 OR memoryHit)
        /// prevent brand-new zero-interest stories from passing.
        let checkpointDate = story.userLastCheckedAt ?? story.firstSeenAt
        let entitiesBeforeCheckpoint: Set<String> = story.articles
            .filter { $0.publishedAt < checkpointDate }
            .reduce(into: Set()) { $0.formUnion($1.extractedEntities) }

        let newEntitiesCount = entities.subtracting(entitiesBeforeCheckpoint).count
        let novelty = min(1.0, Double(newEntitiesCount) / Double(max(1, entities.count)))

        // Track the single brand-new entity for fine-grained reason text.
        let newEntities = entities.subtracting(entitiesBeforeCheckpoint)
        let singleNewEntity: String? = newEntities.count == 1 ? newEntities.first : nil

        // --- ubiquity: article count relative to threshold --------------------
        let ubiquity = min(1.0, Double(story.articles.count) / Double(ubiquityThreshold))

        // --- composite score --------------------------------------------------
        let normalizedInterest = min(1.0, interestWeight / 3.0)   // normalize(x, cap: 3)
        let rawScore = alpha * normalizedInterest
                     + beta  * memoryHit
                     + gamma * novelty
                     - delta * ubiquity

        // --- reasons (shortest first, max 3) ----------------------------------
        var rawReasons: [(text: String, isDownweight: Bool)] = []

        if interestWeight > 0.5, let entity = topEntity {
            rawReasons.append(("continues your \(entity) thread", false))
        }

        if memoryHit > 0, let entity = memoryEntity {
            rawReasons.append(("you mentioned \(entity) recently", false))
        }

        if novelty > 0.3 {
            if let entity = singleNewEntity {
                rawReasons.append(("novel: first mention of \(entity) in months", false))
            } else {
                rawReasons.append(("new developments since your last check", false))
            }
        }

        if ubiquity > 0.5 {
            rawReasons.append(("widely reported — likely already on your radar", true))
        }

        // Sort: downweight flags last, then ascending length (shortest first).
        rawReasons.sort {
            if $0.isDownweight != $1.isDownweight { return !$0.isDownweight }
            return $0.text.count < $1.text.count
        }

        let reasons = Array(rawReasons.prefix(3).map(\.text))

        return ContinuationProposal(
            story: story,
            score: rawScore,
            reasons: reasons,
            primaryEntity: topEntity,
            hasInterestSignal: interestWeight > 0,
            hasMemorySignal: memoryHit > 0
        )
    }

    // MARK: - Private helpers

    /// Fetch recent user turns and extract entities from them on the fly.
    /// Returns the concatenated text plus the union entity set.
    private func buildRecentTurnContext() async -> (text: String, entities: Set<String>) {
        let turns = await conversationTurnsProvider()
        guard !turns.isEmpty else { return ("", []) }

        let combinedText = turns.joined(separator: " ")

        let extractor = EntityExtractor(aliasStore: aliasStore, termFrequency: termFrequency)
        let extracted = await extractor.extract(combinedText)
        let entitySet = Set(extracted.map { $0.canonicalName })

        return (combinedText, entitySet)
    }
}

// MARK: - DEBUG demo

#if DEBUG
public extension ThreadContinuationEngine {

    /// In-memory demo: seeds 5 orgs in the interest graph and 5 synthetic
    /// stories, then returns the top-3 proposals. Useful for manual scoring
    /// verification without running the full app.
    ///
    /// Expected top-3 (approximate):
    ///   1. "Anthropic interpretability" story — high interest + memory hit
    ///   2. "OpenAI regulations" story — moderate interest, some novelty
    ///   3. "Swift concurrency" story — interest-graph hit only
    static func demo() async -> [ContinuationProposal] {
        let tracker = StoryTracker(location: nil)
        let graph = InterestGraphStore(location: nil)

        // Seed interest graph: anthropic 0.7, interpretability 0.3, openai 0.5,
        // regulation 0.2, swift 0.4.
        await graph.potentiate(entity: "anthropic",          type: .org,   event: .queryMention, scale: 1.0)
        await graph.potentiate(entity: "anthropic",          type: .org,   event: .queryMention, scale: 1.0)
        await graph.potentiate(entity: "anthropic",          type: .org,   event: .toolCallSubject, scale: 1.0)
        await graph.potentiate(entity: "interpretability",   type: .topic, event: .queryMention, scale: 1.0)
        await graph.potentiate(entity: "openai",             type: .org,   event: .queryMention, scale: 1.0)
        await graph.potentiate(entity: "openai",             type: .org,   event: .clipboardCopy, scale: 1.0)
        await graph.potentiate(entity: "regulation",         type: .topic, event: .longDwell,    scale: 1.0)
        await graph.potentiate(entity: "swift",              type: .topic, event: .queryMention, scale: 1.0)
        await graph.potentiate(entity: "swift",              type: .org,   event: .clipboardCopy, scale: 1.0)

        let now = Date()

        // Story 1: Anthropic + interpretability — strong interest + memory hit candidate.
        let story1 = Story(
            title: "Anthropic publishes interpretability research",
            entities: ["anthropic", "interpretability"],
            firstSeenAt: now.addingTimeInterval(-2 * 86_400),
            lastArticleAt: now.addingTimeInterval(-3_600),
            articles: [
                StoryArticleRef(articleId: "a1", title: "Anthropic interpretability paper",
                                source: "TechCrunch", publishedAt: now.addingTimeInterval(-3_600),
                                snippet: "", extractedEntities: ["anthropic", "interpretability"],
                                feedOrigin: "tech")
            ]
        )

        // Story 2: OpenAI + regulation — moderate interest.
        let story2 = Story(
            title: "OpenAI faces new EU regulation",
            entities: ["openai", "regulation", "european union"],
            firstSeenAt: now.addingTimeInterval(-3 * 86_400),
            lastArticleAt: now.addingTimeInterval(-7_200),
            articles: (0..<3).map { i in
                StoryArticleRef(articleId: "b\(i)", title: "OpenAI EU \(i)",
                                source: "Reuters", publishedAt: now.addingTimeInterval(-Double(i) * 3_600),
                                snippet: "", extractedEntities: ["openai", "regulation"],
                                feedOrigin: "business")
            }
        )

        // Story 3: Swift concurrency — moderate interest only.
        let story3 = Story(
            title: "Swift concurrency improvements in Xcode",
            entities: ["swift", "xcode", "apple"],
            firstSeenAt: now.addingTimeInterval(-4 * 86_400),
            lastArticleAt: now.addingTimeInterval(-12_000),
            articles: [
                StoryArticleRef(articleId: "c1", title: "Swift actors improved",
                                source: "9to5Mac", publishedAt: now.addingTimeInterval(-12_000),
                                snippet: "", extractedEntities: ["swift", "xcode", "apple"],
                                feedOrigin: "tech")
            ]
        )

        // Story 4: Celebrity gossip — zero interest graph hits, should be dropped by propose().
        let story4 = Story(
            title: "Celebrity scandal",
            entities: ["celebrity", "scandal"],
            firstSeenAt: now.addingTimeInterval(-1 * 86_400),
            lastArticleAt: now.addingTimeInterval(-1_800),
            articles: (0..<12).map { i in
                StoryArticleRef(articleId: "d\(i)", title: "Gossip \(i)",
                                source: "TMZ", publishedAt: now.addingTimeInterval(-Double(i) * 900),
                                snippet: "", extractedEntities: ["celebrity", "scandal"],
                                feedOrigin: "entertainment")
            }
        )

        // Story 5: Climate + policy — weak interest via regulation, some novelty.
        let story5 = Story(
            title: "Climate policy summit",
            entities: ["climate", "policy", "regulation"],
            firstSeenAt: now.addingTimeInterval(-5 * 86_400),
            lastArticleAt: now.addingTimeInterval(-5_400),
            articles: (0..<2).map { i in
                StoryArticleRef(articleId: "e\(i)", title: "Climate \(i)",
                                source: "BBC", publishedAt: now.addingTimeInterval(-Double(i) * 1_800),
                                snippet: "", extractedEntities: ["climate", "policy", "regulation"],
                                feedOrigin: "world")
            }
        )

        await tracker.ingest(articles: story1.articles)
        await tracker.ingest(articles: story2.articles)
        await tracker.ingest(articles: story3.articles)
        await tracker.ingest(articles: story4.articles)
        await tracker.ingest(articles: story5.articles)

        // Simulate a recent turn that mentioned "anthropic".
        let engine = ThreadContinuationEngine(
            stories: tracker,
            interestGraph: graph,
            conversationTurnsProvider: { ["Tell me more about the Anthropic interpretability work"] }
        )

        return await engine.propose(since: now.addingTimeInterval(-7 * 86_400), maxResults: 5)
    }
}
#endif
