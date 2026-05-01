import Foundation

// MARK: - ItemKind

/// The source of an indexed item. Dense integer so it maps directly to the
/// `kind` column in the `items` SQLite table and stays stable across schema
/// migrations. Ordering is load-bearing — do not renumber.
public enum ItemKind: Int, Codable, Sendable, CaseIterable {
    case screen     = 0   // a frame of on-screen text from ScreenHarvest (NO screenshots)
    case file       = 1   // a file on disk indexed by FileHarvest
    case clip       = 2   // a clipboard item
    case browser    = 3   // a browser tab's readable text
    case message    = 4   // a Messages.app row
    case email      = 5   // a Mail.app message
    case calendar   = 6   // a calendar event
    case agentTurn  = 7   // a user query or agent reply from ConversationStore

    public var displaySymbol: String {
        switch self {
        case .screen:    return "rectangle.on.rectangle"
        case .file:      return "doc"
        case .clip:      return "doc.on.clipboard"
        case .browser:   return "safari"
        case .message:   return "message"
        case .email:     return "envelope"
        case .calendar:  return "calendar"
        case .agentTurn: return "bubble.left.and.bubble.right"
        }
    }
}

// MARK: - IndexedItem

/// A single searchable record in Retrace. Every modality (screen frame, file,
/// clipboard item, browser page, message, email, calendar event, agent turn)
/// collapses to this one shape so the query engine can rank across sources.
///
/// `body` may be empty for items where the meaningful content is entirely in
/// the title (short clips, calendar events with no notes). The query engine
/// treats empty-body items as title-only hits.
///
/// The `contentHash` is `xxHash64(canonicalBody)` and is used to dedup
/// consecutive screen frames. For other kinds it is a simple UUID hash —
/// uniqueness on `contentHash` is only enforced for ``ItemKind/screen``.
public struct IndexedItem: Sendable, Hashable {
    public let id: UUID
    public let kind: ItemKind
    public let timestamp: Date
    public let sessionID: UUID?
    public let appBundleID: String?
    public let docPath: String?
    public let url: String?
    public let placeHash: String?
    public let title: String?
    public let body: String
    public let confidence: Double
    public let contentHash: UInt64
    public let sourceMeta: [String: String]?

    public init(
        id: UUID = UUID(),
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
        contentHash: UInt64,
        sourceMeta: [String: String]? = nil
    ) {
        self.id = id
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
        self.contentHash = contentHash
        self.sourceMeta = sourceMeta
    }
}

// MARK: - IndexedEntity

/// An entity extracted from an ``IndexedItem`` body + title.
public struct IndexedEntity: Sendable, Hashable {
    public let canonical: String
    public let entityTypeRaw: Int
    public let weight: Double

    public init(canonical: String, entityTypeRaw: Int, weight: Double = 1.0) {
        self.canonical = canonical
        self.entityTypeRaw = entityTypeRaw
        self.weight = weight
    }
}

// MARK: - SearchHit

/// A result row produced by ``QueryRank`` before scene grouping.
public struct SearchHit: Sendable, Hashable {
    public let item: IndexedItem
    public let rowid: Int64
    public let bm25: Double
    public let cosine: Double
    public let entityScore: Double
    public let finalScore: Double

    public init(item: IndexedItem, rowid: Int64, bm25: Double, cosine: Double, entityScore: Double, finalScore: Double) {
        self.item = item
        self.rowid = rowid
        self.bm25 = bm25
        self.cosine = cosine
        self.entityScore = entityScore
        self.finalScore = finalScore
    }
}

// MARK: - xxHash64

/// xxHash64 — fast non-cryptographic hash used for content deduplication.
///
/// This is a canonical Swift port of Yann Collet's xxHash64 algorithm. It is
/// *not* cryptographic — we use it only to detect "same text twice in a row"
/// for the screen-frame dedup pipeline. Avoids pulling in a C dependency.
public enum XXHash64 {
    private static let prime1: UInt64 = 0x9E3779B185EBCA87
    private static let prime2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let prime3: UInt64 = 0x165667B19E3779F9
    private static let prime4: UInt64 = 0x85EBCA77C2B2AE63
    private static let prime5: UInt64 = 0x27D4EB2F165667C5

    public static func hash(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBytes { raw -> UInt64 in
            let bytes = raw.bindMemory(to: UInt8.self)
            return hash(bytes: bytes.baseAddress, length: raw.count, seed: seed)
        }
    }

    public static func hash(_ string: String, seed: UInt64 = 0) -> UInt64 {
        var s = string
        return s.withUTF8 { buf -> UInt64 in
            hash(bytes: buf.baseAddress, length: buf.count, seed: seed)
        }
    }

    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        return (x &<< r) | (x &>> (64 &- r))
    }

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ (input &* prime2)
        a = rotl(a, 31)
        a = a &* prime1
        return a
    }

    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let v = round(0, val)
        var a = acc ^ v
        a = a &* prime1 &+ prime4
        return a
    }

    private static func hash(bytes: UnsafePointer<UInt8>?, length: Int, seed: UInt64) -> UInt64 {
        guard let base = bytes else { return seed &+ prime5 }
        var p = 0
        var h64: UInt64

        if length >= 32 {
            var v1 = seed &+ prime1 &+ prime2
            var v2 = seed &+ prime2
            var v3 = seed
            var v4 = seed &- prime1

            let limit = length - 32
            while p <= limit {
                v1 = round(v1, readLE64(base, p));       p += 8
                v2 = round(v2, readLE64(base, p));       p += 8
                v3 = round(v3, readLE64(base, p));       p += 8
                v4 = round(v4, readLE64(base, p));       p += 8
            }
            h64 = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h64 = mergeRound(h64, v1)
            h64 = mergeRound(h64, v2)
            h64 = mergeRound(h64, v3)
            h64 = mergeRound(h64, v4)
        } else {
            h64 = seed &+ prime5
        }
        h64 = h64 &+ UInt64(length)

        while p + 8 <= length {
            let k1 = round(0, readLE64(base, p))
            h64 ^= k1
            h64 = rotl(h64, 27) &* prime1 &+ prime4
            p += 8
        }
        if p + 4 <= length {
            h64 ^= UInt64(readLE32(base, p)) &* prime1
            h64 = rotl(h64, 23) &* prime2 &+ prime3
            p += 4
        }
        while p < length {
            h64 ^= UInt64(base[p]) &* prime5
            h64 = rotl(h64, 11) &* prime1
            p += 1
        }

        h64 ^= h64 &>> 33
        h64 = h64 &* prime2
        h64 ^= h64 &>> 29
        h64 = h64 &* prime3
        h64 ^= h64 &>> 32
        return h64
    }

    private static func readLE64(_ p: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
        let ptr = p.advanced(by: offset)
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(ptr[i]) << UInt64(i * 8)
        }
        return result
    }

    private static func readLE32(_ p: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        let ptr = p.advanced(by: offset)
        var result: UInt32 = 0
        for i in 0..<4 {
            result |= UInt32(ptr[i]) << UInt32(i * 8)
        }
        return result
    }
}
