import Foundation

/// Topic section for Google News RSS feeds.
public enum NewsSection: String, Sendable, Codable, CaseIterable {
    case top, world, business, technology, entertainment, sports, science, health
}

/// A single article returned by any news feed — Google News, HN, AP, etc.
/// The `link` URL is treated as the stable identity across feeds.
public struct NewsArticle: Sendable, Codable, Hashable, Identifiable {
    public var id: String { link }

    public let title: String
    public let link: String
    public let source: String
    public let publishedAt: Date
    /// HTML-stripped plain-text summary.
    public let snippet: String
    public let feedOrigin: NewsFeedOrigin

    public init(
        title: String,
        link: String,
        source: String,
        publishedAt: Date,
        snippet: String,
        feedOrigin: NewsFeedOrigin
    ) {
        self.title = title
        self.link = link
        self.source = source
        self.publishedAt = publishedAt
        self.snippet = snippet
        self.feedOrigin = feedOrigin
    }
}

/// Which upstream feed produced this article. Drives attribution in the UI.
public enum NewsFeedOrigin: String, Sendable, Codable {
    case googleNews, hackerNews, ap, reuters, bbc, arxiv, secEdgar, direct
}
