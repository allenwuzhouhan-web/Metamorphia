import Foundation
import CryptoKit

/// The single ingest funnel for every Retrace source. Each archiver builds a
/// `Draft` and hands it here. ``RetraceIngest`` then:
///
///   1. Inserts the item into `RetraceIndex` (FTS5 triggers populate the
///      search table automatically).
///   2. Runs `EntityExtractor` over `title + body` and links canonical
///      entities via `RetraceIndex.linkEntity`.
///   3. Potentiates the `InterestGraphStore` with the extracted entities
///      (using `.longDwell` for read-heavy frames, `.clipboardCopy` for
///      clips, `.toolCallSubject` for agent turns).
///   4. Generates an embedding via ``Embed`` (best-effort; skipped silently
///      on assetless systems or empty bodies).
///   5. Emits the source-appropriate `ActivityEvent` receipt into
///      `ActivityStream`.
///
/// The pipeline holds weak references to its collaborators so the host app
/// stays in control of lifecycle. Every call is idempotent via content-hash:
/// re-ingesting the same screen frame/file/clip is a no-op at the DB layer.
public actor RetraceIngest {

    public static var shared: RetraceIngest?

    public static func configureShared(
        index: RetraceIndex,
        aliasStore: EntityAliasStore?,
        termFrequency: RollingTermFrequency?,
        interestGraph: InterestGraphStore?,
        activityStream: ActivityStream?,
        embed: Embed? = Embed.shared
    ) -> RetraceIngest {
        let instance = RetraceIngest(
            index: index,
            aliasStore: aliasStore,
            termFrequency: termFrequency,
            interestGraph: interestGraph,
            activityStream: activityStream,
            embed: embed
        )
        shared = instance
        return instance
    }

    public let index: RetraceIndex
    private let aliasStore: EntityAliasStore?
    private let termFrequency: RollingTermFrequency?
    private let interestGraph: InterestGraphStore?
    private let activityStream: ActivityStream?
    private let embed: Embed?

    private let extractor: EntityExtractor?

    public init(
        index: RetraceIndex,
        aliasStore: EntityAliasStore?,
        termFrequency: RollingTermFrequency?,
        interestGraph: InterestGraphStore?,
        activityStream: ActivityStream?,
        embed: Embed? = Embed.shared
    ) {
        self.index = index
        self.aliasStore = aliasStore
        self.termFrequency = termFrequency
        self.interestGraph = interestGraph
        self.activityStream = activityStream
        self.embed = embed

        if let aliasStore {
            if let termFrequency {
                self.extractor = EntityExtractor(aliasStore: aliasStore, termFrequency: termFrequency)
            } else {
                self.extractor = EntityExtractor(aliasStore: aliasStore)
            }
        } else {
            self.extractor = nil
        }
    }

    // MARK: - Draft

    /// The unit of ingestion across sources. Archivers build this and hand it
    /// to ``ingest(_:)``; the pipeline takes over from there.
    public struct Draft: Sendable {
        public var kind: ItemKind
        public var timestamp: Date
        public var sessionID: UUID?
        public var appBundleID: String?
        public var docPath: String?
        public var url: String?
        public var placeHash: String?
        public var title: String?
        public var body: String
        public var confidence: Double
        public var sourceMeta: [String: String]?
        public var interestEvent: InterestEvent
        public var interestScale: Double

        public init(
            kind: ItemKind,
            timestamp: Date = Date(),
            sessionID: UUID? = nil,
            appBundleID: String? = nil,
            docPath: String? = nil,
            url: String? = nil,
            placeHash: String? = nil,
            title: String? = nil,
            body: String,
            confidence: Double = 1.0,
            sourceMeta: [String: String]? = nil,
            interestEvent: InterestEvent = .longDwell,
            interestScale: Double = 0.3
        ) {
            self.kind = kind
            self.timestamp = timestamp
            self.sessionID = sessionID
            self.appBundleID = appBundleID
            self.docPath = docPath
            self.url = url
            self.placeHash = placeHash
            self.title = title
            self.body = body
            self.confidence = confidence
            self.sourceMeta = sourceMeta
            self.interestEvent = interestEvent
            self.interestScale = interestScale
        }
    }

    /// Ingest a draft end-to-end. Returns the rowid assigned by SQLite, or
    /// nil if the item was deduped (screen-frame content_hash collision).
    @discardableResult
    public func ingest(_ draft: Draft) async -> Int64? {
        let normalized = normalize(draft.body)
        guard !normalized.isEmpty || (draft.title?.isEmpty == false) else { return nil }

        let hash = Self.hash64(of: normalized.isEmpty ? (draft.title ?? "") : normalized)

        let item = IndexedItem(
            kind: draft.kind,
            timestamp: draft.timestamp,
            sessionID: draft.sessionID,
            appBundleID: draft.appBundleID,
            docPath: draft.docPath,
            url: draft.url,
            placeHash: draft.placeHash,
            title: draft.title,
            body: normalized,
            confidence: draft.confidence,
            contentHash: hash,
            sourceMeta: draft.sourceMeta
        )

        guard let rowid = index.insert(item) else { return nil }

        // Entities → index link table + interest graph potentiation.
        if let extractor = extractor {
            let textForEntities = (draft.title.map { $0 + "\n" } ?? "") + normalized
            let entities = await extractor.extract(textForEntities)
            for entity in entities {
                index.linkEntity(
                    rowid: rowid,
                    canonical: entity.canonicalName,
                    entityTypeRaw: entity.type.stableRaw,
                    weight: entity.confidence
                )
            }
            if let interestGraph, !entities.isEmpty {
                await interestGraph.potentiate(
                    entities: entities,
                    event: draft.interestEvent,
                    coOccurringWith: [],
                    scale: draft.interestScale
                )
            }
        }

        // Embedding — best effort. Skipped silently if no model is available
        // or the body is too short.
        if let embed = embed, normalized.utf8.count >= 64 {
            let textForVec = (draft.title.map { $0 + "\n" } ?? "") + normalized
            if let vector = await embed.embed(textForVec) {
                index.upsertEmbedding(rowid: rowid, vector: vector)
            }
        }

        // Activity stream receipt.
        if let stream = activityStream {
            await stream.emit(receipt(for: draft, normalized: normalized))
        }

        return rowid
    }

    // MARK: - Helpers

    private func receipt(for draft: Draft, normalized: String) -> ActivityEvent {
        let now = draft.timestamp
        let bytes = normalized.utf8.count
        switch draft.kind {
        case .screen:
            return .screenFrameIngested(bundleID: draft.appBundleID ?? "unknown", bodyBytes: bytes, at: now)
        case .file:
            return .fileIndexed(pathHash: Self.shortHashHex(draft.docPath ?? ""), bytes: bytes, at: now)
        case .clip:
            let kind = Self.inferClipKind(meta: draft.sourceMeta)
            return .clipIndexed(kind: kind, bytes: bytes, at: now)
        case .browser:
            let host = Self.extractHost(draft.url) ?? "unknown"
            return .browserPageIndexed(host: host, bytes: bytes, at: now)
        case .message:
            let sender = draft.sourceMeta?["senderHash"] ?? "unknown"
            return .messageIndexed(senderHash: sender, at: now)
        case .email:
            let from = draft.sourceMeta?["fromHash"] ?? "unknown"
            let subject = draft.title?.utf8.count ?? 0
            return .mailIndexed(fromHash: from, subjectBytes: subject, at: now)
        case .calendar:
            return .calendarIndexed(at: now)
        case .agentTurn:
            let kindStr = draft.sourceMeta?["turnKind"] ?? "user"
            return .agentTurnIndexed(turnKind: kindStr, at: now)
        }
    }

    private func normalize(_ raw: String) -> String {
        // Strip control chars, collapse runs of whitespace-only to single
        // spaces, trim.
        let scalars = raw.unicodeScalars.filter { s in
            !(s.value < 0x20 && s != "\n" && s != "\t")
        }
        var out = String(String.UnicodeScalarView(scalars))
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Hashing

    static func hash64(of s: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(s.utf8))
        var h: UInt64 = 0
        digest.withUnsafeBytes { raw in
            for i in 0..<8 {
                h |= UInt64(raw[i]) << UInt64(i * 8)
            }
        }
        return h
    }

    static func shortHashHex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func extractHost(_ url: String?) -> String? {
        guard let url, let u = URL(string: url) else { return nil }
        return u.host?.lowercased()
    }

    static func inferClipKind(meta: [String: String]?) -> ClipboardKind {
        guard let m = meta, let raw = m["clipboardKind"]?.lowercased() else { return .text }
        return ClipboardKind(rawValue: raw) ?? .text
    }
}

// MARK: - EntityType hash stability

// `EntityType.hashValue` is not stable across runs. Map each case to an
// explicit integer so `entity_type` in the DB column means something.
extension EntityType {
    var stableRaw: Int {
        switch self {
        case .person:  return 1
        case .org:     return 2
        case .place:   return 3
        case .ticker:  return 4
        case .topic:   return 5
        case .url:     return 6
        case .paper:   return 7
        case .repo:    return 8
        }
    }
}
