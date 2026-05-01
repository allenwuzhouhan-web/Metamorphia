/*
 * Metamorphia
 * Value types for the unified MorningBrief — a single morning card that
 * aggregates market movers, thread updates, today's meetings, and open loops
 * the user hasn't checked in a while.
 *
 * All types are pure data (Codable / Sendable) with no behaviour beyond
 * convenience accessors. Assembly logic lives in MorningBriefAssembler.
 */

import Foundation

// MARK: - MorningBrief

/// The unified morning card assembled once per calendar day. Each section may
/// be empty; the UI handles the empty-section layout without special markers.
public struct MorningBrief: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let assembledAt: Date
    public let marketMovers: [MarketMoverLine]
    public let threadUpdates: [ThreadUpdateLine]
    public let meetingsToday: [MeetingLine]
    public let openLoops: [OpenLoopLine]

    public init(
        id: UUID = UUID(),
        assembledAt: Date = .now,
        marketMovers: [MarketMoverLine] = [],
        threadUpdates: [ThreadUpdateLine] = [],
        meetingsToday: [MeetingLine] = [],
        openLoops: [OpenLoopLine] = []
    ) {
        self.id = id
        self.assembledAt = assembledAt
        self.marketMovers = marketMovers
        self.threadUpdates = threadUpdates
        self.meetingsToday = meetingsToday
        self.openLoops = openLoops
    }
}

// MARK: - MarketMoverLine

/// One watchlist entry that moved materially this morning.
public struct MarketMoverLine: Sendable, Codable, Hashable {
    public let symbol: String
    public let displayName: String?
    /// Signed percentage change (e.g. +1.2 or -0.3). Value, not fraction.
    public let changePct: Double
    public let last: Double

    public init(symbol: String, displayName: String?, changePct: Double, last: Double) {
        self.symbol = symbol
        self.displayName = displayName
        self.changePct = changePct
        self.last = last
    }
}

// MARK: - ThreadUpdateLine

/// A story the user follows that received new developments in the past 24 h.
public struct ThreadUpdateLine: Sendable, Codable, Hashable {
    public let storyId: UUID
    public let entity: String
    public let headline: String
    /// Human-readable update summary, e.g. "2 new developments".
    public let reason: String

    public init(storyId: UUID, entity: String, headline: String, reason: String) {
        self.storyId = storyId
        self.entity = entity
        self.headline = headline
        self.reason = reason
    }
}

// MARK: - MeetingLine

/// A calendar event happening later today.
public struct MeetingLine: Sendable, Codable, Hashable {
    public let eventId: String
    public let title: String
    /// Start time of the event (today).
    public let timeOfDay: Date
    /// Primary entity resolved from attendees, if any.
    public let primaryEntity: String?

    public init(eventId: String, title: String, timeOfDay: Date, primaryEntity: String?) {
        self.eventId = eventId
        self.title = title
        self.timeOfDay = timeOfDay
        self.primaryEntity = primaryEntity
    }
}

// MARK: - OpenLoopLine

/// A story the user was following but hasn't checked in more than 3 days,
/// with new articles since the last check.
public struct OpenLoopLine: Sendable, Codable, Hashable {
    public let storyId: UUID
    public let entity: String
    public let headline: String
    public let daysSinceLastCheck: Int

    public init(storyId: UUID, entity: String, headline: String, daysSinceLastCheck: Int) {
        self.storyId = storyId
        self.entity = entity
        self.headline = headline
        self.daysSinceLastCheck = daysSinceLastCheck
    }
}
