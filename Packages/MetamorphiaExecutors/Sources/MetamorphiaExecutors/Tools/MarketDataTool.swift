import Foundation
import MetamorphiaAgentKit

/// Single tool the LLM invokes for stock / ETF / index market data. Action-
/// dispatched (one tool, many verbs) to keep the catalog lean — Metamorphia
/// already ships 70+ tools, and LLM routing quality degrades with every
/// additional entry.
///
/// Data path: Yahoo Finance's unauthenticated public endpoints. No API key is
/// required from the user. This is the same data source Apple Stocks uses.
public struct MarketDataTool: ToolDefinition {
    public let name = "market_data"
    public let description = "Look up stock quotes, price history, news, fundamentals, search for tickers, or upcoming earnings via Yahoo Finance. Use `action` to pick the operation. No API key required."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(
                description: "Which operation to run.",
                values: ["quote", "history", "news", "fundamentals", "search", "earnings"]
            ),
            "symbol": JSONSchema.string(description: "Ticker symbol (e.g., NVDA, AAPL). Required for quote / history / fundamentals / earnings. For `news`, either `symbol` or `query`."),
            "symbols": JSONSchema.array(
                items: ["type": "string"],
                description: "Batch of symbols for 'quote' action (e.g., [\"NVDA\", \"AAPL\"]). Up to 10."
            ),
            "range": JSONSchema.enumString(
                description: "Lookback range for 'history'. Default 1d.",
                values: ["1d", "5d", "1mo", "3mo", "6mo", "1y", "2y", "5y", "max"]
            ),
            "query": JSONSchema.string(description: "Search string for 'search' (e.g., 'nvidia', 'semiconductor etf') or topical 'news' queries."),
            "limit": JSONSchema.integer(description: "Max items for 'news' / 'search'. Default 5.", minimum: 1, maximum: 25),
        ], required: ["action"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args).lowercased()
        let service = YahooFinanceService()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        switch action {
        case "quote":
            let symbols = collectSymbols(args)
            guard !symbols.isEmpty else {
                return "Error: 'quote' requires 'symbol' or 'symbols'."
            }
            let rows = try await service.quotes(symbols: symbols)
            return try encodeResponse(encoder: encoder, payload: QuotePayload(quotes: rows))

        case "history":
            let symbol = try requiredString("symbol", from: args)
            let range = (args["range"] as? String) ?? "1d"
            let chart = try await service.chart(symbol: symbol.uppercased(), range: range)
            return try encodeResponse(encoder: encoder, payload: chart)

        case "news":
            let limit = optionalInt("limit", from: args) ?? 5
            let query: String = {
                if let q = optionalString("query", from: args), !q.isEmpty { return q }
                if let s = optionalString("symbol", from: args), !s.isEmpty { return s.uppercased() }
                return ""
            }()
            guard !query.isEmpty else {
                return "Error: 'news' requires 'symbol' or 'query'."
            }
            let result = try await service.search(query: query, newsCount: limit)
            return try encodeResponse(encoder: encoder, payload: NewsPayload(query: query, news: result.news))

        case "search":
            let query = try requiredString("query", from: args)
            let result = try await service.search(query: query, newsCount: 0)
            return try encodeResponse(encoder: encoder, payload: SearchPayload(query: query, hits: result.quotes))

        case "fundamentals":
            let symbol = try requiredString("symbol", from: args).uppercased()
            let rows = try await service.quotes(symbols: [symbol])
            guard let first = rows.first else {
                return "Error: no data available for \(symbol)."
            }
            // The free chart endpoint only exposes the basics (last, day/52w
            // ranges, volume). Deeper fundamentals (P/E, EPS, analyst targets)
            // need an authenticated source — surface that honestly rather than
            // fabricating numbers.
            return try encodeResponse(encoder: encoder, payload: FundamentalsPayload(
                quote: first,
                note: "Free tier only exposes the basics. P/E, EPS, and analyst targets need an authenticated source."
            ))

        case "earnings":
            let symbol = try requiredString("symbol", from: args).uppercased()
            return """
            {
              "symbol": "\(symbol)",
              "note": "Upcoming-earnings data needs an authenticated source (Yahoo's calendar endpoint is cookie-gated). Open finance.yahoo.com/calendar/earnings/?symbol=\(symbol) via open_url if you need it now."
            }
            """

        default:
            return "Error: unknown action '\(action)'. Supported: quote, history, news, fundamentals, search, earnings."
        }
    }

    // MARK: - Helpers

    private func collectSymbols(_ args: [String: Any]) -> [String] {
        if let arr = args["symbols"] as? [String], !arr.isEmpty {
            return arr.map { $0.uppercased() }
        }
        if let arr = args["symbols"] as? [Any] {
            let strs = arr.compactMap { $0 as? String }.map { $0.uppercased() }
            if !strs.isEmpty { return strs }
        }
        if let single = args["symbol"] as? String, !single.isEmpty {
            return [single.uppercased()]
        }
        return []
    }

    private func encodeResponse<T: Encodable>(encoder: JSONEncoder, payload: T) throws -> String {
        let data = try encoder.encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private struct QuotePayload: Encodable {
        let quotes: [YahooFinanceService.QuoteRow]
    }
    private struct NewsPayload: Encodable {
        let query: String
        let news: [YahooFinanceService.NewsItem]
    }
    private struct SearchPayload: Encodable {
        let query: String
        let hits: [YahooFinanceService.SearchHit]
    }
    private struct FundamentalsPayload: Encodable {
        let quote: YahooFinanceService.QuoteRow
        let note: String
    }
}
