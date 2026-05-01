/*
 * Metamorphia
 * Continuum Phase 10 — Predictive staging.
 *
 * On wake, checks whether the user has a strong recurring morning query.
 * If so, pre-computes the answer silently and caches it with a 10-min TTL.
 * When the command bar opens, the staged answer can be rendered instantly
 * (< 100 ms) — no LLM round-trip needed.
 */

import Foundation
import AppKit
import Combine
import Defaults

// MARK: - StagedResponse

public struct StagedResponse: Sendable {
    public let id: UUID
    public let prompt: String
    /// The pre-computed answer text.
    public let response: String
    public let stagedAt: Date
    /// Default 600 s (10 min).
    public let ttl: TimeInterval
    public var isExpired: Bool { Date().timeIntervalSince(stagedAt) > ttl }
}

// MARK: - PredictiveStaging

@MainActor
public final class PredictiveStaging: ObservableObject {

    public static let shared = PredictiveStaging()

    // MARK: - Published state

    @Published public private(set) var stagedResponse: StagedResponse?

    // MARK: - Invalidation

    public enum InvalidationReason: Sendable {
        case userTyped, expired, manual
    }

    // MARK: - Private state

    private var patterns: QueryPatternLearner?
    private var agentSubmit: (@MainActor (String) async -> String)?
    /// Returns true when the user has an active agent run in progress.
    /// Staging is skipped when this returns true to avoid cancelling the
    /// user's live run via the staging loop's cancelInFlight().
    private var isUserBusy: (@MainActor () -> Bool)?
    private var wakeObserver: NSObjectProtocol?
    private var ttlTask: Task<Void, Never>?

    /// Default TTL for staged responses (10 minutes).
    private static let defaultTTL: TimeInterval = 600
    /// Debounce after wake before staging fires (2 s).
    private static let wakeDebounce: TimeInterval = 2

    // MARK: - Init

    private init() {}

    // MARK: - Lifecycle

    /// Wire the staging engine to the pattern learner and the silent agent
    /// submission closure. Call once from bootstrap after both are configured.
    ///
    /// - Parameters:
    ///   - patterns: The shared `QueryPatternLearner` instance.
    ///   - agentSubmit: A closure that submits a query silently to the agent
    ///     and returns the response string. Must not mutate the visible
    ///     conversation UI. Should use a dedicated staging AgentLoop so it
    ///     cannot cancel the user's live run.
    ///   - isUserBusy: Returns true when the user has an active agent run.
    ///     Staging is skipped while the user is busy so the staging loop
    ///     does not preempt in-flight work.
    public func start(
        patterns: QueryPatternLearner,
        agentSubmit: @MainActor @escaping (String) async -> String,
        isUserBusy: @MainActor @escaping () -> Bool = { false }
    ) {
        self.patterns = patterns
        self.agentSubmit = agentSubmit
        self.isUserBusy = isUserBusy
        subscribeToWake()
    }

    // MARK: - Wake subscription

    private func subscribeToWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Small debounce: let the system settle after wake before
                // firing an LLM call.
                try? await Task.sleep(nanoseconds: UInt64(Self.wakeDebounce * 1_000_000_000))
                await self.stageIfApplicable()
            }
        }
    }

    // MARK: - Core staging logic

    /// Evaluate whether pre-computing an answer makes sense right now.
    /// Called automatically on wake; also callable manually for testing.
    public func stageIfApplicable() async {
        // Master news gate and predictive staging sub-flag.
        guard Defaults[.newsEnabled] && Defaults[.newsPredictiveStagingEnabled] else {
            invalidate(reason: .manual)
            return
        }

        guard let patterns, let agentSubmit else { return }

        // User-busy guard: skip staging if the user has an active run so the
        // staging loop cannot preempt (cancel) in-flight work.
        if let busyCheck = isUserBusy, busyCheck() { return }

        // Attention gate.
        guard AttentionModel.shared.currentScore >= 0.5 else { return }

        let cal = Calendar.current
        let now = Date()
        let hourBucket = cal.component(.hour, from: now)
        let weekday = cal.component(.weekday, from: now)   // 1 = Sunday

        let candidates = patterns.topPatterns(hourBucket: hourBucket, within: 120)
        guard let pattern = candidates.first(where: { p in
            p.hitCount(for: weekday) >= patterns.minHitsForRecurring
        }) else { return }

        // Invalidate any existing stage before starting the new one.
        invalidate(reason: .manual)

        let responseText = await agentSubmit(pattern.canonicalQuery)
        guard !responseText.isEmpty else { return }

        let staged = StagedResponse(
            id: UUID(),
            prompt: pattern.canonicalQuery,
            response: responseText,
            stagedAt: Date(),
            ttl: Self.defaultTTL
        )
        stagedResponse = staged

        // Schedule TTL expiry.
        ttlTask?.cancel()
        ttlTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.defaultTTL * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.invalidate(reason: .expired)
        }

        print("[PredictiveStaging] Staged '\(pattern.canonicalQuery)' (TTL \(Int(Self.defaultTTL))s)")
    }

    // MARK: - Consume

    /// Returns the current staged response and clears it. Returns nil when
    /// there is no stage or the TTL has elapsed.
    public func consume() -> StagedResponse? {
        guard let staged = stagedResponse, !staged.isExpired else {
            stagedResponse = nil
            ttlTask?.cancel()
            return nil
        }
        stagedResponse = nil
        ttlTask?.cancel()
        return staged
    }

    // MARK: - Invalidation

    public func invalidate(reason: InvalidationReason) {
        guard stagedResponse != nil else { return }
        ttlTask?.cancel()
        stagedResponse = nil
        if reason != .expired {
            print("[PredictiveStaging] Stage invalidated: \(reason)")
        }
    }
}
