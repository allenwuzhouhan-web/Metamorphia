/*
 * Metamorphia
 * Ambient calendar polling and pre-brief assembly for the notch flash.
 *
 * Polls EventKit every 5 minutes. At T-15 it resolves attendee entities;
 * at T-5 it assembles a full MeetingPreBrief and publishes it for the
 * MeetingBriefLiveActivity to render. The brief auto-clears after 25 s.
 *
 * Does NOT request calendar permission on start() — that is deferred to
 * the Settings UI (Phase 13) via an explicit requestAccess() call.
 *
 * Continuum Phase 7.
 */

import Foundation
import Combine
import Defaults
import EventKit
import MetamorphiaAgentKit

@MainActor
public final class CalendarLens: ObservableObject {

    // MARK: - Singleton

    public static let shared = CalendarLens()

    // MARK: - Published state

    @Published public private(set) var upcomingBrief: MeetingPreBrief?
    @Published public private(set) var permissionGranted: Bool = false

    // MARK: - Private state

    private let store = EKEventStore()
    private var pollTimer: Timer?
    /// Event ids that have already been briefed, keyed to the time they were
    /// briefed so stale entries can be evicted (a briefed event never reappears
    /// in the upcoming-events poll, so its id is dead weight after the meeting).
    private var briefedAtByEventId: [String: Date] = [:]

    /// Resolved attendee digests keyed by event identifier.
    /// Set at T-15 so T-5 can promote straight to brief assembly.
    private var resolvedAttendees: [String: [AttendeeDigest]] = [:]

    private var interestGraph: InterestGraphStore?
    private var stories: StoryTracker?
    private var aliasStore: EntityAliasStore?
    private var memory: (any MemoryStore)?

    /// Handle for the auto-clear task so dismiss() can cancel it explicitly.
    private var autoClearTask: Task<Void, Never>?

    private static let pollInterval: TimeInterval    = 5 * 60    // 5 min
    private static let identifyWindowLow: TimeInterval = 10 * 60  // 10 min
    private static let identifyWindowHigh: TimeInterval = 15 * 60 // 15 min
    private static let briefWindowLow: TimeInterval  =  4 * 60   // 4 min
    private static let briefWindowHigh: TimeInterval =  6 * 60   // 6 min
    private static let briefDisplayDuration: TimeInterval = 25
    private static let storyRecencyWindow: TimeInterval = 7 * 24 * 3600  // 7 days
    private static let briefedIdRetention: TimeInterval = 48 * 3600      // 48 h

    // MARK: - Lifecycle

    private init() {}

    /// Wire the external stores and start the 5-minute polling loop.
    /// Permission is NOT requested here — call requestAccess() separately.
    public func start(
        interestGraph: InterestGraphStore,
        stories: StoryTracker,
        aliasStore: EntityAliasStore,
        memory: any MemoryStore
    ) {
        self.interestGraph = interestGraph
        self.stories = stories
        self.aliasStore = aliasStore
        self.memory = memory
        schedulePollTimer()
    }

    // MARK: - Permission

    /// Request full EventKit access. Updates permissionGranted on completion.
    /// Must be called explicitly — typically from the Settings UI.
    public func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            permissionGranted = granted
            if granted {
                // Run an immediate poll after permission is first granted.
                await poll()
            }
        } catch {
            permissionGranted = false
            print("[CalendarLens] requestAccess failed: \(error.localizedDescription)")
        }
    }

    /// Manual refresh — same as the timer tick.
    public func refreshNow() async {
        await poll()
    }

    /// Fetch all non-all-day events that start after `now` and before end-of-day,
    /// map to `MeetingLine`, and return up to 3 in chronological order.
    /// Returns an empty array when calendar permission has not been granted.
    public func meetingsToday() async -> [MeetingLine] {
        guard permissionGranted else { return [] }
        guard let aliasStore, let interestGraph else { return [] }

        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        var components = DateComponents()
        components.day = 1
        let endOfDay = calendar.date(byAdding: components, to: startOfDay) ?? startOfDay

        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)

        // Filter out all-day events and events already in progress.
        let upcoming = events
            .filter { !$0.isAllDay }
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)

        var lines: [MeetingLine] = []
        for event in upcoming {
            let digests = await resolveAttendees(
                event: event,
                aliasStore: aliasStore,
                interestGraph: interestGraph
            )
            let primaryEntity = digests.first?.canonicalEntity
            lines.append(MeetingLine(
                eventId: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Meeting",
                timeOfDay: event.startDate,
                primaryEntity: primaryEntity
            ))
        }

        return lines
    }

    /// Immediately clear the active brief.
    public func dismiss() {
        autoClearTask?.cancel()
        autoClearTask = nil
        upcomingBrief = nil
        AttentionModel.shared.recordSurfaceDismissal()
    }

    // MARK: - Polling timer

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.poll() }
        }
        // Run once immediately.
        Task { @MainActor in await poll() }
    }

    // MARK: - Core poll

    private func poll() async {
        // Master news gate and meeting pre-briefs sub-flag.
        guard Defaults[.newsEnabled] && Defaults[.newsMeetingPreBriefsEnabled] else {
            upcomingBrief = nil
            return
        }
        guard permissionGranted else { return }
        guard let interestGraph, let stories, let aliasStore, let memory else { return }

        let now = Date()
        // Fetch events in the next 20-minute window.
        let windowEnd = now.addingTimeInterval(20 * 60)
        let predicate = store.predicateForEvents(withStart: now, end: windowEnd, calendars: nil)
        let events = store.events(matching: predicate)

        for event in events {
            guard let eventId = event.eventIdentifier else { continue }
            guard briefedAtByEventId[eventId] == nil else { continue }

            let secondsUntil = event.startDate.timeIntervalSince(now)

            // T-15 window: resolve attendees.
            if secondsUntil >= Self.identifyWindowLow && secondsUntil <= Self.identifyWindowHigh {
                if resolvedAttendees[eventId] == nil {
                    let digests = await resolveAttendees(
                        event: event,
                        aliasStore: aliasStore,
                        interestGraph: interestGraph
                    )
                    resolvedAttendees[eventId] = digests
                }
            }

            // T-5 window: assemble and publish the brief.
            if secondsUntil >= Self.briefWindowLow && secondsUntil <= Self.briefWindowHigh {
                // Ensure attendees are resolved (may have been skipped if poll missed T-15).
                if resolvedAttendees[eventId] == nil {
                    let digests = await resolveAttendees(
                        event: event,
                        aliasStore: aliasStore,
                        interestGraph: interestGraph
                    )
                    resolvedAttendees[eventId] = digests
                }
                guard let digests = resolvedAttendees[eventId] else { continue }

                // Record before the await so a second overlapping poll cannot
                // enter this branch for the same event (Fix 1 — race guard).
                briefedAtByEventId[eventId] = now
                resolvedAttendees.removeValue(forKey: eventId)

                let brief = await assembleBrief(
                    event: event,
                    digests: digests,
                    stories: stories,
                    memory: memory,
                    now: now
                )
                upcomingBrief = brief

                // Auto-clear after 25 s if not already dismissed.
                // Store the handle so dismiss() can cancel it (Fix 3).
                autoClearTask?.cancel()
                let briefId = eventId
                autoClearTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.briefDisplayDuration * 1_000_000_000))
                    guard let self else { return }
                    if self.upcomingBrief?.id == briefId {
                        self.upcomingBrief = nil
                        AttentionModel.shared.recordSurfaceIgnored()
                    }
                }
            }
        }

        // Evict stale resolved-attendee caches for events that have passed.
        for key in resolvedAttendees.keys {
            let isStillUpcoming = events.contains { $0.eventIdentifier == key }
            if !isStillUpcoming { resolvedAttendees.removeValue(forKey: key) }
        }

        // Evict briefed-event ids older than the dedupe horizon. A meeting
        // briefed this long ago has already happened and will never reappear
        // in the upcoming-events poll, so its id only wastes memory.
        let briefedCutoff = now.addingTimeInterval(-Self.briefedIdRetention)
        briefedAtByEventId = briefedAtByEventId.filter { $0.value > briefedCutoff }
    }

    // MARK: - Attendee resolution

    /// Extract AttendeeDigest values from an EKEvent, ordered by interest-graph score
    /// (highest first). The user's own address is stripped.
    private func resolveAttendees(
        event: EKEvent,
        aliasStore: EntityAliasStore,
        interestGraph: InterestGraphStore
    ) async -> [AttendeeDigest] {
        guard let participants = event.attendees, !participants.isEmpty else { return [] }

        var digests: [(digest: AttendeeDigest, score: Double)] = []

        for participant in participants {
            // Skip self.
            if participant.isCurrentUser { continue }

            let rawURL = participant.url.absoluteString  // e.g. "mailto:sarah@anthropic.com"
            let email: String? = rawURL.hasPrefix("mailto:")
                ? String(rawURL.dropFirst("mailto:".count)).lowercased()
                : nil

            // Derive company from email domain prefix (e.g. "anthropic" from "anthropic.com").
            let company: String? = email.flatMap { addr in
                guard let atIdx = addr.firstIndex(of: "@") else { return nil }
                let domain = String(addr[addr.index(after: atIdx)...])
                // Strip the TLD: "anthropic.com" -> "anthropic"
                return domain.components(separatedBy: ".").first
            }

            let displayName: String? = participant.name.flatMap {
                $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
            }

            // Canonicalize: prefer company, fall back to display name.
            let surface = company ?? displayName ?? email ?? ""
            let canonicalEntity: String? = surface.isEmpty
                ? nil
                : await aliasStore.canonicalize(surface: surface, type: .org)

            let digest = AttendeeDigest(
                displayName: displayName,
                email: email,
                canonicalEntity: canonicalEntity,
                company: company
            )

            // Score via interest graph (async actor call).
            let score: Double
            if let entity = canonicalEntity, !entity.isEmpty {
                score = await interestGraph.score(entity: entity)
            } else {
                score = 0
            }

            digests.append((digest: digest, score: score))
        }

        // Sort descending by interest-graph score so primary is first.
        return digests
            .sorted { $0.score > $1.score }
            .map(\.digest)
    }

    // MARK: - Brief assembly

    private func assembleBrief(
        event: EKEvent,
        digests: [AttendeeDigest],
        stories: StoryTracker,
        memory: any MemoryStore,
        now: Date
    ) async -> MeetingPreBrief {
        let primaryAttendee = digests.first
        let otherAttendees = digests.count > 1 ? Array(digests.dropFirst()) : []

        var recentStories: [StoryArticleRef] = []
        var mentions: [String] = []
        var lastSpokeAt: Date? = nil

        if let primaryEntity = primaryAttendee?.canonicalEntity {
            // Stories: get all stories about the entity, take those with
            // lastArticleAt within the past 7 days, sort desc, top 3.
            let cutoff = now.addingTimeInterval(-Self.storyRecencyWindow)
            let candidateStories = await stories.stories(about: primaryEntity)
            let fresh = candidateStories
                .filter { $0.lastArticleAt > cutoff }
                .prefix(3)

            // Flatten each story to its most-recent article.
            recentStories = fresh.compactMap { story in
                story.articles
                    .sorted { $0.publishedAt > $1.publishedAt }
                    .first
            }

            // Memory: recall .thread memories for the primary entity.
            let records = memory.recall(query: primaryEntity, category: .thread, limit: 2)
            // Truncate each record to 120 characters so the surface stays compact.
            mentions = records.map { rec in
                rec.content.count > 120
                    ? String(rec.content.prefix(117)) + "..."
                    : rec.content
            }
            // Pick the most-recent record's timestamp for the "last spoke" label.
            lastSpokeAt = records.max(by: { $0.timestamp < $1.timestamp })?.timestamp
        }

        return MeetingPreBrief(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Meeting",
            startDate: event.startDate,
            primaryAttendee: primaryAttendee,
            otherAttendees: otherAttendees,
            recentStories: recentStories,
            lastConversationMentions: mentions,
            lastSpokeAt: lastSpokeAt,
            computedAt: now
        )
    }
}
