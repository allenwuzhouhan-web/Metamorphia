/*
 * Metamorphia
 * Market-domain value types — shared by WatchlistStore, MarketQuoteMonitor,
 * Live Activities, notch UI, and the command-bar rich-content renderer.
 *
 * All types are pure data (Codable / Sendable) with no behavior beyond
 * convenience accessors. Runtime logic lives in MarketQuoteMonitor.
 */

import Foundation
import MetamorphiaAgentKit

// MARK: - Quote

/// A single point-in-time snapshot of a ticker. Mirrors the shape the
/// MarketDataTool returns (Yahoo Finance chart-meta-derived) so JSON coming
/// back from the agent decodes straight into this without field renaming.
public struct MarketQuote: Codable, Sendable, Hashable, Identifiable {
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

    public var id: String { symbol }

    /// `true` when the last print is at or above the previous close.
    public var isRising: Bool {
        guard let prev = previousClose else { return (change ?? 0) >= 0 }
        return last >= prev
    }
}

// MARK: - Watchlist

/// A ticker the user has pinned to their watchlist. `updatedAt` drives
/// last-write-wins reconciliation when the watchlist syncs via iCloud KVS.
public struct WatchlistEntry: Codable, Sendable, Hashable, Identifiable {
    public var symbol: String
    public var addedAt: Date
    public var updatedAt: Date
    public var displayName: String?
    public var alertRules: [PriceAlertRule]

    public var id: String { symbol }

    public init(
        symbol: String,
        addedAt: Date = .now,
        updatedAt: Date = .now,
        displayName: String? = nil,
        alertRules: [PriceAlertRule] = []
    ) {
        self.symbol = symbol.uppercased()
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.displayName = displayName
        self.alertRules = alertRules
    }
}

// MARK: - Alerts

public struct PriceAlertRule: Codable, Sendable, Hashable, Identifiable {
    public enum Condition: Codable, Sendable, Hashable {
        /// Trigger when last crosses strictly above `value`.
        case crossAbove(Double)
        /// Trigger when last crosses strictly below `value`.
        case crossBelow(Double)
        /// Trigger when absolute day-change percent exceeds `value` (e.g. 2.0 = ±2%).
        case percentMoveAbs(Double)
    }

    public let id: UUID
    public let symbol: String
    public let condition: Condition
    public let createdAt: Date
    public var lastFiredAt: Date?

    public init(
        id: UUID = UUID(),
        symbol: String,
        condition: Condition,
        createdAt: Date = .now,
        lastFiredAt: Date? = nil
    ) {
        self.id = id
        self.symbol = symbol.uppercased()
        self.condition = condition
        self.createdAt = createdAt
        self.lastFiredAt = lastFiredAt
    }

    /// Evaluate this rule against a freshly-arrived quote. Returns whether the
    /// rule should fire *now*. Does not mutate `lastFiredAt` — callers do that.
    public func evaluate(against quote: MarketQuote, previous: MarketQuote?) -> Bool {
        switch condition {
        case .crossAbove(let threshold):
            // Cross, not just "above" — needs the previous sample to be below.
            guard let prevLast = previous?.last else { return quote.last > threshold }
            return prevLast <= threshold && quote.last > threshold

        case .crossBelow(let threshold):
            guard let prevLast = previous?.last else { return quote.last < threshold }
            return prevLast >= threshold && quote.last < threshold

        case .percentMoveAbs(let magnitude):
            guard let pct = quote.changePct else { return false }
            return abs(pct) >= magnitude
        }
    }
}

// MARK: - News & earnings

public struct MarketNewsItem: Codable, Sendable, Hashable, Identifiable {
    public let title: String
    public let url: String
    public let publisher: String?
    public let publishedAt: Date?
    public let symbol: String?

    public var id: String { url }
}

public struct EarningsEvent: Codable, Sendable, Hashable, Identifiable {
    public let symbol: String
    public let expectedDate: Date
    public let consensusEps: Double?

    public var id: String { "\(symbol)@\(expectedDate.timeIntervalSince1970)" }
}

// MARK: - Clipboard hint

/// Surfaced when the clipboard receives a URL containing references to
/// watchlist tickers. Consumed by the UI to offer a quiet analyze-this toast.
public struct ClipboardMarketHint: Sendable, Hashable {
    public let url: String
    public let extractedSymbols: [String]
    public let detectedAt: Date
    /// The clipboard item that triggered this hint. Used by
    /// `ClipboardInsightsSurface` to suppress the thread hint when the market
    /// hint is already showing for the same copy action.
    public let clipboardItemId: UUID?

    public init(
        url: String,
        extractedSymbols: [String],
        detectedAt: Date = .now,
        clipboardItemId: UUID? = nil
    ) {
        self.url = url
        self.extractedSymbols = extractedSymbols
        self.detectedAt = detectedAt
        self.clipboardItemId = clipboardItemId
    }
}

// MARK: - Rich command-bar content

/// Optional rich rendering alongside a `Turn.result`. Command-bar views read
/// this; if nil, the existing text rendering is unchanged.
public enum RichTurnContent: Sendable, Hashable {
    case quoteCard(MarketQuote)
    case sparkline(symbol: String, points: [Double])
    case newsDigest([MarketNewsItem])
    case morningBrief(MorningBrief)
    case functionGraph(FunctionGraphSpec)
    /// Continuum Phase 7: meeting pre-brief from CalendarLens.
    /// Surfaced when the user asks "what's next on my calendar?" via the
    /// command bar. The notch-flash mechanism uses CalendarLens.upcomingBrief
    /// directly, not this case.
    case meetingBrief(MeetingPreBrief)
    /// Retrace recall scenes — rendered when a user query resolves to one
    /// or more episodes via `QueryRank`. The rendering is a hero item with
    /// a timeline ribbon and entity chips.
    case retraceScenes(query: String, scenes: [RecallScene])

    // --- T11: rich text-pattern cards ---
    case dateResult(DateResult)
    case eventResult(EventResult)
    case listResult(ListResult)
    case documentReview(DocumentReviewResult)
    case powerPointRewrite(PowerPointRewriteResult)
    case powerPointDesign(PowerPointDesignResult)
    case powerPointDirectEdit(PowerPointDirectEditResult)
}
