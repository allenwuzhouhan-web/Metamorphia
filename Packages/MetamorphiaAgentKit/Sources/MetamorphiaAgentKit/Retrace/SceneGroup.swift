import Foundation

/// A cluster of recalled items surfaced together in the UI. Items share a
/// session (or time bucket + app), plus enough entity overlap to be "about
/// the same thing." A scene has a hero item, a timeline ribbon of siblings,
/// and chip entities for the UI.
public struct RecallScene: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let span: ClosedRange<Date>
    public let sessionIDs: Set<UUID>
    public let chipEntities: [String]
    public let members: [SearchHit]
    public let anchorReason: String?

    public var hero: SearchHit { members.first! }
    public var sceneScore: Double {
        let topThree = members.prefix(3).map(\.finalScore)
        return topThree.reduce(0, +)
    }

    public init(id: UUID = UUID(), span: ClosedRange<Date>, sessionIDs: Set<UUID>, chipEntities: [String], members: [SearchHit], anchorReason: String?) {
        self.id = id
        self.span = span
        self.sessionIDs = sessionIDs
        self.chipEntities = chipEntities
        self.members = members
        self.anchorReason = anchorReason
    }
}

public enum SceneGroup {

    /// Cluster search hits into coherent scenes. Called after ranking has
    /// narrowed to top-N candidates.
    public static func cluster(hits: [SearchHit], anchor: TimeWindow.Anchor?) -> [RecallScene] {
        guard !hits.isEmpty else { return [] }

        // Step 1 — seed groups by session_id, or by 15-min bucket ∩ app if no session.
        var groups: [[SearchHit]] = []
        var assigned: [Int64: Int] = [:]  // rowid → group index

        for hit in hits {
            let key = sessionOrBucketKey(for: hit)
            if let existingIndex = findGroupWithKey(key, groups: groups) {
                groups[existingIndex].append(hit)
                assigned[hit.rowid] = existingIndex
            } else {
                assigned[hit.rowid] = groups.count
                groups.append([hit])
            }
        }

        // Step 2 — compute entity sets per group.
        var metas = groups.map { group -> GroupMeta in
            let ents = entitiesFromHits(group)
            let ts = group.map(\.item.timestamp)
            return GroupMeta(entities: ents, start: ts.min() ?? Date.distantPast, end: ts.max() ?? Date.distantFuture)
        }

        // Step 3 — merge pairwise on entity overlap + time proximity.
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<groups.count {
                for j in (i+1)..<groups.count {
                    let a = metas[i], b = metas[j]
                    if timeDistance(a.start, a.end, b.start, b.end) > 6 * 3600 { continue }
                    if jaccardAsymmetric(a.entities, b.entities) >= 0.4 {
                        groups[i].append(contentsOf: groups[j])
                        metas[i].entities.formUnion(metas[j].entities)
                        metas[i].start = min(metas[i].start, metas[j].start)
                        metas[i].end = max(metas[i].end, metas[j].end)
                        groups.remove(at: j)
                        metas.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }

        // Step 4 — build RecallScene values.
        let anchorReason: String? = {
            guard let anchor else { return nil }
            switch anchor {
            case .calendarEvent(_, let title): return "during '\(title)'"
            case .meeting:                     return "during a meeting"
            case .placeLabel(let label):       return "while at \(label)"
            }
        }()

        var scenes = groups.enumerated().map { (i, group) -> RecallScene in
            let sorted = group.sorted { $0.finalScore > $1.finalScore }
            let capped = Array(sorted.prefix(10))
            let sessionIDs = Set(capped.compactMap { $0.item.sessionID })
            let entities = metas[i].entities
            let topEntities = Array(entities.prefix(3))
            return RecallScene(
                span: metas[i].start...metas[i].end,
                sessionIDs: sessionIDs,
                chipEntities: topEntities,
                members: capped,
                anchorReason: anchorReason
            )
        }
        scenes.sort { $0.sceneScore > $1.sceneScore }
        return scenes
    }

    // MARK: - Helpers

    private static func sessionOrBucketKey(for hit: SearchHit) -> String {
        if let sid = hit.item.sessionID {
            return "session:\(sid.uuidString)"
        }
        let ts = hit.item.timestamp.timeIntervalSince1970
        let bucket = Int(ts / 900)  // 15-min buckets
        let app = hit.item.appBundleID ?? "unknown"
        return "bucket:\(bucket):\(app)"
    }

    private static func findGroupWithKey(_ key: String, groups: [[SearchHit]]) -> Int? {
        for (i, group) in groups.enumerated() {
            if let first = group.first, sessionOrBucketKey(for: first) == key {
                return i
            }
        }
        return nil
    }

    private static func entitiesFromHits(_ hits: [SearchHit]) -> Set<String> {
        // We don't have entities-per-hit bundled in the SearchHit, so derive
        // from the body via a simple top-term heuristic for grouping.
        // Callers can replace this with a proper entity fetch later.
        var ents: Set<String> = []
        for hit in hits {
            if let title = hit.item.title {
                let tokens = title.split(whereSeparator: { !$0.isLetter })
                for t in tokens where t.count >= 4 {
                    ents.insert(t.lowercased())
                }
            }
        }
        return ents
    }

    private static func jaccardAsymmetric(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let smaller = min(a.count, b.count)
        return Double(inter) / Double(smaller)
    }

    private static func timeDistance(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> TimeInterval {
        if aEnd >= bStart && bEnd >= aStart { return 0 }
        return min(abs(aEnd.timeIntervalSince(bStart)), abs(bEnd.timeIntervalSince(aStart)))
    }
}

private struct GroupMeta {
    var entities: Set<String>
    var start: Date
    var end: Date
}
