import Foundation

// MARK: - Story

/// A narrative cluster of news articles that share overlapping entities.
/// Stories are assembled by `StoryTracker` via Jaccard entity-overlap; they
/// persist across article churn because `StoryArticleRef` duplicates the
/// narrow fields needed for rendering without referencing `NewsArticle`
/// (which lives in MetamorphiaExecutors — a higher-level package).
public struct Story: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    /// Derived from the first article's title, or updated as the dominant
    /// headline emerges. Writers use `internal(set)` to allow `StoryTracker`
    /// to revise this in-place as better titles arrive.
    public var title: String
    /// Canonical entity ids gathered from all member articles.
    public var entities: Set<String>
    /// When the first article in this story was published.
    public let firstSeenAt: Date
    /// Timestamp of the most recently ingested article.
    public internal(set) var lastArticleAt: Date
    /// Compact article references. The full `NewsArticle` values live upstream
    /// in MetamorphiaExecutors and are not retained here.
    public internal(set) var articles: [StoryArticleRef]
    /// Nil until the user opens the story thread in the UI.
    public internal(set) var userLastCheckedAt: Date?
    /// Rolling polarity history, capped at 50 samples. Used to show sentiment
    /// trajectory over time (improving / declining coverage tone).
    public internal(set) var sentimentTrajectory: [StorySentimentSample]

    public init(
        id: UUID = UUID(),
        title: String,
        entities: Set<String>,
        firstSeenAt: Date,
        lastArticleAt: Date,
        articles: [StoryArticleRef] = [],
        userLastCheckedAt: Date? = nil,
        sentimentTrajectory: [StorySentimentSample] = []
    ) {
        self.id = id
        self.title = title
        self.entities = entities
        self.firstSeenAt = firstSeenAt
        self.lastArticleAt = lastArticleAt
        self.articles = articles
        self.userLastCheckedAt = userLastCheckedAt
        self.sentimentTrajectory = sentimentTrajectory
    }

    // MARK: - Hashable

    public static func == (lhs: Story, rhs: Story) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - StoryArticleRef

/// Compact, self-contained article record kept inside a `Story`.
/// Intentionally does NOT reference `NewsArticle` from MetamorphiaExecutors to
/// avoid a cross-package circular dependency and to survive article churn.
public struct StoryArticleRef: Sendable, Codable, Hashable {
    /// Stable identity — the article's canonical link URL (mirrors `NewsArticle.id`).
    public let articleId: String
    public let title: String
    public let source: String
    public let publishedAt: Date
    public let snippet: String
    /// Entity canonical names extracted from title + snippet.
    public let extractedEntities: [String]
    /// Raw value of `NewsFeedOrigin` kept as a plain string to avoid importing
    /// MetamorphiaExecutors from within MetamorphiaAgentKit.
    public let feedOrigin: String

    public init(
        articleId: String,
        title: String,
        source: String,
        publishedAt: Date,
        snippet: String,
        extractedEntities: [String],
        feedOrigin: String
    ) {
        self.articleId = articleId
        self.title = title
        self.source = source
        self.publishedAt = publishedAt
        self.snippet = snippet
        self.extractedEntities = extractedEntities
        self.feedOrigin = feedOrigin
    }
}

// MARK: - StorySentimentSample

/// A single polarity reading attached to a story at a point in time.
/// Polarity is in `[-1.0, +1.0]` from `NLTagger` `.sentimentScore`.
public struct StorySentimentSample: Sendable, Codable, Hashable {
    public let at: Date
    /// Sentiment polarity in [-1.0, +1.0]. Positive = favorable tone.
    public let polarity: Double

    public init(at: Date, polarity: Double) {
        self.at = at
        self.polarity = polarity
    }
}
