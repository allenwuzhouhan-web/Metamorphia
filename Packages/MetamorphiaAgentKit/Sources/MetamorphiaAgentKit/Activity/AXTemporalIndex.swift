import CoreGraphics
import Foundation

// MARK: - AXTemporalIndex

/// In-memory ring buffer of AX tree snapshots that answers "what was on screen
/// N seconds ago" queries.
///
/// ## Module boundary
/// `MetamorphiaAgentKit` has no dependency on `MetamorphiaPerception`. Callers
/// in Perception convert their native `AXReader.RawElement` to
/// `AXTemporalIndex.RawElement` at ingest time.
///
/// ## Storage model
/// One `PidRing` per process. The first ingest for a pid stores a full baseline
/// (all elements in `adds`). Subsequent ingests within `snapshotInterval`
/// are skipped entirely; once the interval elapses a delta snapshot is stored.
///
/// ## Eviction
/// Three pressure valves in order:
/// 1. Age: snapshots older than `maxAgeSeconds` are trimmed per-pid.
/// 2. Depth: per-pid rings are capped at `maxSnapshotsPerPid`.
/// 3. Memory: if `totalBytes` exceeds `maxTotalBytes`, the LRU pid is evicted.
public actor AXTemporalIndex {

    // MARK: - Public types

    public struct RawElement: Sendable, Hashable, Codable {
        public let identityHash: UInt64
        public let role: String
        public let title: String?
        public let bounds: CGRect
        public let bytesEstimate: Int

        public init(
            identityHash: UInt64,
            role: String,
            title: String?,
            bounds: CGRect,
            bytesEstimate: Int
        ) {
            self.identityHash = identityHash
            self.role = role
            self.title = title
            self.bounds = bounds
            self.bytesEstimate = bytesEstimate
        }

        /// Canonical byte estimate: role + optional title + fixed overhead for
        /// bounds (4 × 8 bytes), identity hash (8 bytes), and object bookkeeping.
        public static func estimateBytes(role: String, title: String?) -> Int {
            role.utf8.count + (title?.utf8.count ?? 0) + 64
        }

        // Hashable / Equatable are keyed solely on identityHash so Set operations
        // behave like a stable-identity dictionary keyed on that hash.
        public static func == (lhs: RawElement, rhs: RawElement) -> Bool {
            lhs.identityHash == rhs.identityHash
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(identityHash)
        }
    }

    public struct Snapshot: Sendable, Hashable, Codable {
        public let pid: pid_t
        public let at: Date
        /// `true` → full tree stored as `adds`; `false` → delta vs. previous.
        public let baseline: Bool
        public let adds: [RawElement]
        public let removes: [UInt64]
        public let updates: [RawElement]

        /// Sum of bytesEstimate across adds + updates. Removes are negligible
        /// (just UInt64 hashes).
        public var bytesEstimate: Int {
            adds.reduce(0) { $0 + $1.bytesEstimate }
            + updates.reduce(0) { $0 + $1.bytesEstimate }
        }
    }

    // MARK: - Private ring

    private struct PidRing {
        var snapshots: [Snapshot] = []
        var lastAccess: Date = .now
        var bytes: Int = 0
    }

    // MARK: - State

    private var rings: [pid_t: PidRing] = [:]
    private var totalBytes: Int = 0

    // MARK: - Config

    private let maxTotalBytes: Int
    private let maxAgeSeconds: TimeInterval
    private let snapshotInterval: TimeInterval
    private let maxSnapshotsPerPid: Int

    // MARK: - Privacy

    private let sensitiveFieldFilter: @Sendable (String, String?) -> Bool

    // MARK: - Init

    public init(
        maxTotalBytes: Int = 50 * 1_024 * 1_024,
        maxAgeSeconds: TimeInterval = 300,
        snapshotInterval: TimeInterval = 60,
        maxSnapshotsPerPid: Int = 5,
        sensitiveFieldFilter: @escaping @Sendable (String, String?) -> Bool = { role, _ in
            role == "AXSecureTextField"
        }
    ) {
        self.maxTotalBytes = maxTotalBytes
        self.maxAgeSeconds = maxAgeSeconds
        self.snapshotInterval = snapshotInterval
        self.maxSnapshotsPerPid = maxSnapshotsPerPid
        self.sensitiveFieldFilter = sensitiveFieldFilter
    }

    // MARK: - Ingest

    /// Ingest a full current tree for `pid`. The index decides whether to store
    /// as a baseline or delta based on `snapshotInterval` since the last capture.
    public func ingest(pid: pid_t, elements: [RawElement], at: Date = Date()) {
        // 1. Apply sensitive-field filter.
        let sanitized = elements.map { el -> RawElement in
            guard sensitiveFieldFilter(el.role, el.title) else { return el }
            // Redact title; recompute hash and byte estimate without it.
            let newHash = redactedHash(base: el.identityHash)
            let newBytes = RawElement.estimateBytes(role: el.role, title: nil)
            return RawElement(
                identityHash: newHash,
                role: el.role,
                title: nil,
                bounds: el.bounds,
                bytesEstimate: newBytes
            )
        }

        // 2. Look up or create ring.
        var ring = rings[pid] ?? PidRing()
        ring.lastAccess = at

        // 3. Determine whether we need a new snapshot.
        if let lastSnapshot = ring.snapshots.last {
            let elapsed = at.timeIntervalSince(lastSnapshot.at)
            guard elapsed >= snapshotInterval else {
                // Within the interval — update lastAccess and return early.
                rings[pid] = ring
                return
            }
        }

        // 4. Compute and store snapshot.
        let snapshot: Snapshot
        if ring.snapshots.isEmpty {
            // First capture: full baseline.
            snapshot = Snapshot(
                pid: pid,
                at: at,
                baseline: true,
                adds: sanitized,
                removes: [],
                updates: []
            )
        } else {
            // Delta vs. materialized current state.
            let oldSet = materialize(ring, upTo: ring.snapshots.last!.at)
            snapshot = delta(pid: pid, at: at, old: oldSet, new: Set(sanitized))
        }

        // 5. Update bytes.
        let snapshotBytes = snapshot.bytesEstimate
        ring.bytes += snapshotBytes
        totalBytes += snapshotBytes
        ring.snapshots.append(snapshot)

        // 6. Trim by age.
        let cutoff = at.addingTimeInterval(-maxAgeSeconds)
        let before = ring.snapshots.count
        ring.snapshots.removeAll { $0.at < cutoff }
        let trimmedCount = before - ring.snapshots.count
        // Rebasing: if we trimmed non-baseline snapshots the first remaining one
        // must be made into a baseline; handle by recomputing bytes after trim.
        if trimmedCount > 0 {
            rebaseIfNeeded(&ring)
        }

        // 7. Trim by max snapshots per pid.
        while ring.snapshots.count > maxSnapshotsPerPid {
            let dropped = ring.snapshots.removeFirst()
            ring.bytes -= dropped.bytesEstimate
            totalBytes -= dropped.bytesEstimate
        }
        // Rebase again in case we dropped the baseline.
        rebaseIfNeeded(&ring)

        rings[pid] = ring

        // 8. LRU eviction if over memory cap.
        evictIfNeeded()
    }

    // MARK: - Query

    /// Materialise the tree as it existed at `at` for `pid`.
    ///
    /// Applies deltas in chronological order up to and including the last
    /// snapshot whose timestamp is ≤ `at`, then filters by `predicate`.
    public func query(
        pid: pid_t,
        at queryTime: Date,
        predicate: @Sendable (RawElement) -> Bool = { _ in true }
    ) -> [RawElement] {
        guard var ring = rings[pid] else { return [] }
        ring.lastAccess = .now
        rings[pid] = ring

        // Find the last snapshot at or before queryTime.
        guard let targetIdx = ring.snapshots.lastIndex(where: { $0.at <= queryTime }) else {
            return []
        }

        var state: [UInt64: RawElement] = [:]

        for i in 0 ... targetIdx {
            let snap = ring.snapshots[i]
            if snap.baseline {
                // Baseline resets state entirely.
                state = Dictionary(uniqueKeysWithValues: snap.adds.map { ($0.identityHash, $0) })
            } else {
                // Delta: apply removes, then adds (new elements), then updates.
                for hash in snap.removes { state.removeValue(forKey: hash) }
                for el in snap.adds { state[el.identityHash] = el }
                for el in snap.updates { state[el.identityHash] = el }
            }
        }

        return state.values.filter(predicate)
    }

    // MARK: - Forget

    /// Drop all history for `pid` (e.g. on app termination).
    public func forget(pid: pid_t) {
        guard let ring = rings.removeValue(forKey: pid) else { return }
        totalBytes -= ring.bytes
    }

    // MARK: - Diagnostics

    public func memoryUsage() -> (totalBytes: Int, pidCount: Int, snapshotCount: Int) {
        let snapCount = rings.values.reduce(0) { $0 + $1.snapshots.count }
        return (totalBytes, rings.count, snapCount)
    }

    // MARK: - Private helpers

    /// Materialise the tree state up to and including `upTo` from a ring's
    /// snapshot sequence. Returns a Set keyed by identityHash.
    private func materialize(_ ring: PidRing, upTo date: Date) -> Set<RawElement> {
        var state: [UInt64: RawElement] = [:]
        for snap in ring.snapshots where snap.at <= date {
            if snap.baseline {
                state = Dictionary(uniqueKeysWithValues: snap.adds.map { ($0.identityHash, $0) })
            } else {
                for hash in snap.removes { state.removeValue(forKey: hash) }
                for el in snap.adds { state[el.identityHash] = el }
                for el in snap.updates { state[el.identityHash] = el }
            }
        }
        return Set(state.values)
    }

    /// Compute a delta snapshot between `old` and `new` sets.
    private func delta(pid: pid_t, at: Date, old: Set<RawElement>, new: Set<RawElement>) -> Snapshot {
        let oldByHash = Dictionary(uniqueKeysWithValues: old.map { ($0.identityHash, $0) })
        let newByHash = Dictionary(uniqueKeysWithValues: new.map { ($0.identityHash, $0) })

        let addedHashes = Set(newByHash.keys).subtracting(oldByHash.keys)
        let removedHashes = Set(oldByHash.keys).subtracting(newByHash.keys)
        let commonHashes = Set(oldByHash.keys).intersection(newByHash.keys)

        let adds = addedHashes.compactMap { newByHash[$0] }
        let removes = Array(removedHashes)
        // Updates: same hash but element content differs (e.g. bounds shifted).
        // Because Hashable/Equatable are keyed on identityHash, we compare the
        // full struct fields manually here.
        let updates = commonHashes.compactMap { hash -> RawElement? in
            guard let oldEl = oldByHash[hash], let newEl = newByHash[hash] else { return nil }
            return (oldEl.role == newEl.role &&
                    oldEl.title == newEl.title &&
                    oldEl.bounds == newEl.bounds) ? nil : newEl
        }

        return Snapshot(pid: pid, at: at, baseline: false, adds: adds, removes: removes, updates: updates)
    }

    /// When snapshots are trimmed, re-materialise the earliest remaining snapshot
    /// as a baseline so future queries don't need trimmed-away history.
    private func rebaseIfNeeded(_ ring: inout PidRing) {
        guard !ring.snapshots.isEmpty, !ring.snapshots[0].baseline else { return }

        // Materialise state up to first surviving snapshot's time.
        let firstDate = ring.snapshots[0].at
        let rebased = materialize(ring, upTo: firstDate)
        let newBaseline = Snapshot(
            pid: ring.snapshots[0].pid,
            at: firstDate,
            baseline: true,
            adds: Array(rebased),
            removes: [],
            updates: []
        )

        // Recompute bytes: remove old cost of all snapshots, add new baseline.
        let oldBytes = ring.snapshots.reduce(0) { $0 + $1.bytesEstimate }
        ring.snapshots = [newBaseline]
        let newBytes = newBaseline.bytesEstimate
        let delta = newBytes - oldBytes
        ring.bytes += delta
        totalBytes += delta
    }

    /// Evict the LRU pid while `totalBytes` exceeds `maxTotalBytes`.
    private func evictIfNeeded() {
        while totalBytes > maxTotalBytes {
            guard let lruPid = rings.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else {
                break
            }
            let ring = rings.removeValue(forKey: lruPid)!
            totalBytes -= ring.bytes
        }
    }

    /// Derive a redacted identity hash from an existing one, keeping it
    /// stable but distinct from the original so privacy-filtered copies
    /// don't collide with clear-text versions.
    private func redactedHash(base: UInt64) -> UInt64 {
        // XOR with a fixed sentinel so the hash namespace is disjoint.
        base ^ 0xDEAD_BEEF_CAFE_BABE
    }
}
