/*
 * Metamorphia
 * Assembles the daily MorningBrief from four independent sources: live market
 * quotes, story-continuation proposals, EventKit calendar events, and open
 * loops in the story tracker.
 *
 * All assembly is done once per calendar day; MarketQuoteMonitor owns the
 * guard and calls `assembleForToday()` from `maybePostMorningBrief()`.
 *
 * Continuum Phase 9.
 */

import Foundation
import MetamorphiaAgentKit

@MainActor
public final class MorningBriefAssembler {

    public static let shared = MorningBriefAssembler()

    // MARK: - Dependencies (wired at bootstrap)

    private var markets: MarketQuoteMonitor?
    private var stories: StoryTracker?
    private var continuation: ThreadContinuationEngine?
    private var calendar: CalendarLens?
    private var attention: AttentionModel?

    private init() {}

    /// Wire all five dependencies. Called once from MetamorphiaBootstrap.
    public func configure(
        markets: MarketQuoteMonitor,
        stories: StoryTracker,
        continuation: ThreadContinuationEngine,
        calendar: CalendarLens,
        attention: AttentionModel
    ) {
        self.markets = markets
        self.stories = stories
        self.continuation = continuation
        self.calendar = calendar
        self.attention = attention
    }

    // MARK: - Assembly

    /// Build today's MorningBrief. Returns a fully populated struct even when
    /// individual sections are empty — the UI handles empty-section layout.
    public func assembleForToday() async -> MorningBrief {
        async let movers = assembleMarketMovers()
        async let threads = assembleThreadUpdates()
        async let meetings = assembleMeetings()
        async let loops = assembleOpenLoops()

        return MorningBrief(
            assembledAt: .now,
            marketMovers: await movers,
            threadUpdates: await threads,
            meetingsToday: await meetings,
            openLoops: await loops
        )
    }

    // MARK: - Market movers

    /// Top-3 watchlist entries by absolute percent change this morning.
    private func assembleMarketMovers() async -> [MarketMoverLine] {
        guard let markets else { return [] }

        let quotes = markets.quotes
        guard !quotes.isEmpty else { return [] }

        let entries = WatchlistStore.shared.entries

        let lines: [MarketMoverLine] = quotes.values.compactMap { quote -> MarketMoverLine? in
            guard let pct = quote.changePct else { return nil }
            let entry = entries.first { $0.symbol == quote.symbol }
            return MarketMoverLine(
                symbol: quote.symbol,
                displayName: entry?.displayName ?? quote.companyName,
                changePct: pct,
                last: quote.last
            )
        }
        .sorted { abs($0.changePct) > abs($1.changePct) }

        return Array(lines.prefix(3))
    }

    // MARK: - Thread updates

    /// Up to 3 story-continuation proposals from the past 24 h,
    /// gated by AttentionModel.currentScore >= 0.5.
    private func assembleThreadUpdates() async -> [ThreadUpdateLine] {
        guard let continuation, let attention else { return [] }
        guard attention.currentScore >= 0.5 else { return [] }

        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let proposals = await continuation.propose(since: cutoff, maxResults: 10)

        return proposals.prefix(3).map { proposal in
            let newArticleCount = proposal.story.articles
                .filter { $0.publishedAt >= cutoff }
                .count
            let reason: String
            if newArticleCount == 1 {
                reason = "1 new development"
            } else if newArticleCount > 1 {
                reason = "\(newArticleCount) new developments"
            } else {
                reason = proposal.reasons.first ?? "updated"
            }
            let entity: String = {
                if let e = proposal.primaryEntity, !e.isEmpty { return e }
                if let e = proposal.story.entities.first, !e.isEmpty { return e }
                let titlePrefix = String(proposal.story.title.prefix(40))
                if !titlePrefix.isEmpty { return titlePrefix }
                return "story"
            }()
            return ThreadUpdateLine(
                storyId: proposal.story.id,
                entity: entity,
                headline: proposal.story.title,
                reason: reason
            )
        }
    }

    // MARK: - Meetings today

    /// Up to 3 calendar events later today, via CalendarLens.
    private func assembleMeetings() async -> [MeetingLine] {
        guard let calendar else { return [] }
        return await calendar.meetingsToday()
    }

    // MARK: - Recent work sessions

    /// A single line summarising one app's aggregate usage in the look-back window.
    public struct RecentWorkLine: Sendable {
        public let appName: String
        public let bundleID: String
        public let docHint: String?
        public let totalDurationSeconds: Int   // sum across multiple sessions of same app
        public let sessionCount: Int
    }

    /// Reads the last 24 h of `.sessionClosed` events from the activity journal
    /// and groups them by bundleID. Top `limit` (default 3) by total duration.
    /// Meant to populate a "you worked on X yesterday" section of the morning brief.
    public func recentWorkSessions(limit: Int = 3) async -> [RecentWorkLine] {
        guard let stream = MetamorphiaBootstrap.activityStream else { return [] }

        let cutoff = Date.now.addingTimeInterval(-86_400)
        let events = await stream.recent(since: cutoff)

        // Extract only sessionClosed events.
        struct SessionRecord {
            let bundleID: String
            let appName: String
            let docHint: String?
            let duration: Int
        }

        let sessions: [SessionRecord] = events.compactMap { event in
            guard case .sessionClosed(let bundleID, let docHint, let duration, _, _) = event else {
                return nil
            }
            // Derive a display name from the bundle ID's last component as a fallback.
            // NOTE: if features ever cross-reference this data with InterestGraphPotentiator,
            // normalize both sides to the same key — either bundleID or lowercased appName —
            // to avoid casing mismatches.
            let appName = bundleID.components(separatedBy: ".").last ?? bundleID
            return SessionRecord(bundleID: bundleID, appName: appName, docHint: docHint, duration: duration)
        }

        guard !sessions.isEmpty else { return [] }

        // Group by bundleID.
        var grouped: [String: (appName: String, totalDuration: Int, count: Int, bestDocHint: String?)] = [:]
        for record in sessions {
            if var existing = grouped[record.bundleID] {
                existing.totalDuration += record.duration
                existing.count += 1
                // Keep the longest non-nil docHint as representative.
                if let hint = record.docHint,
                   (existing.bestDocHint == nil || hint.count > (existing.bestDocHint?.count ?? 0)) {
                    existing.bestDocHint = hint
                }
                grouped[record.bundleID] = existing
            } else {
                grouped[record.bundleID] = (
                    appName: record.appName,
                    totalDuration: record.duration,
                    count: 1,
                    bestDocHint: record.docHint
                )
            }
        }

        let sorted = grouped
            .sorted { $0.value.totalDuration > $1.value.totalDuration }
            .prefix(limit)

        return sorted.map { bundleID, info in
            RecentWorkLine(
                appName: info.appName,
                bundleID: bundleID,
                docHint: info.bestDocHint,
                totalDurationSeconds: info.totalDuration,
                sessionCount: info.count
            )
        }
    }

    // MARK: - Open loops

    /// Up to 2 stories the user was following but hasn't checked in > 3 days,
    /// where new articles have arrived since the last check.
    private func assembleOpenLoops() async -> [OpenLoopLine] {
        guard let stories else { return [] }

        let now = Date()
        let staleness: TimeInterval = 3 * 24 * 3600

        let allStories = await stories.allStories()

        let candidates: [(story: Story, days: Int)] = allStories.compactMap { story in
            guard let lastChecked = story.userLastCheckedAt else { return nil }
            let elapsed = now.timeIntervalSince(lastChecked)
            guard elapsed > staleness else { return nil }
            guard story.lastArticleAt > lastChecked else { return nil }
            let days = max(1, Int(elapsed / 86_400))
            return (story, days)
        }
        .sorted { $0.days > $1.days }   // oldest-check first

        return candidates.prefix(2).map { pair in
            let entity = pair.story.entities.first ?? ""
            return OpenLoopLine(
                storyId: pair.story.id,
                entity: entity,
                headline: pair.story.title,
                daysSinceLastCheck: pair.days
            )
        }
    }
}
