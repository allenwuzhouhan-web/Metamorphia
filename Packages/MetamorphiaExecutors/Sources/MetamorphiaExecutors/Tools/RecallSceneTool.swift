import Foundation
import MetamorphiaAgentKit

/// Single entry-point for "find something" queries — scenes, files,
/// screens, browser pages, agent turns. Performs ONE broad search of
/// the temporal-recall index per query (cached for a short window so
/// rephrasings hit the cache instead of paying the search cost again),
/// and when the broad search returns no scenes, automatically falls
/// through to the indexed filesystem (Spotlight) so the user always
/// gets *something* back.
///
/// The fallback is intent-aware: a query for a "research paper" is
/// constrained to PDFs; a request for "slides" is constrained to
/// keynote/pptx; a code file query is constrained to source extensions.
/// This is what stops the agent from returning a PowerPoint when the
/// user asked for a paper.
///
/// The tool depends on the app having called `RetraceSurface.shared.start()`
/// at launch. When the surface isn't configured yet, the fallback path
/// alone is used — the user still gets indexed-file results.
public struct RecallSceneTool: ToolDefinition {
    public let name = "recall_scene"
    public let description = """
    Find something the user has touched — a file, a scene, a screen, a \
    page, an agent turn — anywhere in their Retrace timeline. This is \
    the single search call to make: it runs ONE broad sweep across all \
    sources, and if nothing surfaces it falls back automatically to the \
    indexed filesystem (Spotlight) so a result is always returned. Pass \
    `doc_type` (paper, document, presentation, spreadsheet, image, video, \
    audio, code, archive, text) to constrain results to that kind — the \
    tool will infer it from the query when omitted. Do NOT call this \
    tool repeatedly with reworded prompts: the first call is broad, and \
    repeats within the same turn return the cached result with a hint \
    to widen the topic instead.
    """

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Natural-language recall query, e.g. 'that ESL hw yesterday night' or 'the paper I wrote on attention'."),
            "max_scenes": JSONSchema.integer(description: "Max scenes to return (default 3).", minimum: 1, maximum: 10),
            "doc_type": JSONSchema.enumString(
                description: "Optional document-type filter. Omit to let the tool infer from the query.",
                values: ["paper", "document", "presentation", "spreadsheet", "image", "video", "audio", "code", "archive", "text", "any"]
            ),
        ], required: ["query"])
    }

    /// Pluggable scene search — the app target sets this during bootstrap
    /// to reach `RetraceSurface.shared.search(_:)`. Keeps the Executors
    /// package free of `AppKit` / main-actor entanglement.
    public static var search: (@Sendable (_ query: String) async -> RecallResult?)?

    public init() {}

    public struct RecallResult: Sendable, Codable {
        public let scenes: [Scene]
        public let window: WindowSummary?
        public let autoNarrowed: Bool

        public init(scenes: [Scene], window: WindowSummary?, autoNarrowed: Bool) {
            self.scenes = scenes
            self.window = window
            self.autoNarrowed = autoNarrowed
        }

        public struct Scene: Sendable, Codable {
            public let heroTitle: String
            public let heroKind: String
            public let heroTimestamp: Date
            public let heroSnippet: String
            public let heroPath: String?
            public let heroURL: String?
            public let chipEntities: [String]
            public let siblingCount: Int
            public let anchorReason: String?

            public init(heroTitle: String, heroKind: String, heroTimestamp: Date, heroSnippet: String, heroPath: String?, heroURL: String?, chipEntities: [String], siblingCount: Int, anchorReason: String?) {
                self.heroTitle = heroTitle
                self.heroKind = heroKind
                self.heroTimestamp = heroTimestamp
                self.heroSnippet = heroSnippet
                self.heroPath = heroPath
                self.heroURL = heroURL
                self.chipEntities = chipEntities
                self.siblingCount = siblingCount
                self.anchorReason = anchorReason
            }
        }

        public struct WindowSummary: Sendable, Codable {
            public let start: Date
            public let end: Date
            public let reason: String
            public init(start: Date, end: Date, reason: String) {
                self.start = start; self.end = end; self.reason = reason
            }
        }
    }

    // MARK: - Per-process cache
    //
    // Keyed by normalized query so trivial rephrasings hit the cache.
    // 60-second TTL — long enough to absorb a rapid second tool call
    // inside the same agent turn, short enough that it never serves a
    // result staler than the user's perception of "now".

    private actor Cache {
        struct Entry {
            let result: String
            let timestamp: Date
        }
        var entries: [String: Entry] = [:]

        func get(_ key: String, maxAge: TimeInterval) -> String? {
            guard let entry = entries[key],
                  Date().timeIntervalSince(entry.timestamp) < maxAge
            else { return nil }
            return entry.result
        }

        func put(_ key: String, _ value: String, ttl: TimeInterval) {
            // Sweep entries past the TTL before inserting so the cache is
            // bounded to the working set within one TTL window instead of
            // accumulating one stale entry per distinct query forever.
            let now = Date()
            entries = entries.filter { now.timeIntervalSince($0.value.timestamp) < ttl }
            entries[key] = Entry(result: value, timestamp: now)
        }
    }

    private static let cache = Cache()
    private static let cacheTTL: TimeInterval = 60

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let maxScenes = optionalInt("max_scenes", from: args) ?? 3

        let intent: DocTypeIntent = {
            if let raw = optionalString("doc_type", from: args)?.lowercased(),
               let parsed = DocTypeIntent(rawValue: raw) {
                return parsed
            }
            return DocTypeIntent.infer(from: query)
        }()

        let cacheKey = normalize(query: query) + "|" + intent.rawValue + "|" + String(maxScenes)
        if let cached = await Self.cache.get(cacheKey, maxAge: Self.cacheTTL) {
            return cached
        }

        // 1. Broad scene search. If the surface isn't bootstrapped yet
        //    we skip this and head straight to the file fallback so the
        //    user still gets indexed-file matches.
        var scenes: [RecallResult.Scene] = []
        var window: RecallResult.WindowSummary?
        var autoNarrowed = false

        if let search = Self.search, let result = await search(query) {
            scenes = Array(result.scenes.prefix(maxScenes))
            window = result.window
            autoNarrowed = result.autoNarrowed

            if intent != .any {
                scenes = filter(scenes, byIntent: intent)
            }
        }

        // 2. Indexed-file fallback. Always runs when the scene search
        //    returned nothing — the user asked for *something* and the
        //    contract is that this tool always tries to deliver a result.
        let fileHits: [IndexedFileSearch.Hit]
        if scenes.isEmpty {
            fileHits = await IndexedFileSearch.search(
                query: query,
                intent: intent,
                directory: nil,
                maxResults: max(maxScenes, 5)
            )
        } else {
            fileHits = []
        }

        let payload = encode(
            query: query,
            intent: intent,
            scenes: scenes,
            window: window,
            autoNarrowed: autoNarrowed,
            fallbackFiles: fileHits
        )

        await Self.cache.put(cacheKey, payload, ttl: Self.cacheTTL)
        return payload
    }

    // MARK: - Encoding

    private func encode(
        query: String,
        intent: DocTypeIntent,
        scenes: [RecallResult.Scene],
        window: RecallResult.WindowSummary?,
        autoNarrowed: Bool,
        fallbackFiles: [IndexedFileSearch.Hit]
    ) -> String {
        let formatter = ISO8601DateFormatter()

        let sceneArray: [[String: Any]] = scenes.map { scene in
            var dict: [String: Any] = [
                "heroTitle":      scene.heroTitle,
                "heroKind":       scene.heroKind,
                "heroTimestamp":  formatter.string(from: scene.heroTimestamp),
                "heroSnippet":    scene.heroSnippet,
                "chipEntities":   scene.chipEntities,
                "siblingCount":   scene.siblingCount,
            ]
            if let p = scene.heroPath { dict["heroPath"] = p }
            if let u = scene.heroURL  { dict["heroURL"]  = u }
            if let r = scene.anchorReason { dict["anchorReason"] = r }
            return dict
        }

        let fileArray: [[String: Any]] = fallbackFiles.map { hit in
            var dict: [String: Any] = [
                "path":      hit.path,
                "extension": hit.extension,
            ]
            if let m = hit.modifiedAt { dict["modifiedAt"] = formatter.string(from: m) }
            if let s = hit.size       { dict["sizeBytes"]  = s }
            return dict
        }

        var payload: [String: Any] = [
            "query":     query,
            "doc_type":  intent.rawValue,
            "scenes":    sceneArray,
            "files":     fileArray,
        ]

        if let w = window {
            payload["window"] = [
                "start":  formatter.string(from: w.start),
                "end":    formatter.string(from: w.end),
                "reason": w.reason,
            ] as [String: Any]
        }
        payload["autoNarrowed"] = autoNarrowed

        if scenes.isEmpty && fallbackFiles.isEmpty {
            payload["status"] = "empty"
            payload["note"] = "Broad memory search returned nothing and Spotlight/find found no \(intent == .any ? "matching" : intent.rawValue) files. Widen the topic or relax the doc_type filter — do not retry with a rewording."
        } else if scenes.isEmpty {
            payload["status"] = "fallback"
            payload["note"] = "No timeline scenes matched. Returning indexed filesystem hits filtered by doc_type=\(intent.rawValue)."
        } else {
            payload["status"] = "ok"
        }

        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Filtering

    /// Drop scenes whose hero is a file with an extension that doesn't
    /// match the intent. We only filter file-kind scenes — a screen or
    /// browser hit on the right topic is still useful even when the
    /// asked-for kind is "paper", because the user may have read the
    /// paper in the browser.
    private func filter(_ scenes: [RecallResult.Scene], byIntent intent: DocTypeIntent) -> [RecallResult.Scene] {
        let allowed = Set(intent.extensions)
        guard !allowed.isEmpty else { return scenes }
        return scenes.filter { scene in
            guard scene.heroKind == "file", let path = scene.heroPath else {
                return true
            }
            let ext = (path as NSString).pathExtension.lowercased()
            return allowed.contains(ext)
        }
    }

    // MARK: - Normalisation

    private func normalize(query: String) -> String {
        let lower = query.lowercased()
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.sorted().joined(separator: " ")
    }
}
