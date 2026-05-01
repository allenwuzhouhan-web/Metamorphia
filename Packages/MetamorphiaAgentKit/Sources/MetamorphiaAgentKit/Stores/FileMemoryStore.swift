import Foundation

/// File-backed `MemoryStore` with biological retrieval dynamics.
///
/// On every `recall`, matched records are reinforced (LTP) and category-scoped
/// records age via exponential decay. Eviction at capacity prefers the
/// weakest synapses (forgetting curve), not the oldest. Persisted as JSON at
/// the injected `storageURL`; writes are debounced on a background queue so
/// rapid recall bursts don't thrash disk.
public final class FileMemoryStore: MemoryStore, @unchecked Sendable {

    private struct PersistedMemory: Codable, Sendable, Potentiated {
        let id: UUID
        let content: String
        let category: MemoryCategory
        let keywords: [String]
        let timestamp: Date
        var strength: SynapticStrength
        var lastAccessed: Date
        var accessCount: Int
        var createdAt: Date

        /// Satisfies the `Potentiated` protocol; callers that need per-category
        /// decay should use `categoryTau` instead.
        static var decayTau: TimeInterval { SynapseDefaults.tauSemantic }

        /// Tau constant chosen by this record's category. Overrides the static
        /// default so different content types age at biologically plausible rates.
        var categoryTau: TimeInterval {
            MemoryCategoryTau.tau(for: category)
        }

        /// Instance `decayTau` satisfying `Potentiated`. Routes `lazilyDecay(now:)`
        /// through the per-category tau so callers don't need to know which
        /// tau to use — they just call the protocol method.
        var decayTau: TimeInterval { categoryTau }

        func toRecord() -> MemoryRecord {
            MemoryRecord(
                id: id,
                content: content,
                category: category,
                keywords: keywords,
                timestamp: timestamp
            )
        }

        /// True if this record is eligible for eviction. `.entity` records use
        /// a lower threshold (0.01) to prevent full eviction of important entities.
        var isEvictable: Bool {
            category == .entity
                ? strength.value < 0.01
                : strength.value < SynapseDefaults.evictionThreshold
        }
    }

    // MARK: - Category tau constants

    /// Decay time-constants (τ) for each memory category.
    private enum MemoryCategoryTau {
        static func tau(for category: MemoryCategory) -> TimeInterval {
            switch category {
            case .preference:  return SynapseDefaults.tauSemantic
            case .correction:  return SynapseDefaults.tauSemantic
            case .fact:        return SynapseDefaults.tauSemantic
            case .skill:       return SynapseDefaults.tauProcedural
            case .note:        return SynapseDefaults.tauEpisodic
            case .interest:    return 21 * 86_400   // 21 days
            case .thesis:      return 14 * 86_400   // 14 days
            case .thread:      return  7 * 86_400   //  7 days
            case .entity:      return 30 * 86_400   // 30 days
            }
        }
    }

    private let lock = NSLock()
    private var records: [PersistedMemory] = []

    private let storageURL: URL
    private let maxRecords: Int
    private let writeDebounce: TimeInterval

    private let writeQueue = DispatchQueue(label: "FileMemoryStore.write", qos: .utility)
    private var pendingWrite: DispatchWorkItem?

    public init(
        storageURL: URL,
        maxRecords: Int = 2_000,
        writeDebounce: TimeInterval = 0.3
    ) {
        self.storageURL = storageURL
        self.maxRecords = maxRecords
        self.writeDebounce = writeDebounce
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        loadSync()
    }

    // MARK: - MemoryStore

    public func add(_ input: MemoryInput) {
        let now = Date()
        lock.lock()
        records.append(PersistedMemory(
            id: UUID(),
            content: input.content,
            category: input.category,
            keywords: input.keywords,
            timestamp: now,
            strength: SynapticStrength(SynapseDefaults.baseline),
            lastAccessed: now,
            accessCount: 0,
            createdAt: now
        ))
        evictIfOverCapacityUnlocked()
        lock.unlock()
        scheduleWrite()
    }

    public func recall(query: String, category: MemoryCategory, limit: Int) -> [MemoryRecord] {
        let now = Date()
        let queryTokens = Self.tokenize(query)

        lock.lock()

        for i in records.indices where records[i].category == category {
            records[i].lazilyDecay(now: now)
        }

        let scored: [(idx: Int, score: Double)] = records.indices.compactMap { i in
            guard records[i].category == category else { return nil }
            let rel = Self.relevance(rec: records[i], queryTokens: queryTokens)
            if !queryTokens.isEmpty && rel == 0 { return nil }
            let r = queryTokens.isEmpty ? 1.0 : rel
            return (i, records[i].strength.value * r)
        }

        let top = scored.sorted { $0.score > $1.score }.prefix(limit)

        // LTP fires only on real queries. An empty-query bulk scan
        // (system-prompt scrape, recent-activity dump) would otherwise
        // reinforce the top-N records every single time it was invoked,
        // saturating them to 1.0 regardless of actual user engagement.
        if !queryTokens.isEmpty {
            for s in top {
                records[s.idx].reinforceOnRecall(now: now)
            }
        }

        let out = top.map { records[$0.idx].toRecord() }
        lock.unlock()
        scheduleWrite()
        return out
    }

    /// Test helper: the current in-memory count. Forces a flush so on-disk
    /// state can be inspected from tests.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    /// Test helper: synchronously cancel any pending debounced write and
    /// flush the current snapshot to disk. `pendingWrite` is confined to
    /// `writeQueue`, so the cancel/nil must happen inside it too.
    public func flushForTesting() {
        writeQueue.sync {
            self.pendingWrite?.cancel()
            self.pendingWrite = nil
        }
        writeSync()
    }

    /// Test helper: peek the synaptic strength of a stored record by id.
    public func strengthForTesting(id: UUID) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return records.first(where: { $0.id == id })?.strength.value
    }

    // MARK: - Eviction & I/O

    private func evictIfOverCapacityUnlocked() {
        guard records.count > maxRecords else { return }
        // Pass 1: drop records that are below their per-category eviction floor.
        // isEvictable is the authoritative gate — it uses a lower threshold for
        // .entity (0.01) so entity records with strength 0.02..0.05 are protected.
        records.removeAll { $0.isEvictable }
        // Pass 2: if still over capacity, sort survivors by strength ascending
        // and drop the weakest until within the limit.
        if records.count > maxRecords {
            records.sort { $0.strength.value < $1.strength.value }
            records.removeFirst(records.count - maxRecords)
        }
    }

    private func scheduleWrite() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingWrite?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.writeSync() }
            self.pendingWrite = item
            self.writeQueue.asyncAfter(deadline: .now() + self.writeDebounce, execute: item)
        }
    }

    private func writeSync() {
        lock.lock()
        let snapshot = records
        lock.unlock()
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[FileMemoryStore] save failed: \(error)")
        }
    }

    private func loadSync() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            var loaded = try JSONDecoder().decode([PersistedMemory].self, from: data)
            let now = Date()
            for i in loaded.indices { loaded[i].lazilyDecay(now: now) }
            records = loaded
        } catch {
            print("[FileMemoryStore] load failed: \(error)")
        }
    }

    // MARK: - Tokenization

    private static func tokenize(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 2 })
    }

    private static func relevance(rec: PersistedMemory, queryTokens: Set<String>) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let kwHits = Set(rec.keywords.map { $0.lowercased() }).intersection(queryTokens).count
        let content = rec.content.lowercased()
        let contentHits = queryTokens.filter { content.contains($0) }.count
        let total = kwHits * 2 + contentHits
        return Double(total) / Double(queryTokens.count * 2)
    }
}
