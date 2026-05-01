import Foundation
import CryptoKit

/// Multi-signal ranker for Retrace. Fuses BM25 (FTS5), cosine similarity
/// (embeddings), and entity-graph scores via Reciprocal Rank Fusion, then
/// multiplies by temporal, session, recency, and source boosts and adds a
/// tap-feedback term. Candidates are pre-filtered by time window + app +
/// kind to keep cosine scans bounded.
public actor QueryRank {

    public let index: RetraceIndex
    public let resolver: TimeResolver
    public let embed: Embed?
    public let aliasStore: EntityAliasStore?
    public let interestGraph: InterestGraphStore?
    public let extractor: EntityExtractor?

    // Tunables (defaults match the plan):
    public var rrfK: Double = 60
    public var sessionDensityCap: Double = 0.5
    public var recencyHalfLifeDays: Double = 45
    public var defaultAutoWindowDays: Int = 7
    public var maxCandidates: Int = 5000
    public var topN: Int = 200

    public init(
        index: RetraceIndex,
        resolver: TimeResolver,
        embed: Embed?,
        aliasStore: EntityAliasStore?,
        interestGraph: InterestGraphStore?
    ) {
        self.index = index
        self.resolver = resolver
        self.embed = embed
        self.aliasStore = aliasStore
        self.interestGraph = interestGraph

        if let aliasStore {
            self.extractor = EntityExtractor(aliasStore: aliasStore)
        } else {
            self.extractor = nil
        }
    }

    // MARK: - Public search

    public struct SearchResult: Sendable {
        public let scenes: [RecallScene]
        public let window: TimeWindow?
        public let remainder: String
        public let autoNarrowed: Bool
    }

    public func search(_ query: String, now: Date = Date()) async -> SearchResult {
        let resolution = await resolver.resolve(query, now: now)
        let primaryWindow = resolution.windows.max(by: { $0.confidence < $1.confidence })

        var autoNarrowed = false
        let effectiveWindow: TimeWindow = {
            if let w = primaryWindow { return w }
            autoNarrowed = true
            let start = now.addingTimeInterval(-Double(defaultAutoWindowDays) * 86400)
            return TimeWindow(start: start, end: now, confidence: 0.4, sourcePhrase: "last \(defaultAutoWindowDays) days")
        }()

        let textPart = resolution.remainder.isEmpty ? query : resolution.remainder

        // Pre-filter candidates (time + optional app).
        let candidates = index.candidateRowids(
            from: effectiveWindow.start,
            to: effectiveWindow.end,
            apps: nil,
            kinds: nil,
            limit: maxCandidates
        )

        // Fan out three ranked lists.
        async let bm25List = asyncBM25(query: textPart, candidates: candidates)
        async let vecList  = asyncVector(query: textPart, candidates: candidates)
        async let entList  = asyncEntities(query: textPart, candidates: candidates)

        let (bm25, vec, ent) = await (bm25List, vecList, entList)

        // Fuse ranks.
        var rrf: [Int64: Double] = [:]
        func fold(_ list: [(Int64, Double)]) {
            for (i, pair) in list.enumerated() {
                rrf[pair.0, default: 0] += 1.0 / (rrfK + Double(i + 1))
            }
        }
        fold(bm25); fold(vec); fold(ent)

        // Score each candidate.
        let bm25Map = Dictionary(uniqueKeysWithValues: bm25.enumerated().map { ($1.0, $1.1) })
        let vecMap  = Dictionary(uniqueKeysWithValues: vec.enumerated().map { ($1.0, $1.1) })
        let entMap  = Dictionary(uniqueKeysWithValues: ent.enumerated().map { ($1.0, $1.1) })

        var hits: [SearchHit] = []
        hits.reserveCapacity(rrf.count)
        for (rowid, rrfScore) in rrf {
            guard let item = index.fetchItem(rowid: rowid) else { continue }
            let time = timeWeight(for: item.timestamp, window: effectiveWindow)
            let recency = exp(-ageInDays(item.timestamp, now: now) / recencyHalfLifeDays)
            let source = sourceBoost(for: item)
            let final = rrfScore * time * recency * source
            hits.append(SearchHit(
                item: item, rowid: rowid,
                bm25: bm25Map[rowid] ?? 0,
                cosine: vecMap[rowid] ?? 0,
                entityScore: entMap[rowid] ?? 0,
                finalScore: final
            ))
        }
        hits.sort { $0.finalScore > $1.finalScore }
        if hits.count > topN { hits.removeLast(hits.count - topN) }

        // Apply session-density boost once top-N is known.
        let boostedHits = applySessionDensity(hits)

        // Group into scenes.
        let scenes = SceneGroup.cluster(hits: boostedHits, anchor: effectiveWindow.anchor)

        return SearchResult(scenes: scenes, window: primaryWindow, remainder: resolution.remainder, autoNarrowed: autoNarrowed)
    }

    // MARK: - Ranked sources

    private func asyncBM25(query: String, candidates: [Int64]) async -> [(Int64, Double)] {
        guard !query.isEmpty else { return [] }
        let rowids: [Int64]? = candidates.isEmpty ? nil : candidates
        return index.ftsSearch(query, rowids: rowids, limit: topN)
    }

    private func asyncVector(query: String, candidates: [Int64]) async -> [(Int64, Double)] {
        guard let embed = embed else { return [] }
        guard let vec = await embed.embed(query) else { return [] }
        let rowids: [Int64]? = candidates.isEmpty ? nil : candidates
        return index.nearest(to: vec, candidates: rowids, limit: topN)
    }

    private func asyncEntities(query: String, candidates: [Int64]) async -> [(Int64, Double)] {
        guard let extractor = extractor else { return [] }
        let entities = await extractor.extract(query)
        guard !entities.isEmpty else { return [] }

        // Score each candidate by overlap + interest-graph weight.
        var scores: [Int64: Double] = [:]
        let candSet = Set(candidates)

        for entity in entities {
            let rowidsForEntity = index.rowidsForEntity(canonical: entity.canonicalName)
            let graphWeight = await interestGraph?.score(entity: entity.canonicalName) ?? 0.5
            for rowid in rowidsForEntity where candSet.contains(rowid) {
                scores[rowid, default: 0] += entity.confidence * (0.5 + graphWeight)
            }
        }

        return scores.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: - Boosts

    private func timeWeight(for ts: Date, window: TimeWindow) -> Double {
        let half = max(1800.0, window.span / 2)
        let deltaFromCenter = abs(ts.timeIntervalSince(window.center))
        // Inside the window: full weight. Outside: exponential decay scaled
        // by confidence (low-confidence windows decay faster).
        if ts >= window.start && ts <= window.end { return 1.0 }
        let softness = max(0.3, window.confidence)
        return exp(-deltaFromCenter / (half * softness))
    }

    private func sourceBoost(for item: IndexedItem) -> Double {
        let chromeLike: Set<String> = [
            "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
            "com.microsoft.edgemac", "com.brave.Browser"
        ]
        switch item.kind {
        case .file:      return 1.20
        case .screen:
            if let app = item.appBundleID, chromeLike.contains(app) { return 1.15 }
            if item.appBundleID == "com.microsoft.VSCode" { return 1.10 }
            return 1.0
        case .email:     return 1.10
        case .calendar:  return 1.10
        case .browser:   return 1.05
        case .message:   return 1.00
        case .clip:      return 0.85
        case .agentTurn: return 0.70
        }
    }

    private func applySessionDensity(_ hits: [SearchHit]) -> [SearchHit] {
        var sessionCount: [UUID: Int] = [:]
        for hit in hits {
            if let sid = hit.item.sessionID { sessionCount[sid, default: 0] += 1 }
        }
        let maxCount = max(1, sessionCount.values.max() ?? 1)

        return hits.map { hit -> SearchHit in
            guard let sid = hit.item.sessionID else { return hit }
            let density = Double(sessionCount[sid] ?? 1) / Double(maxCount)
            let boost = 1.0 + sessionDensityCap * density
            return SearchHit(
                item: hit.item, rowid: hit.rowid,
                bm25: hit.bm25, cosine: hit.cosine, entityScore: hit.entityScore,
                finalScore: hit.finalScore * boost
            )
        }
        .sorted { $0.finalScore > $1.finalScore }
    }

    private func ageInDays(_ ts: Date, now: Date) -> Double {
        max(0, now.timeIntervalSince(ts) / 86400.0)
    }

    // MARK: - Feedback

    public func recordTap(rowid: Int64, query: String) async {
        let hash = Self.normalizedQueryHash(query)
        index.recordTap(rowid: rowid, queryHash: hash)
    }

    // MARK: - Query hashing (for tap logging)

    public static func normalizedQueryHash(_ query: String) -> UInt64 {
        let normalized = query
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        var h: UInt64 = 0
        digest.withUnsafeBytes { raw in
            for i in 0..<8 {
                h |= UInt64(raw[i]) << UInt64(i * 8)
            }
        }
        return h
    }
}
