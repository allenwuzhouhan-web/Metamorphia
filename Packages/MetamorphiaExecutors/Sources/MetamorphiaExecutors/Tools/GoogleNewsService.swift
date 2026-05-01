import Foundation

/// Fetches articles from Google News's unauthenticated RSS endpoints.
///
/// Three operations: top stories, section-filtered headlines, and free-text
/// search. All results are sorted newest-first and capped at 50 articles.
/// No API key is required — Google News exposes these RSS URLs publicly.
public struct GoogleNewsService: Sendable {
    private let fetcher: AnonymizedNewsFetcher
    private let parser: RSSParser

    public init(
        fetcher: AnonymizedNewsFetcher = AnonymizedNewsFetcher(),
        parser: RSSParser = RSSParser()
    ) {
        self.fetcher = fetcher
        self.parser = parser
    }

    // MARK: - Public API

    /// Top stories for the given locale (e.g. `"en-US"`, `"fr-FR"`).
    public func topStories(locale: String = "en-US") async throws -> [NewsArticle] {
        let url = try topURL(locale: locale)
        return try await fetchAndParse(url)
    }

    /// Section-filtered headlines (business, technology, etc.).
    public func section(_ section: NewsSection, locale: String = "en-US") async throws -> [NewsArticle] {
        let url = try sectionURL(section, locale: locale)
        return try await fetchAndParse(url)
    }

    /// Free-text search — good for entity queries like "OpenAI board".
    public func search(query: String, locale: String = "en-US") async throws -> [NewsArticle] {
        let url = try searchURL(query: query, locale: locale)
        return try await fetchAndParse(url)
    }

    // MARK: - Errors

    public enum ServiceError: Error, LocalizedError {
        case emptyFeed
        case parseFailed(reason: String)

        public var errorDescription: String? {
            switch self {
            case .emptyFeed:              return "Google News returned an empty feed."
            case .parseFailed(let r):     return "Feed parse failed: \(r)"
            }
        }
    }

    // MARK: - URL construction

    private func topURL(locale: String) throws -> URL {
        let (lang, region) = splitLocale(locale)
        var comps = URLComponents(string: "https://news.google.com/rss")!
        comps.queryItems = [
            URLQueryItem(name: "hl",   value: lang),
            URLQueryItem(name: "gl",   value: region),
            URLQueryItem(name: "ceid", value: "\(region):\(lang)"),
        ]
        return comps.url!
    }

    private func sectionURL(_ section: NewsSection, locale: String) throws -> URL {
        let (lang, region) = splitLocale(locale)
        let topic = section.rawValue.uppercased()
        var comps = URLComponents(
            string: "https://news.google.com/rss/headlines/section/topic/\(topic)"
        )!
        comps.queryItems = [
            URLQueryItem(name: "hl",   value: lang),
            URLQueryItem(name: "gl",   value: region),
            URLQueryItem(name: "ceid", value: "\(region):\(lang)"),
        ]
        return comps.url!
    }

    private func searchURL(query: String, locale: String) throws -> URL {
        let (lang, region) = splitLocale(locale)
        var comps = URLComponents(string: "https://news.google.com/rss/search")!
        comps.queryItems = [
            URLQueryItem(name: "q",    value: query),
            URLQueryItem(name: "hl",   value: lang),
            URLQueryItem(name: "gl",   value: region),
            URLQueryItem(name: "ceid", value: "\(region):\(lang)"),
        ]
        return comps.url!
    }

    /// Split `"en-US"` → `("en", "US")`. Falls back to `"en"` / `"US"` on
    /// malformed input.
    private func splitLocale(_ locale: String) -> (lang: String, region: String) {
        let parts = locale.split(separator: "-", maxSplits: 1).map(String.init)
        let lang   = parts.first ?? "en"
        let region = parts.count > 1 ? parts[1] : "US"
        return (lang, region)
    }

    // MARK: - Fetch + parse + sort + cap

    private func fetchAndParse(_ url: URL) async throws -> [NewsArticle] {
        let data = try await fetcher.fetch(url)
        let articles: [NewsArticle]
        do {
            articles = try parser.parse(data, feedOrigin: .googleNews)
        } catch {
            throw ServiceError.parseFailed(reason: error.localizedDescription)
        }
        guard !articles.isEmpty else { throw ServiceError.emptyFeed }
        return Array(
            articles
                .sorted { $0.publishedAt > $1.publishedAt }
                .prefix(50)
        )
    }
}
