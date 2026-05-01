import Foundation

/// Rank 2 — Per-session snapshot cache for delta encoding.
///
/// Each `captureDelta` call keyed by a `sessionID` stores the freshly-captured
/// `ScreenMap` + its tier snapshot and the accompanying sequence number into
/// this actor. The next call in the same session reads back the previous
/// entry so `DeltaEncoder.buildPayload` can diff against it.
///
/// Properties of this implementation:
/// - **Actor-isolated.** All mutation happens on the actor's serial executor,
///   so concurrent stores for different session IDs don't race.
/// - **LRU-capped.** `maxSessions` (default 64) hard cap. Least-recently-stored
///   session is evicted on overflow.
/// - **Idle-timed.** Entries untouched for `idleTimeout` seconds (default
///   300) are dropped via `pruneIdleSessions`. Auto-pruning also happens
///   lazily during `store` / `fetch` / `nextSequenceNumber`.
/// - **Sequence-aware.** `nextSequenceNumber(for:)` auto-increments per session
///   starting at 0. Callers call it once per `captureDelta` before `store`.
///
/// The cache is deliberately stateless outside per-session entries — no global
/// clock, no shared counters. Two `SnapshotCache` instances can coexist if a
/// test wants to avoid the shared singleton.
public actor SnapshotCache {
    public static let shared = SnapshotCache()

    // MARK: Entry shape

    private struct Entry {
        /// Optional: stored on the first successful `store`. Entries whose
        /// `map` is nil exist only to track the per-session sequence counter
        /// before the first store completes.
        var map: ScreenMap?
        var tiers: [ElementRef: IdentityTier]
        /// Last-touched timestamp for idle-timeout eviction.
        var lastTouched: Date
        /// Next sequence number to hand out for this session. Initialized to 0
        /// on the first `nextSequenceNumber` call and incremented afterwards.
        var nextSequence: Int
        /// Monotonic access counter used for LRU eviction. Bumped on `store`
        /// AND `fetch` so the most-recently-used entry survives when the cap
        /// is exceeded. Higher = more recently accessed.
        var lastAccessOrder: UInt64
    }

    // MARK: Config

    private let maxSessions: Int
    private let idleTimeout: TimeInterval

    // MARK: State

    private var entries: [String: Entry] = [:]
    /// Rolling access counter bumped on each `store` + `fetch` for LRU.
    private var accessCounter: UInt64 = 0

    public init(maxSessions: Int = 64, idleTimeout: TimeInterval = 300) {
        self.maxSessions = max(1, maxSessions)
        self.idleTimeout = max(1, idleTimeout)
    }

    // MARK: - Public API

    /// Store the freshly-captured snapshot + tiers into the cache under
    /// `sessionID`. Touches the entry's last-access time for idle tracking and
    /// bumps the LRU counter. Evicts older entries if the session count would
    /// exceed `maxSessions`.
    public func store(
        sessionID: String,
        map: ScreenMap,
        tiers: [ElementRef: IdentityTier]
    ) {
        pruneIdleLocked()
        accessCounter += 1
        let now = Date()
        let existing = entries[sessionID]
        let entry = Entry(
            map: map,
            tiers: tiers,
            lastTouched: now,
            nextSequence: existing?.nextSequence ?? 0,
            lastAccessOrder: accessCounter
        )
        entries[sessionID] = entry
        evictLRUIfNeededLocked()
    }

    /// Fetch the most-recent snapshot stored for this session. Returns nil if
    /// the session has no stored map or the entry has expired. Touches
    /// `lastTouched` + `lastAccessOrder` on a hit so idle + LRU eviction
    /// won't drop an active session.
    public func fetch(sessionID: String) -> (map: ScreenMap, tiers: [ElementRef: IdentityTier])? {
        pruneIdleLocked()
        guard var entry = entries[sessionID], let map = entry.map else { return nil }
        accessCounter += 1
        entry.lastTouched = Date()
        entry.lastAccessOrder = accessCounter
        entries[sessionID] = entry
        return (map, entry.tiers)
    }

    /// Drop the entry for this session. Idempotent; a no-op if the session
    /// has no entry.
    public func reset(sessionID: String) {
        entries.removeValue(forKey: sessionID)
    }

    /// Return the next sequence number for this session and auto-increment.
    /// First call returns 0, second returns 1, etc. The sequence counter is
    /// independent of whether a map has been stored yet — callers can request
    /// a sequence number before calling `store`. Creates a placeholder entry
    /// (with `map == nil`) so subsequent stores preserve the counter.
    public func nextSequenceNumber(for sessionID: String) -> Int {
        pruneIdleLocked()
        accessCounter += 1
        if var entry = entries[sessionID] {
            let next = entry.nextSequence
            entry.nextSequence = next + 1
            entry.lastTouched = Date()
            entry.lastAccessOrder = accessCounter
            entries[sessionID] = entry
            return next
        }
        // Seed a placeholder entry so subsequent calls remember the counter.
        // `fetch` guards against nil `map` so placeholders don't surface as
        // false-positives.
        let entry = Entry(
            map: nil,
            tiers: [:],
            lastTouched: Date(),
            nextSequence: 1,
            lastAccessOrder: accessCounter
        )
        entries[sessionID] = entry
        evictLRUIfNeededLocked()
        return 0
    }

    /// Evict all entries whose `lastTouched` is older than `idleTimeout`.
    /// Also dispatched automatically from `store`/`fetch`/`nextSequenceNumber`.
    public func pruneIdleSessions() {
        pruneIdleLocked()
    }

    // MARK: - Internal

    private func pruneIdleLocked() {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        entries = entries.filter { $0.value.lastTouched > cutoff }
    }

    private func evictLRUIfNeededLocked() {
        guard entries.count > maxSessions else { return }
        // Evict the entry with the smallest `lastAccessOrder` until we're at cap.
        while entries.count > maxSessions {
            guard let victim = entries.min(by: { $0.value.lastAccessOrder < $1.value.lastAccessOrder })?.key else {
                break
            }
            entries.removeValue(forKey: victim)
        }
    }
}
