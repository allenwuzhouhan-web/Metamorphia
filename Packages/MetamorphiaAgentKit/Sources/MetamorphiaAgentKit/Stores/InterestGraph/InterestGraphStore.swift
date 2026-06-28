import Foundation

// MARK: - Interest event kinds

/// A discrete signal that affected an entity's weight in the interest graph.
public enum InterestEvent: String, Sendable, Codable {
    case queryMention      // +0.08
    case clipboardCopy     // +0.04
    case toolCallSubject   // +0.06
    case longDwell         // +0.02
    case dismissedBoring   // -0.10

    /// Signed delta in [−1, 1]. Positive values use LTP saturation;
    /// negative values use a floor-clamped subtraction.
    var delta: Double {
        switch self {
        case .queryMention:    return  0.08
        case .clipboardCopy:   return  0.04
        case .toolCallSubject: return  0.06
        case .longDwell:       return  0.02
        case .dismissedBoring: return -0.10
        }
    }

    var salienceReason: SalienceReason {
        switch self {
        case .queryMention:    return .recentMention
        case .clipboardCopy:   return .clipboardSignal
        case .toolCallSubject: return .toolSubject
        case .longDwell:       return .persistentInterest
        case .dismissedBoring: return .userDismissed
        }
    }
}

// MARK: - Salience reasons

/// Human-readable rationale for why an entity scored highly right now.
public enum SalienceReason: String, Sendable, Codable {
    case recentMention
    case persistentInterest
    case toolSubject
    case clipboardSignal
    case coOccurrence
    case userDismissed
}

// MARK: - Interest node

/// A single entity in the interest graph with its synaptic weight and metadata.
public struct InterestNode: Sendable, Codable, Hashable {
    public let entityId: String
    public let type: EntityType
    public internal(set) var weight: SynapticStrength
    public internal(set) var lastSeen: Date
    public let firstSeen: Date
    /// Co-occurrence counts with other entity IDs.
    public internal(set) var coOccurrences: [String: Int]
    /// Last 5 salience reasons that touched this node (FIFO, most recent last).
    public internal(set) var salienceReasons: [SalienceReason]

    public init(
        entityId: String,
        type: EntityType,
        now: Date = Date()
    ) {
        self.entityId = entityId
        self.type = type
        self.weight = SynapticStrength(SynapseDefaults.baseline)
        self.lastSeen = now
        self.firstSeen = now
        self.coOccurrences = [:]
        self.salienceReasons = []
    }

    /// Apply lazy exponential decay based on time elapsed since `lastSeen`.
    /// Tau is 21 days (semantic interest).
    mutating func lazilyDecay(now: Date) {
        let elapsed = now.timeIntervalSince(lastSeen)
        weight.decay(elapsed: elapsed, tau: InterestGraphStore.decayTau)
        lastSeen = now
    }

    /// Apply a potentiation event with an optional scale factor (0 < scale ≤ 1).
    mutating func apply(event: InterestEvent, scale: Double = 1.0) {
        let delta = event.delta * max(0.0, min(1.0, scale))
        if delta > 0 {
            // Hebbian LTP: saturates near 1.0
            let headroom = 1.0 - weight.value
            weight = SynapticStrength(weight.value + delta * headroom)
        } else if delta < 0 {
            // Negative signal: floor at 0
            weight = SynapticStrength(max(0.0, weight.value + delta))
        }
        // Append salience reason (keep last 5, FIFO)
        salienceReasons.append(event.salienceReason)
        if salienceReasons.count > 5 {
            salienceReasons.removeFirst(salienceReasons.count - 5)
        }
    }

    // MARK: - Hashable / Equatable

    public static func == (lhs: InterestNode, rhs: InterestNode) -> Bool {
        lhs.entityId == rhs.entityId && lhs.type == rhs.type
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(entityId)
        hasher.combine(type)
    }
}

// MARK: - InterestGraphStore

/// Persistent, decaying, encrypted weight map of user-interest entities.
///
/// Potentiation is event-driven: callers call `potentiate(...)` whenever a
/// user signal touches an entity. Weights decay exponentially (tau = 21 days)
/// and are applied lazily on read. Nodes are evicted when the store exceeds
/// `maxNodes`, preferring nodes below `floorWeight`, then by ascending weight.
///
/// Persistence: JSON encrypted at rest via `SecurePersistence`. If the Keychain
/// is unavailable, the store falls back to plain-JSON (logged once) so the
/// feature degrades gracefully rather than crashing.
public actor InterestGraphStore {

    // MARK: - Constants

    static let decayTau: TimeInterval = 21 * 86_400   // 21 days

    /// Max co-occurrence edges retained per node. Set well above any
    /// `edgesOut(entity:limit:)` query so trimming only discards low-count
    /// tail edges that would never surface in a top-`limit` result.
    private static let maxCoOccurrences = 64

    // MARK: - State

    private var nodes: [String: InterestNode] = [:]   // entityId → node
    private let maxNodes: Int
    private let floorWeight: Double

    private let storageURL: URL
    private let securePersistence: SecurePersistence?   // nil → plain JSON fallback
    private var pendingWriteTask: Task<Void, Never>?
    private let writeDebounce: TimeInterval = 0.5

    // MARK: - Lifecycle

    public init(
        location: URL? = nil,
        maxNodes: Int = 500,
        floorWeight: Double = 0.02
    ) {
        self.maxNodes = maxNodes
        self.floorWeight = floorWeight

        let url = location ?? URL.applicationSupportDirectory
            .appendingPathComponent("Metamorphia", isDirectory: true)
            .appendingPathComponent("interest-graph.enc")
        self.storageURL = url

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Resolve encryption key. Fall back to plain JSON on Keychain denial.
        var secure: SecurePersistence?
        do {
            secure = try SecurePersistence(serviceTag: "com.metamorphia.interestgraph.v1")
        } catch {
            print("[InterestGraphStore] Keychain unavailable (\(error.localizedDescription)); using plain JSON.")
        }
        self.securePersistence = secure

        self.nodes = Self.readFromDisk(
            at: url,
            fallback: url.deletingPathExtension().appendingPathExtension("json"),
            secure: secure
        )
    }

    // MARK: - Read API

    /// Top-N entities by current weight, optionally filtered by `EntityType`.
    public func topInterests(type: EntityType? = nil, count: Int = 10) -> [InterestNode] {
        let now = Date()
        var decayed = applyDecayAll(now: now)
        if let t = type {
            decayed = decayed.filter { $0.type == t }
        }
        return decayed.sorted { $0.weight.value > $1.weight.value }.prefix(count).map { $0 }
    }

    /// Current weight for `entity` (0 if unknown), decay applied lazily.
    public func score(entity: String) -> Double {
        guard var node = nodes[entity] else { return 0 }
        node.lazilyDecay(now: Date())
        nodes[entity] = node
        return node.weight.value
    }

    /// Up to `limit` co-occurring entities, sorted descending by co-occurrence count.
    public func edgesOut(entity: String, limit: Int = 10) -> [(entity: String, weight: Double)] {
        guard let node = nodes[entity] else { return [] }
        return node.coOccurrences
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (entity: $0.key, weight: Double($0.value)) }
    }

    /// Full snapshot — decay applied to all nodes before returning.
    public func snapshot() -> [InterestNode] {
        applyDecayAll(now: Date())
    }

    /// Number of tracked entities.
    public func nodeCount() -> Int {
        nodes.count
    }

    // MARK: - Write API

    /// Potentiate a batch of extracted entities (same co-occurrence group).
    /// - Parameters:
    ///   - entities: Entities extracted from the same turn / notification.
    ///   - event: The signal kind to apply.
    ///   - coOccurringWith: Additional entity IDs to pair for co-occurrence counts.
    ///   - scale: Multiplier for the event delta (use 0.5 for backfill half-strength).
    public func potentiate(
        entities: [ExtractedEntity],
        event: InterestEvent,
        coOccurringWith extra: [String] = [],
        scale: Double = 1.0
    ) {
        let now = Date()
        var ids: [String] = []

        for entity in entities {
            let key = entity.canonicalName
            ids.append(key)
            var node = nodes[key] ?? InterestNode(entityId: key, type: entity.type, now: now)
            node.lazilyDecay(now: now)
            node.apply(event: event, scale: scale)
            node.lastSeen = now
            nodes[key] = node
        }

        let allIds = ids + extra

        // Bump pairwise co-occurrence counts for all entities in the same batch.
        for i in allIds.indices {
            for j in allIds.indices where j != i {
                if nodes[allIds[i]] != nil {
                    nodes[allIds[i]]!.coOccurrences[allIds[j], default: 0] += 1
                }
            }
        }

        // Bound each touched node's co-occurrence map so a frequently-seen
        // entity can't accumulate an unbounded key set across the app's life.
        for id in Set(allIds) where nodes[id] != nil {
            trimCoOccurrences(&nodes[id]!)
        }

        evictIfNeeded()
        scheduleWrite()
    }

    /// Potentiate a single entity by ID and type.
    public func potentiate(
        entity: String,
        type: EntityType,
        event: InterestEvent,
        scale: Double = 1.0
    ) {
        let now = Date()
        var node = nodes[entity] ?? InterestNode(entityId: entity, type: type, now: now)
        node.lazilyDecay(now: now)
        node.apply(event: event, scale: scale)
        node.lastSeen = now
        nodes[entity] = node
        evictIfNeeded()
        scheduleWrite()
    }

    /// Remove a specific entity permanently (user-initiated "forget").
    public func prune(entity: String) {
        nodes.removeValue(forKey: entity)
        scheduleWrite()
    }

    /// Wipe the entire graph.
    public func forgetAll() {
        nodes.removeAll()
        scheduleWrite()
    }

    // MARK: - Decay helpers

    private func applyDecayAll(now: Date) -> [InterestNode] {
        var result: [InterestNode] = []
        for key in nodes.keys {
            var node = nodes[key]!
            node.lazilyDecay(now: now)
            nodes[key] = node
            result.append(node)
        }
        return result
    }

    // MARK: - Eviction

    private func evictIfNeeded() {
        guard nodes.count > maxNodes else { return }

        // Pass 1: drop nodes below floorWeight.
        for (key, node) in nodes where node.weight.value < floorWeight {
            nodes.removeValue(forKey: key)
        }
        guard nodes.count > maxNodes else { return }

        // Pass 2: sort survivors and drop weakest, preserving .entity type in ties.
        let sorted = nodes.values.sorted { a, b in
            if a.weight.value != b.weight.value {
                return a.weight.value < b.weight.value   // weakest first
            }
            // In a tie, prefer to evict .topic and .place before .entity.
            let aScore = typeEvictionPriority(a.type)
            let bScore = typeEvictionPriority(b.type)
            return aScore < bScore
        }
        let dropCount = nodes.count - maxNodes
        for node in sorted.prefix(dropCount) {
            nodes.removeValue(forKey: node.entityId)
        }
    }

    /// Keep only the highest-count co-occurrence edges once the map grows
    /// past twice the cap, discarding the low-count tail. Hysteresis (trim at
    /// 2*K, keep K) avoids re-sorting on every potentiate.
    private func trimCoOccurrences(_ node: inout InterestNode) {
        let k = Self.maxCoOccurrences
        guard node.coOccurrences.count > 2 * k else { return }
        let topEdges = node.coOccurrences.sorted { $0.value > $1.value }
            .prefix(k)
            .map { ($0.key, $0.value) }
        node.coOccurrences = Dictionary(topEdges, uniquingKeysWith: { a, _ in a })
    }

    /// Lower = evicted first. `.entity`-type nodes survive longest.
    private func typeEvictionPriority(_ type: EntityType) -> Int {
        switch type {
        case .person, .org, .ticker: return 3   // preserve longest
        case .url, .paper, .repo:    return 2
        case .topic, .place:         return 1   // evict first in ties
        }
    }

    // MARK: - Persistence

    // Persistence file: interest-graph.enc (encrypted) or interest-graph.json (fallback).
    // The URL always points to the .enc path; the plain fallback writes alongside as .json.

    private var plainFallbackURL: URL {
        storageURL.deletingPathExtension().appendingPathExtension("json")
    }

    private func scheduleWrite() {
        // Cancel any in-flight debounce task before starting a new one.
        // Both the cancel and the new Task assignment happen on the actor,
        // so there is no data race on `pendingWriteTask`.
        pendingWriteTask?.cancel()
        let snapshot = Array(nodes.values)
        let debounce = writeDebounce
        pendingWriteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performWrite(snapshot: snapshot)
        }
    }

    private func performWrite(snapshot: [InterestNode]) async {
        // Capture values needed for I/O before leaving the actor.
        let secure = self.securePersistence
        let encURL = self.storageURL
        let plainURL = self.plainFallbackURL

        // Dispatch the blocking encrypt + write off-actor so we don't hold
        // the actor during disk I/O.
        await Task.detached(priority: .utility) {
            do {
                let json = try JSONEncoder().encode(snapshot)
                if let secure {
                    let encrypted = try secure.encrypt(json)
                    try encrypted.write(to: encURL, options: .atomic)
                } else {
                    try json.write(to: plainURL, options: .atomic)
                }
            } catch {
                print("[InterestGraphStore] save failed: \(error)")
            }
        }.value
    }

    nonisolated private static func readFromDisk(
        at encURL: URL,
        fallback: URL,
        secure: SecurePersistence?
    ) -> [String: InterestNode] {
        let now = Date()

        // Try encrypted file first, then plain JSON fallback.
        if let secure,
           let encData = try? Data(contentsOf: encURL),
           !encData.isEmpty {
            if let json = try? secure.decrypt(encData),
               var loaded = try? JSONDecoder().decode([InterestNode].self, from: json) {
                for i in loaded.indices { loaded[i].lazilyDecay(now: now) }
                return Dictionary(loaded.map { ($0.entityId, $0) }, uniquingKeysWith: { _, new in new })
            } else {
                print("[InterestGraphStore] failed to decrypt; attempting plain JSON fallback.")
            }
        }

        // Plain JSON fallback path.
        guard FileManager.default.fileExists(atPath: fallback.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fallback)
            var loaded = try JSONDecoder().decode([InterestNode].self, from: data)
            for i in loaded.indices { loaded[i].lazilyDecay(now: now) }
            return Dictionary(loaded.map { ($0.entityId, $0) }, uniquingKeysWith: { _, new in new })
        } catch {
            print("[InterestGraphStore] load failed: \(error)")
            return [:]
        }
    }
}
