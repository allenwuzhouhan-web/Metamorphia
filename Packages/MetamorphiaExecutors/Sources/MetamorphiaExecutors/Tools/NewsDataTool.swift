import Foundation
import MetamorphiaAgentKit

/// LLM-facing tool for news retrieval. Action-dispatched (one tool, many
/// verbs) to keep the catalog lean — one `news_feed` entry rather than five.
///
/// Data path for Google News actions:
///   LLM → `execute(arguments:)` → `GoogleNewsService` → `AnonymizedNewsFetcher`
///        → `RSSParser` → `[NewsArticle]` → JSON response string → LLM
///
/// Phase 4 integration: when constructed with a `StoryTracker` reference and
/// the caller passes `"track": true`, fetched articles are piped through
/// `StoryTracker.ingest` after the response is encoded. Entity extraction
/// is performed on-device via `EntityExtractor` before building the
/// `StoryArticleRef` values.
public struct NewsDataTool: ToolDefinition {
    public let name = "news_feed"
    public let description = """
        Fetch current news articles from Google News and related feeds. \
        Use `action` to pick the operation. No API key required. \
        Returns articles sorted newest-first with title, link, source, and snippet.
        """

    /// Optional `StoryTracker` injected at construction. When non-nil and the
    /// `track` argument is `true`, fetched articles are ingested into the tracker.
    private let storyTracker: StoryTracker?
    private let aliasStore: EntityAliasStore?
    private let termFrequency: RollingTermFrequency?

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(
                description: "Which operation to run: top (top stories), section (topic section), search (free-text).",
                values: ["top", "section", "search"]
            ),
            "section": JSONSchema.enumString(
                description: "News section for 'section' action.",
                values: NewsSection.allCases.map(\.rawValue)
            ),
            "query": JSONSchema.string(description: "Search query for 'search' action (e.g. 'OpenAI board')."),
            "locale": JSONSchema.string(description: "BCP-47 locale string (e.g. 'en-US', 'fr-FR'). Defaults to 'en-US'."),
            "track": JSONSchema.boolean(description: "When true, pipe fetched articles through StoryTracker for narrative clustering. Default false."),
        ], required: ["action"])
    }

    /// Construct a tool without story tracking (previous behavior).
    public init() {
        self.storyTracker = nil
        self.aliasStore = nil
        self.termFrequency = nil
    }

    /// Construct a tool with story tracking wired in.
    ///
    /// - Parameters:
    ///   - storyTracker: The shared `StoryTracker` to ingest articles into.
    ///   - aliasStore: Entity alias store for `EntityExtractor`.
    ///   - termFrequency: Rolling term frequency for `EntityExtractor`.
    public init(
        storyTracker: StoryTracker,
        aliasStore: EntityAliasStore,
        termFrequency: RollingTermFrequency
    ) {
        self.storyTracker = storyTracker
        self.aliasStore = aliasStore
        self.termFrequency = termFrequency
    }

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = (args["action"] as? String ?? "top").lowercased()
        let locale = (args["locale"] as? String) ?? "en-US"
        let shouldTrack = (args["track"] as? Bool) ?? false
        let service = GoogleNewsService()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let articles: [NewsArticle]
            switch action {
            case "top":
                articles = try await service.topStories(locale: locale)

            case "section":
                guard let sectionRaw = args["section"] as? String,
                      let section = NewsSection(rawValue: sectionRaw.lowercased()) else {
                    return errorJSON("'section' action requires a valid 'section' parameter. Valid values: \(NewsSection.allCases.map(\.rawValue).joined(separator: ", ")).", retryable: false)
                }
                articles = try await service.section(section, locale: locale)

            case "search":
                guard let query = args["query"] as? String, !query.isEmpty else {
                    return errorJSON("'search' action requires a non-empty 'query' parameter.", retryable: false)
                }
                articles = try await service.search(query: query, locale: locale)

            case "story_thread":
                return errorJSON("action not yet available (Phase 5)", retryable: false)

            case "since_last_check":
                return errorJSON("action not yet available (Phase 5)", retryable: false)

            default:
                return errorJSON("Unknown action '\(action)'. Supported: top, section, search.", retryable: false)
            }

            let response = encode(articles, encoder: encoder)

            // Phase 4 integration: ingest articles into StoryTracker when requested.
            // Fire-and-forget: the LLM receives the articles JSON immediately; tracking
            // runs in a detached utility Task so it does not delay the response path.
            if shouldTrack, let tracker = storyTracker, let aliasStore = aliasStore, let tf = termFrequency {
                let articlesCopy = articles  // capture by value
                Task.detached(priority: .utility) {
                    let refs = await Self.buildArticleRefs(articles: articlesCopy, aliasStore: aliasStore, termFrequency: tf)
                    await tracker.ingest(articles: refs)
                }
            }

            return response

        } catch let e as GoogleNewsService.ServiceError {
            switch e {
            case .emptyFeed:
                return errorJSON("Google News returned an empty feed. The query may be too specific or the service may be temporarily unavailable.", retryable: true)
            case .parseFailed(let reason):
                return errorJSON("Feed parse failed: \(reason)", retryable: true)
            }
        } catch {
            // Network errors, timeouts — retryable.
            return errorJSON(error.localizedDescription, retryable: true)
        }
    }

    // MARK: - Story tracking helpers

    /// Build `StoryArticleRef` values by extracting entities from each article's
    /// title + snippet using the shared `EntityExtractor`. Static so it can be
    /// called from a detached `Task` without capturing `self`.
    private static func buildArticleRefs(
        articles: [NewsArticle],
        aliasStore: EntityAliasStore,
        termFrequency: RollingTermFrequency
    ) async -> [StoryArticleRef] {
        let extractor = EntityExtractor(aliasStore: aliasStore, termFrequency: termFrequency)
        var refs: [StoryArticleRef] = []
        for article in articles {
            let text = article.title + " " + article.snippet
            let extracted = await extractor.extract(text)
            refs.append(StoryArticleRef(
                articleId: article.link,
                title: article.title,
                source: article.source,
                publishedAt: article.publishedAt,
                snippet: article.snippet,
                extractedEntities: extracted.map(\.canonicalName),
                feedOrigin: article.feedOrigin.rawValue
            ))
        }
        return refs
    }

    // MARK: - Encoding helpers

    private func encode(_ articles: [NewsArticle], encoder: JSONEncoder) -> String {
        let payload = FeedPayload(
            articles: articles.map(ArticleDTO.init),
            count: articles.count,
            fetchedAt: Date()
        )
        guard let data = try? encoder.encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return errorJSON("Failed to encode response.", retryable: false)
        }
        return str
    }

    private func errorJSON(_ message: String, retryable: Bool) -> String {
        // Escape message for inline JSON construction.
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"error\": \"\(escaped)\", \"retryable\": \(retryable)}"
    }

    // MARK: - Wire types

    private struct FeedPayload: Encodable {
        let articles: [ArticleDTO]
        let count: Int
        let fetchedAt: Date

        enum CodingKeys: String, CodingKey {
            case articles, count
            case fetchedAt = "fetched_at"
        }
    }

    private struct ArticleDTO: Encodable {
        let title: String
        let link: String
        let source: String
        let publishedAt: String
        let snippet: String

        init(_ article: NewsArticle) {
            self.title = article.title
            self.link = article.link
            self.source = article.source
            // Encode date as ISO 8601 string manually to keep consistent
            // formatting without a custom encoder on each field.
            self.publishedAt = ISO8601DateFormatter().string(from: article.publishedAt)
            self.snippet = article.snippet
        }
    }
}
