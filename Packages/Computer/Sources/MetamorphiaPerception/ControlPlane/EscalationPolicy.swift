import Foundation

// MARK: - Wave 4 persistence note
//
// `AppEscalationProfile` is designed for durable persistence via a
// `PersistenceBackend` protocol. In Wave 4 (this file) all state is
// in-memory only — `NoopPersistence` is the default. Wave 8 wires
// `SecurePersistence` from the host-app target by calling
// `EscalationPolicy.shared.attach(persistence:)` at bootstrap.
// `MetamorphiaPerception` intentionally has no dependency on
// `MetamorphiaAgentKit` or any other package.

// MARK: - PersistenceBackend

/// Protocol for persisting per-bundle escalation profiles.
/// Wave 8 wires a concrete `SecurePersistence`-backed implementation.
public protocol EscalationPersistenceBackend: Sendable {
    func load(bundleID: String) async -> EscalationPolicy.AppEscalationProfile?
    func save(_ profile: EscalationPolicy.AppEscalationProfile) async
}

/// Default no-op backend (Wave 4). All state lives only in the actor.
public struct NoopEscalationPersistence: EscalationPersistenceBackend {
    public init() {}
    public func load(bundleID: String) async -> EscalationPolicy.AppEscalationProfile? { nil }
    public func save(_ profile: EscalationPolicy.AppEscalationProfile) async {}
}

// MARK: - EscalationPolicy

/// Decides when to escalate from AX to OCR with explicit per-reason
/// debouncing, per-app profiles, daily caps, and oscillation protection.
///
/// All state is actor-isolated. Callers on any context may `await` the
/// public methods without races.
public actor EscalationPolicy {

    // MARK: Shared instance

    public static let shared = EscalationPolicy()

    // MARK: - Reason

    public enum Reason: String, Sendable, Codable, CaseIterable {
        case axEmpty
        case axShallow
        case knownOpaqueApp
        case userInteractedUnnamedElement
        case attentionSpike
        case agentRequestedVerify
        case driftDetected
        case secureInputAdjacent
    }

    // MARK: - EscalationContext

    public struct EscalationContext: Sendable {
        public let bundleID: String?
        public let reason: Reason
        public let at: Date

        public init(bundleID: String?, reason: Reason, at: Date = Date()) {
            self.bundleID = bundleID
            self.reason = reason
            self.at = at
        }
    }

    // MARK: - Decision

    public struct Decision: Sendable, Hashable {
        public let allow: Bool
        public let reason: Reason?
        public let tokenID: UUID?
        /// Short string consumed by telemetry. Non-nil only on denial.
        public let denyCause: String?
    }

    // MARK: - EscalationResult

    public enum EscalationResult: Sendable, Hashable {
        case completed, supersededByPrimary, timedOut
    }

    // MARK: - AppEscalationProfile

    public struct AppEscalationProfile: Sendable, Codable, Hashable {
        public var bundleID: String
        public var sevenDayCounts: [Reason: Int]
        public var axQualityScore: Double       // 0..1
        public var preferredStrategy: Strategy

        public enum Strategy: String, Sendable, Codable {
            case ax, axPlusOcr, ocrOnly
        }

        public init(bundleID: String) {
            self.bundleID = bundleID
            self.sevenDayCounts = [:]
            self.axQualityScore = 1.0
            self.preferredStrategy = .ax
        }
    }

    // MARK: - BundleEscalationTally

    public struct BundleEscalationTally: Sendable, Hashable {
        public let bundleID: String
        public let reasonCounts: [Reason: Int]
        public let lastEscalations: [Date]
        /// Per-reason settlement outcome counts. Populated as callers report
        /// `settle(tokenID:result:)` for each escalation. A high
        /// `supersededByPrimary` count indicates OCR budget wasted on an app
        /// whose AX is healthier than the profile realised — we nudge the
        /// axQualityScore up to compensate over time.
        public let settlementCounts: [Reason: [EscalationResult: Int]]
    }

    // MARK: - Debounce + cap tables

    private static let debounceSeconds: [Reason: TimeInterval] = [
        .axEmpty:                      2.0,
        .axShallow:                    3.0,
        .knownOpaqueApp:               5.0,
        .userInteractedUnnamedElement: 0.3,
        .attentionSpike:               1.0,
        .agentRequestedVerify:         0.0,
        .driftDetected:                10.0,
        .secureInputAdjacent:          .infinity,   // always denied
    ]

    private static let dailyCaps: [Reason: Int] = [
        .axEmpty:                      200,
        .axShallow:                    100,
        .knownOpaqueApp:               60,
        .userInteractedUnnamedElement: .max,
        .attentionSpike:               30,
        .agentRequestedVerify:         .max,
        .driftDetected:                20,
        .secureInputAdjacent:          0,
    ]

    /// Ring buffer capacity for recent escalation timestamps per bundle.
    private static let ringCapacity = 10

    /// Bundle keys idle longer than this are dropped during the periodic sweep.
    private static let bundleRetention: TimeInterval = 7 * 24 * 60 * 60   // 7 days
    /// Hard ceiling on tracked bundle keys; oldest are evicted past this.
    private static let maxTrackedBundles = 256

    // MARK: - Per-bundle state

    /// Keyed by effective bundle key (`bundleID ?? "_"`).
    private var lastEscalationAt: [String: [Reason: Date]] = [:]
    private var todayCount: [String: [Reason: Int]] = [:]
    private var todayStart: [String: Date] = [:]
    /// Outstanding token per (bundle, reason). Oscillation guard.
    private var outstandingTokens: [String: [Reason: UUID]] = [:]
    /// Ring buffer of recent escalation timestamps per bundle.
    private var recentEscalations: [String: [Date]] = [:]
    /// Per-bundle profiles (in-memory, Wave 4).
    private var profiles: [String: AppEscalationProfile] = [:]
    /// Settlement outcomes keyed by bundle → reason → result.
    private var settlementCounts: [String: [Reason: [EscalationResult: Int]]] = [:]

    // MARK: - Persistence backend

    private var persistence: any EscalationPersistenceBackend = NoopEscalationPersistence()

    // MARK: - Init

    public init() {}

    // MARK: - Wiring

    /// Wave 8 hook: replace the noop backend with a real persistence layer.
    public func attach(persistence backend: any EscalationPersistenceBackend) {
        persistence = backend
    }

    // MARK: - Core API

    /// Evaluate whether escalation should be allowed for `lane` + `context`.
    public func evaluate(lane: PerceptionLane, context: EscalationContext) async -> Decision {
        let reason = context.reason
        let key = context.bundleID ?? "_"
        let now = context.at

        // 1. Hard-deny: secureInputAdjacent
        if reason == .secureInputAdjacent {
            return Decision(allow: false, reason: .secureInputAdjacent,
                            tokenID: nil, denyCause: "hard-deny")
        }

        // 2. Daily reset check
        resetTodayCountsIfNeeded(key: key, now: now)

        // 3. Per-reason debounce
        let debounce = Self.debounceSeconds[reason] ?? 0
        if debounce > 0 {
            if let last = lastEscalationAt[key]?[reason] {
                if now.timeIntervalSince(last) < debounce {
                    return Decision(allow: false, reason: reason,
                                    tokenID: nil, denyCause: "debounce")
                }
            }
        }

        // 4. Daily cap
        let cap = Self.dailyCaps[reason] ?? .max
        let currentCount = todayCount[key]?[reason] ?? 0
        if currentCount >= cap {
            return Decision(allow: false, reason: reason,
                            tokenID: nil, denyCause: "cap")
        }

        // 5. Allow: issue token, record state
        let token = UUID()

        // Update debounce timestamp
        if lastEscalationAt[key] == nil { lastEscalationAt[key] = [:] }
        lastEscalationAt[key]![reason] = now

        // Bump daily count
        if todayCount[key] == nil { todayCount[key] = [:] }
        todayCount[key]![reason] = currentCount + 1

        // Record outstanding token (oscillation guard)
        if outstandingTokens[key] == nil { outstandingTokens[key] = [:] }
        outstandingTokens[key]![reason] = token

        // Append to ring buffer
        appendRecentEscalation(key: key, at: now)

        // Update profile counts and quality score
        updateProfile(key: key, bundleID: context.bundleID, reason: reason)

        // Bound the tracked-bundle key set on long-running processes.
        pruneStaleBundlesIfNeeded(now: now, keep: key)

        return Decision(allow: true, reason: reason, tokenID: token, denyCause: nil)
    }

    /// Settle a previously issued token. Clears the outstanding entry if the
    /// token still matches (i.e. no newer escalation has superseded it) and
    /// records the outcome for telemetry. `supersededByPrimary` nudges the
    /// app's axQualityScore up (AX recovered before OCR settled — evidence
    /// we escalated prematurely). `timedOut` leaves score unchanged.
    public func settle(tokenID: UUID, result: EscalationResult) async {
        for (key, reasonMap) in outstandingTokens {
            for (reason, outstanding) in reasonMap where outstanding == tokenID {
                outstandingTokens[key]?.removeValue(forKey: reason)
                recordSettlement(key: key, reason: reason, result: result)
                if result == .supersededByPrimary {
                    bumpAXQualityScore(key: key, delta: 0.002)
                }
                return
            }
        }
        // Token not found — already superseded by a newer evaluate() for the
        // same (bundle, reason). Record against a synthetic key so the wasted
        // work still shows up in telemetry.
        recordSettlement(key: "_superseded_", reason: .agentRequestedVerify, result: result)
    }

    private func recordSettlement(key: String, reason: Reason, result: EscalationResult) {
        if settlementCounts[key] == nil { settlementCounts[key] = [:] }
        if settlementCounts[key]![reason] == nil { settlementCounts[key]![reason] = [:] }
        settlementCounts[key]![reason]![result, default: 0] += 1
    }

    private func bumpAXQualityScore(key: String, delta: Double) {
        var p = loadedProfile(key: key, bundleID: key)
        p.axQualityScore = max(0.0, min(1.0, p.axQualityScore + delta))
        updateStrategy(&p)
        profiles[key] = p
    }

    /// Return the current outstanding token for a (bundleID, reason) pair.
    /// Wave 6/7 callers use this to detect oscillation before consuming OCR output.
    public func outstandingToken(bundleID: String?, reason: Reason) async -> UUID? {
        let key = bundleID ?? "_"
        return outstandingTokens[key]?[reason]
    }

    /// Return the escalation profile for a bundle, constructing a default if absent.
    public func profile(forBundle id: String) async -> AppEscalationProfile {
        loadedProfile(key: id, bundleID: id)
    }

    /// Record a successful AX read for a bundle, improving its quality score.
    public func recordAXSuccess(bundle bundleID: String) async {
        var p = loadedProfile(key: bundleID, bundleID: bundleID)
        p.axQualityScore = min(1.0, p.axQualityScore + 0.005)
        updateStrategy(&p)
        profiles[bundleID] = p
        await persistence.save(p)
    }

    /// Aggregate per-bundle tallies for telemetry / diagnostics.
    public func dailyReport() async -> [BundleEscalationTally] {
        var result: [BundleEscalationTally] = []
        let allKeys = Set(todayCount.keys)
            .union(Set(recentEscalations.keys))
            .union(Set(settlementCounts.keys))
        for key in allKeys {
            result.append(BundleEscalationTally(
                bundleID: key,
                reasonCounts: todayCount[key] ?? [:],
                lastEscalations: recentEscalations[key] ?? [],
                settlementCounts: settlementCounts[key] ?? [:]
            ))
        }
        return result
    }

    // MARK: - Private helpers

    private func resetTodayCountsIfNeeded(key: String, now: Date) {
        let start = todayStart[key] ?? now
        if !Calendar.current.isDate(now, inSameDayAs: start) {
            todayCount[key] = [:]
            todayStart[key] = now
        } else if todayStart[key] == nil {
            todayStart[key] = now
        }
    }

    /// Most recent activity timestamp for a bundle key, derived from existing
    /// signals (last ring-buffer escalation, else today-start). `nil` when the
    /// key has no time-stamped activity.
    private func lastActivity(forKey key: String) -> Date? {
        recentEscalations[key]?.last ?? todayStart[key]
    }

    /// Forget all per-bundle state for `key`. Never touches the synthetic
    /// `"_superseded_"` telemetry key (it carries no time-stamped activity, so
    /// the retention sweep already skips it) or the default `"_"` key.
    private func removeBundle(key: String) {
        lastEscalationAt.removeValue(forKey: key)
        todayCount.removeValue(forKey: key)
        todayStart.removeValue(forKey: key)
        outstandingTokens.removeValue(forKey: key)
        recentEscalations.removeValue(forKey: key)
        profiles.removeValue(forKey: key)
        settlementCounts.removeValue(forKey: key)
    }

    /// Drop bundle keys idle past the retention window, then enforce a hard cap
    /// on the number of tracked bundles by evicting the least-recently-active.
    /// `keep` is the key just touched by the current escalation; it is never
    /// evicted. Keys with an outstanding token are also preserved so a pending
    /// `settle` can still match.
    private func pruneStaleBundlesIfNeeded(now: Date, keep: String) {
        func hasOutstanding(_ key: String) -> Bool {
            !(outstandingTokens[key]?.isEmpty ?? true)
        }
        func evictable(_ key: String) -> Bool {
            key != keep && key != "_" && !hasOutstanding(key)
        }

        // 1. Retention sweep: drop keys idle longer than the window.
        //    Snapshot the keys so we can mutate the dictionary while iterating.
        for key in Array(lastEscalationAt.keys) where evictable(key) {
            if let last = lastActivity(forKey: key),
               now.timeIntervalSince(last) > Self.bundleRetention {
                removeBundle(key: key)
            }
        }

        // 2. Hard cap: evict least-recently-active beyond the ceiling.
        if lastEscalationAt.count > Self.maxTrackedBundles {
            let candidates = lastEscalationAt.keys
                .filter(evictable)
                .sorted { (lastActivity(forKey: $0) ?? .distantPast)
                            < (lastActivity(forKey: $1) ?? .distantPast) }
            let overflow = lastEscalationAt.count - Self.maxTrackedBundles
            for key in candidates.prefix(overflow) {
                removeBundle(key: key)
            }
        }
    }

    private func appendRecentEscalation(key: String, at date: Date) {
        if recentEscalations[key] == nil { recentEscalations[key] = [] }
        recentEscalations[key]!.append(date)
        let cap = Self.ringCapacity
        if recentEscalations[key]!.count > cap {
            recentEscalations[key]!.removeFirst(recentEscalations[key]!.count - cap)
        }
    }

    private func loadedProfile(key: String, bundleID: String) -> AppEscalationProfile {
        if let existing = profiles[key] { return existing }
        let fresh = AppEscalationProfile(bundleID: bundleID)
        profiles[key] = fresh
        return fresh
    }

    private func updateProfile(key: String, bundleID: String?, reason: Reason) {
        var p = loadedProfile(key: key, bundleID: bundleID ?? key)

        // Increment seven-day reason count (simple running total in Wave 4;
        // Wave 8 will rotate the seven-day window via dated buckets).
        p.sevenDayCounts[reason, default: 0] += 1

        // Decay quality score on AX-inadequacy signals
        if reason == .axEmpty || reason == .axShallow {
            p.axQualityScore = max(0.0, p.axQualityScore - 0.01)
        }

        updateStrategy(&p)
        profiles[key] = p

        // Fire-and-forget persistence (Wave 4 noop)
        let captured = p
        Task { [weak self] in
            guard let self else { return }
            await self.persistence.save(captured)
        }
    }

    private func updateStrategy(_ p: inout AppEscalationProfile) {
        if p.axQualityScore < 0.1 {
            p.preferredStrategy = .ocrOnly
        } else if p.axQualityScore < 0.3 {
            p.preferredStrategy = .axPlusOcr
        } else {
            p.preferredStrategy = .ax
        }
    }
}
