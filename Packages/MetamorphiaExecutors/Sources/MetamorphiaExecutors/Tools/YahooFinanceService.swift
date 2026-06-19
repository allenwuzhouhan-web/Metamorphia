import Foundation

/// HTTP client for Yahoo Finance's unauthenticated public endpoints.
///
/// No API key, no OAuth, no crumb cookie — the `/v8/finance/chart/` and
/// `/v1/finance/search` endpoints return JSON to an ordinary browser UA. This
/// is the same data path Apple Stocks uses under the hood and countless
/// consumer apps rely on.
///
/// Used by `MarketDataTool` (LLM-facing) and directly by the app target's
/// ambient market polling. Public so both callers share the same decode and
/// caching story.
public struct YahooFinanceService: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            config.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public value types (serialized back to the LLM via JSON)

    public struct QuoteRow: Codable, Sendable {
        public let symbol: String
        public let companyName: String?
        public let last: Double
        public let previousClose: Double?
        public let change: Double?
        public let changePct: Double?
        public let dayHigh: Double?
        public let dayLow: Double?
        public let fiftyTwoWeekHigh: Double?
        public let fiftyTwoWeekLow: Double?
        public let volume: Int64?
        public let currency: String?
        public let exchange: String?
        public let timestamp: Date
    }

    public struct ChartPoint: Codable, Sendable {
        public let timestamp: Date
        public let close: Double
    }

    public struct ChartResult: Codable, Sendable {
        public let symbol: String
        public let range: String
        public let points: [ChartPoint]
        public let meta: QuoteRow?
    }

    public struct NewsItem: Codable, Sendable {
        public let title: String
        public let url: String
        public let publisher: String?
        public let publishedAt: Date?
    }

    public struct SearchHit: Codable, Sendable {
        public let symbol: String
        public let name: String
        public let exchange: String?
        public let type: String?
    }

    public struct SearchResult: Codable, Sendable {
        public let quotes: [SearchHit]
        public let news: [NewsItem]
    }

    // MARK: - Endpoints

    /// Batch quotes. Avoids Yahoo's newer `/v7/finance/quote` endpoint which
    /// requires a crumb cookie; instead pulls per-symbol chart metadata which
    /// contains the same last/prev/day-range fields keylessly.
    public func quotes(symbols: [String]) async throws -> [QuoteRow] {
        let capped = Array(symbols.prefix(10))
        var out: [QuoteRow] = []
        try await withThrowingTaskGroup(of: QuoteRow?.self) { group in
            for symbol in capped {
                group.addTask {
                    let raw = try? await self.fetchRawChart(symbol: symbol, range: "1d", interval: "5m")
                    return raw?.asQuoteRow()
                }
            }
            for try await row in group {
                if let row { out.append(row) }
            }
        }
        return out.sorted { $0.symbol < $1.symbol }
    }

    public func chart(symbol: String, range: String) async throws -> ChartResult {
        let interval = Self.intervalFor(range: range)
        let raw = try await fetchRawChart(symbol: symbol, range: range, interval: interval)
        let points: [ChartPoint] = zip(raw.timestamps, raw.closes).compactMap { (ts, close) in
            guard let close else { return nil }
            return ChartPoint(timestamp: Date(timeIntervalSince1970: Double(ts)), close: close)
        }
        return ChartResult(symbol: raw.symbol, range: range, points: points, meta: raw.asQuoteRow())
    }

    public func search(query: String, newsCount: Int = 5) async throws -> SearchResult {
        guard var comps = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search") else {
            throw ServiceError.invalidURL
        }
        // `query` is placed via URLQueryItem, so URLComponents percent-encodes
        // it for us — no manual escaping needed here.
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "newsCount", value: String(newsCount)),
            URLQueryItem(name: "quotesCount", value: "10"),
        ]
        guard let url = comps.url else {
            throw ServiceError.invalidURL
        }
        let response: YahooSearchResponse = try await get(url)
        let quotes = response.quotes.map {
            SearchHit(
                symbol: $0.symbol,
                name: $0.longname ?? $0.shortname ?? $0.symbol,
                exchange: $0.exchange,
                type: $0.quoteType
            )
        }
        let news = response.news.map {
            NewsItem(
                title: $0.title,
                url: $0.link,
                publisher: $0.publisher,
                publishedAt: $0.providerPublishTime.map { Date(timeIntervalSince1970: Double($0)) }
            )
        }
        return SearchResult(quotes: quotes, news: news)
    }

    // MARK: - Private: chart raw decode

    private struct RawChart {
        let symbol: String
        let meta: YahooChartMeta
        let timestamps: [Int]
        let closes: [Double?]

        func asQuoteRow() -> QuoteRow? {
            guard let last = meta.regularMarketPrice else { return nil }
            let prev = meta.chartPreviousClose ?? meta.previousClose
            let change = prev.map { last - $0 }
            let changePct: Double? = {
                guard let prev, prev != 0 else { return nil }
                return (last - prev) / prev * 100.0
            }()
            return QuoteRow(
                symbol: symbol,
                companyName: meta.longName ?? meta.shortName,
                last: last,
                previousClose: prev,
                change: change,
                changePct: changePct,
                dayHigh: meta.regularMarketDayHigh,
                dayLow: meta.regularMarketDayLow,
                fiftyTwoWeekHigh: meta.fiftyTwoWeekHigh,
                fiftyTwoWeekLow: meta.fiftyTwoWeekLow,
                volume: meta.regularMarketVolume,
                currency: meta.currency,
                exchange: meta.exchangeName,
                timestamp: Date()
            )
        }
    }

    private func fetchRawChart(symbol: String, range: String, interval: String) async throws -> RawChart {
        // The symbol is LLM-supplied and may contain characters illegal in a
        // URL path component (`^`, spaces, `=`, etc.). Percent-encode it and
        // guard the optionals instead of force-unwrapping — a bad symbol must
        // surface as a clean error, never a trap.
        guard let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !encodedSymbol.isEmpty else {
            throw ServiceError.invalidSymbol(symbol)
        }
        guard var comps = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedSymbol)") else {
            throw ServiceError.invalidSymbol(symbol)
        }
        comps.queryItems = [
            URLQueryItem(name: "range", value: range),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "includePrePost", value: "false"),
        ]
        guard let url = comps.url else {
            throw ServiceError.invalidURL
        }
        let response: YahooChartResponse = try await get(url)
        guard let result = response.chart.result?.first else {
            throw ServiceError.noData
        }
        return RawChart(
            symbol: result.meta.symbol ?? symbol,
            meta: result.meta,
            timestamps: result.timestamp ?? [],
            closes: result.indicators.quote.first?.close ?? []
        )
    }

    private static func intervalFor(range: String) -> String {
        switch range {
        case "1d": return "5m"
        case "5d": return "15m"
        case "1mo": return "1h"
        case "3mo", "6mo", "1y": return "1d"
        case "2y", "5y": return "1wk"
        case "max": return "1mo"
        default: return "1d"
        }
    }

    // MARK: - Generic GET

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.nonHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.httpError(status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum ServiceError: LocalizedError {
        case noData
        case nonHTTPResponse
        case httpError(status: Int)
        case invalidSymbol(String)
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .noData: return "No data returned by Yahoo Finance."
            case .nonHTTPResponse: return "Unexpected non-HTTP response from Yahoo Finance."
            case .httpError(let status): return "Yahoo Finance returned HTTP \(status)."
            case .invalidSymbol(let symbol): return "Invalid ticker symbol: '\(symbol)'."
            case .invalidURL: return "Failed to build a valid Yahoo Finance request URL."
            }
        }
    }
}

// MARK: - Yahoo decode structs (private to this file)

private struct YahooChartResponse: Decodable {
    let chart: Chart
    struct Chart: Decodable {
        let result: [Result]?
    }
    struct Result: Decodable {
        let meta: YahooChartMeta
        let timestamp: [Int]?
        let indicators: Indicators
    }
    struct Indicators: Decodable {
        let quote: [Quote]
        struct Quote: Decodable {
            let close: [Double?]?
        }
    }
}

private struct YahooChartMeta: Decodable {
    let symbol: String?
    let currency: String?
    let exchangeName: String?
    let regularMarketPrice: Double?
    let chartPreviousClose: Double?
    let previousClose: Double?
    let regularMarketDayHigh: Double?
    let regularMarketDayLow: Double?
    let fiftyTwoWeekHigh: Double?
    let fiftyTwoWeekLow: Double?
    let regularMarketVolume: Int64?
    let longName: String?
    let shortName: String?
}

private struct YahooSearchResponse: Decodable {
    let quotes: [YahooSearchQuote]
    let news: [YahooSearchNews]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.quotes = (try? c.decode([YahooSearchQuote].self, forKey: .quotes)) ?? []
        self.news = (try? c.decode([YahooSearchNews].self, forKey: .news)) ?? []
    }

    enum CodingKeys: String, CodingKey { case quotes, news }
}

private struct YahooSearchQuote: Decodable {
    let symbol: String
    let shortname: String?
    let longname: String?
    let exchange: String?
    let quoteType: String?
}

private struct YahooSearchNews: Decodable {
    let title: String
    let link: String
    let publisher: String?
    let providerPublishTime: Int?
}
