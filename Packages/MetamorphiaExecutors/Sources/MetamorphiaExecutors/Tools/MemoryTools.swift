import Foundation
import MetamorphiaAgentKit

// MARK: - StoreMemoryTool

/// Persists a keyed fact to the long-term memory store so it can be recalled
/// in future sessions.
///
/// The LLM should call this when the user explicitly asks to remember something,
/// or when a high-value fact emerges mid-conversation that is unlikely to be
/// rediscovered from context alone (e.g., a thesis, an ongoing thread, or a
/// named entity the user keeps referencing).
public struct StoreMemoryTool: ToolDefinition {
    public let name = "store_memory"
    public let description = """
    Persist a keyed fact to long-term memory. Use when the user asks you to \
    remember something, or when a valuable fact (thesis, preference, entity, \
    ongoing thread) should survive beyond the current session. \
    Recalled in future turns via recall_memory.
    """

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "key": JSONSchema.string(
                description: "A short, stable identifier for this memory (e.g., \"aapl_thesis\", \"user_preferred_lang\"). Used as a lookup hint in recall."
            ),
            "value": JSONSchema.string(
                description: "The content to persist. Be concise but complete — this is exactly what recall_memory will return."
            ),
            "category": JSONSchema.enumString(
                description: "Memory category that controls decay rate and eviction behavior. Defaults to \"fact\".",
                values: [
                    "preference",
                    "correction",
                    "fact",
                    "skill",
                    "note",
                    "interest",
                    "thesis",
                    "thread",
                    "entity",
                ]
            ),
            "keywords": JSONSchema.array(
                items: ["type": "string"],
                description: "Optional list of lowercase keywords that improve recall precision (e.g., [\"aapl\", \"services\", \"revenue\"])."
            ),
        ], required: ["key", "value"])
    }

    private let store: any MemoryStore

    public init(store: any MemoryStore) {
        self.store = store
    }

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let key   = try requiredString("key",   from: args)
        let value = try requiredString("value", from: args)

        let category: MemoryCategory
        if let raw = optionalString("category", from: args) {
            guard let parsed = MemoryCategory(rawValue: raw) else {
                return errorResponse("Unknown category \"\(raw)\". Valid values: preference, correction, fact, skill, note, interest, thesis, thread, entity.")
            }
            category = parsed
        } else {
            category = .fact
        }

        // Merge the explicit key into keywords so recall_memory can find it by
        // name even if the query doesn't include the stored value.
        var keywords: [String] = []
        if let s = args["keywords"] as? [String] {
            keywords = s
        } else if let a = args["keywords"] as? [Any] {
            keywords = a.compactMap { $0 as? String }
        }
        let keyTokens = key.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 2 }
        for tok in keyTokens where !keywords.contains(tok) {
            keywords.append(tok)
        }

        store.add(MemoryInput(
            content: "[\(key)] \(value)",
            category: category,
            keywords: keywords
        ))

        return successResponse(key: key, category: category.rawValue)
    }

    // MARK: - Private helpers

    private func successResponse(key: String, category: String) -> String {
        let payload: [String: String] = [
            "status":   "stored",
            "key":      key,
            "category": category,
        ]
        return encodePayload(payload)
    }

    private func errorResponse(_ message: String) -> String {
        let payload: [String: String] = ["error": message]
        return encodePayload(payload)
    }

    private func encodePayload(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "{\"error\":\"serialization failure\"}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - RecallMemoryTool

/// Retrieves memories that match a query, applying synaptic LTP on hits so
/// frequently recalled memories stay strong.
///
/// Always call this at the start of a turn when continuing a thread the user
/// cares about (e.g., before answering questions about a stock the user follows,
/// a thesis they have shared, or an entity they keep referencing).
public struct RecallMemoryTool: ToolDefinition {
    public let name = "recall_memory"
    public let description = """
    Retrieve stored facts (theses, preferences, entities, ongoing threads) the \
    user has explicitly asked to remember. NOT for finding files, scenes, \
    screens, browser pages, or past activity — use `recall_scene` for those. \
    Call this at most ONCE per turn, with a single broad query; the recall \
    spans every category. Reinforces recalled records via synaptic LTP.
    """

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(
                description: "Natural-language or keyword query (e.g., \"AAPL thesis\", \"preferred editor\", \"OpenAI thread\")."
            ),
            "category": JSONSchema.enumString(
                description: "Restrict results to one category. Omit to search across all categories (runs separate recalls per category and merges by score).",
                values: [
                    "preference",
                    "correction",
                    "fact",
                    "skill",
                    "note",
                    "interest",
                    "thesis",
                    "thread",
                    "entity",
                ]
            ),
            "limit": JSONSchema.integer(
                description: "Maximum number of records to return. Defaults to 5.",
                minimum: 1,
                maximum: 20
            ),
        ], required: ["query"])
    }

    private let store: any MemoryStore

    public init(store: any MemoryStore) {
        self.store = store
    }

    public func execute(arguments: String) async throws -> String {
        let args  = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let limit = optionalInt("limit", from: args) ?? 5

        let targetCategory: MemoryCategory?
        if let raw = optionalString("category", from: args) {
            guard let parsed = MemoryCategory(rawValue: raw) else {
                return errorResponse("Unknown category \"\(raw)\". Valid values: preference, correction, fact, skill, note, interest, thesis, thread, entity.")
            }
            targetCategory = parsed
        } else {
            targetCategory = nil
        }

        let records: [MemoryRecord]
        if let cat = targetCategory {
            records = store.recall(query: query, category: cat, limit: limit)
        } else {
            // No category filter — search all categories and merge by timestamp.
            let allCategories: [MemoryCategory] = [
                .preference, .correction, .fact, .skill, .note,
                .interest, .thesis, .thread, .entity,
            ]
            // Allocate `limit` slots across all categories, then take the top
            // `limit` by timestamp descending. Using `limit` per-category is
            // intentionally generous — the LLM asked for broad recall.
            var merged: [MemoryRecord] = []
            for cat in allCategories {
                let hits = store.recall(query: query, category: cat, limit: limit)
                merged.append(contentsOf: hits)
            }
            records = Array(
                merged
                    .sorted { $0.timestamp > $1.timestamp }
                    .prefix(limit)
            )
        }

        return encodeRecords(records, query: query)
    }

    // MARK: - Private helpers

    private func encodeRecords(_ records: [MemoryRecord], query: String) -> String {
        if records.isEmpty {
            let payload: [String: Any] = [
                "query":   query,
                "count":   0,
                "records": [] as [Any],
            ]
            return encodePayload(payload)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]

        let items = records.map { rec -> [String: Any] in
            [
                "id":        rec.id.uuidString,
                "content":   rec.content,
                "category":  rec.category.rawValue,
                "keywords":  rec.keywords,
                "timestamp": ISO8601DateFormatter().string(from: rec.timestamp),
            ]
        }
        let payload: [String: Any] = [
            "query":   query,
            "count":   records.count,
            "records": items,
        ]
        return encodePayload(payload)
    }

    private func errorResponse(_ message: String) -> String {
        let payload: [String: Any] = ["error": message]
        return encodePayload(payload)
    }

    private func encodePayload(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "{\"error\":\"serialization failure\"}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
