import Foundation
import MetamorphiaExecutors

/// Curated complementary news feeds beyond Google News.
///
/// Each method returns an empty array instead of throwing when the upstream
/// feed is unavailable (404, timeout, deprecated endpoint). Downstream
/// consumers should be resilient to partial data.
public struct NewsSources: Sendable {
    private let fetcher: AnonymizedNewsFetcher
    private let parser: RSSParser

    public init(
        fetcher: AnonymizedNewsFetcher = AnonymizedNewsFetcher(),
        parser: RSSParser = RSSParser()
    ) {
        self.fetcher = fetcher
        self.parser = parser
    }

    // MARK: - HackerNews (Firebase JSON, not RSS)

    /// Top HN stories via the Firebase REST API. Fetches up to `limit` items
    /// concurrently (max 10 at a time).
    public func hackerNewsTop(limit: Int = 20) async throws -> [NewsArticle] {
        let topURL = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json")!
        let data: Data
        do { data = try await fetcher.fetch(topURL) } catch { return [] }

        guard let ids = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        let capped = Array(ids.prefix(limit))

        var articles: [NewsArticle] = []
        await withTaskGroup(of: NewsArticle?.self) { group in
            // Limit concurrency to 10 parallel item fetches.
            let semaphore = AsyncSemaphore(limit: 10)
            for id in capped {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    return await self.fetchHNItem(id: id)
                }
            }
            for await article in group {
                if let a = article { articles.append(a) }
            }
        }
        return articles.sorted { $0.publishedAt > $1.publishedAt }
    }

    private func fetchHNItem(id: Int) async -> NewsArticle? {
        let url = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!
        guard let data = try? await fetcher.fetch(url),
              let item = try? JSONDecoder().decode(HNItem.self, from: data),
              let title = item.title,
              let urlStr = item.url, !urlStr.isEmpty else { return nil }

        return NewsArticle(
            title: title,
            link: urlStr,
            source: "Hacker News",
            publishedAt: Date(timeIntervalSince1970: Double(item.time ?? 0)),
            snippet: item.text.map { stripHNText($0) } ?? "",
            feedOrigin: .hackerNews
        )
    }

    private func stripHNText(_ html: String) -> String {
        var s = html
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
        if let re = try? NSRegularExpression(pattern: "<[^>]+>") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return String(s.prefix(300))
    }

    private struct HNItem: Decodable {
        let title: String?
        let url: String?
        let time: Int?
        let text: String?
    }

    // MARK: - AP Top Headlines

    public func apTopHeadlines() async throws -> [NewsArticle] {
        return await fetchRSS(
            url: URL(string: "https://feeds.apnews.com/apf-topnews")!,
            origin: .ap
        )
    }

    // MARK: - Reuters World

    /// Reuters deprecated most free RSS endpoints in 2023. This URL may 404;
    /// returns empty gracefully when it does.
    public func reutersWorld() async throws -> [NewsArticle] {
        return await fetchRSS(
            url: URL(string: "https://feeds.reuters.com/reuters/worldNews")!,
            origin: .reuters
        )
    }

    // MARK: - BBC World

    public func bbcWorld() async throws -> [NewsArticle] {
        return await fetchRSS(
            url: URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!,
            origin: .bbc
        )
    }

    // MARK: - arXiv

    /// New submissions for an arXiv category (e.g. `"cs.AI"`, `"q-fin.GN"`).
    public func arxivNewSubmissions(category: String) async throws -> [NewsArticle] {
        let encodedCategory = category.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? category
        return await fetchRSS(
            url: URL(string: "https://export.arxiv.org/rss/\(encodedCategory)")!,
            origin: .arxiv
        )
    }

    // MARK: - SEC EDGAR

    /// Recent EDGAR filings for the given form type (e.g. `"8-K"`, `"10-K"`).
    /// The EDGAR Atom feed uses the same `RSSParser` since it handles both
    /// `<item>` and `<entry>` elements.
    public func secEdgarFilings(formType: String = "8-K") async throws -> [NewsArticle] {
        let encoded = formType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? formType
        return await fetchRSS(
            url: URL(string: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcurrent&type=\(encoded)&output=atom")!,
            origin: .secEdgar
        )
    }

    // MARK: - Generic RSS helper (never throws — returns empty on failure)

    private func fetchRSS(url: URL, origin: NewsFeedOrigin) async -> [NewsArticle] {
        do {
            let data = try await fetcher.fetch(url)
            let articles = try parser.parse(data, feedOrigin: origin)
            return articles.sorted { $0.publishedAt > $1.publishedAt }
        } catch {
            return []
        }
    }
}

// MARK: - Lightweight async semaphore

/// Caps concurrent tasks without spawning threads. Actor-backed so it is safe
/// in structured concurrency.
private actor AsyncSemaphore {
    private let limit: Int
    private var current = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func wait() async {
        if current < limit {
            current += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            current -= 1
        }
    }
}
