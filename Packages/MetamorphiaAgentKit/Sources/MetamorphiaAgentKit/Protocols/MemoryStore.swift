import Foundation

/// A sync persistence layer for durable memories that outlive a single agent session.
///
/// Replaces Executer's `MemoryManager.shared.add(...)` / `recall(...)`.
/// The app target supplies a concrete implementation (file-backed, LearningDatabase,
/// CoreData, etc.); middleware in the package see only this protocol.
///
/// Kept sync because middleware hooks (`beforeModelCall`, `afterModelCall`,
/// `afterToolExecution`) are sync. Concrete implementations that need async I/O
/// should cache/queue internally.
public protocol MemoryStore: AnyObject, Sendable {
    /// Persist a new memory record.
    func add(_ input: MemoryInput)

    /// Recall recent memories matching a query, filtered to a single category.
    /// `limit` caps the number of records returned (most recent first).
    func recall(query: String, category: MemoryCategory, limit: Int) -> [MemoryRecord]
}

/// Categories used by the agent loop. The app target may extend this list
/// by adding its own `rawValue` strings if it stores additional types — the
/// memory store just round-trips the raw string.
public enum MemoryCategory: String, Sendable, Codable {
    case preference
    case correction
    case fact
    case skill
    case note

    // Continuum categories — Phases 0+
    /// A recurring interest the user has shown (e.g., a topic or company they
    /// ask about repeatedly). Tau: 21 days.
    case interest
    /// A belief or thesis the user holds about a subject (e.g., "AAPL services
    /// growth thesis"). Tau: 14 days.
    case thesis
    /// An ongoing narrative thread the user is tracking (e.g., an unfolding
    /// news story). Tau: 7 days.
    case thread
    /// A named entity (person, org, ticker, place) that the user cares about.
    /// Tau: 30 days. Floor weight of 0.05 prevents full eviction.
    case entity
}

/// Input for a new memory record — what to persist.
public struct MemoryInput: Sendable {
    public let content: String
    public let category: MemoryCategory
    public let keywords: [String]

    public init(content: String, category: MemoryCategory, keywords: [String]) {
        self.content = content
        self.category = category
        self.keywords = keywords
    }
}

/// A persisted memory record returned by `recall(...)`.
public struct MemoryRecord: Sendable, Identifiable {
    public let id: UUID
    public let content: String
    public let category: MemoryCategory
    public let keywords: [String]
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        content: String,
        category: MemoryCategory,
        keywords: [String],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.keywords = keywords
        self.timestamp = timestamp
    }
}

/// A no-op store used in tests and in contexts where memory persistence
/// is disabled (e.g., privacy-sensitive sessions).
public final class NullMemoryStore: MemoryStore, @unchecked Sendable {
    public init() {}
    public func add(_ input: MemoryInput) {}
    public func recall(query: String, category: MemoryCategory, limit: Int) -> [MemoryRecord] { [] }
}

/// An in-memory store suitable for tests and short-lived sessions.
/// Thread-safe via a single lock.
public final class InMemoryMemoryStore: MemoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [MemoryRecord] = []
    /// Upper bound on retained records — mirrors `FileMemoryStore`'s `maxRecords`
    /// so an unbounded `add()` loop can't exhaust memory. Records are appended in
    /// chronological order, so dropping from the front evicts the oldest first.
    private let maxRecords: Int

    public init(maxRecords: Int = 2_000) {
        self.maxRecords = maxRecords
    }

    public func add(_ input: MemoryInput) {
        lock.lock(); defer { lock.unlock() }
        records.append(MemoryRecord(
            content: input.content,
            category: input.category,
            keywords: input.keywords
        ))
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
    }

    public func recall(query: String, category: MemoryCategory, limit: Int) -> [MemoryRecord] {
        lock.lock(); defer { lock.unlock() }
        let filtered = records.filter { $0.category == category }
        let ordered = filtered.sorted(by: { $0.timestamp > $1.timestamp })
        guard !query.isEmpty else {
            return Array(ordered.prefix(limit))
        }
        // Token-level match: return records where any query token appears in the
        // content (substring) or overlaps with any stored keyword. Callers may
        // apply stricter filtering on top — we lean inclusive by design so a
        // memory tagged `["browser","safari"]` still surfaces for a query "open a browser".
        let queryTokens = Set(
            query.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
        guard !queryTokens.isEmpty else {
            return Array(ordered.prefix(limit))
        }
        let matched = ordered.filter { rec in
            let recKeywords = Set(rec.keywords.map { $0.lowercased() })
            if !recKeywords.intersection(queryTokens).isEmpty { return true }
            let lowerContent = rec.content.lowercased()
            return queryTokens.contains(where: { lowerContent.contains($0) })
        }
        return Array(matched.prefix(limit))
    }

    /// Test helper: number of records currently stored.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }
}
