import Foundation

/// One named, pre-built pattern in the library — the unit users search, stack, and
/// apply. `slug` is a single lowercase token so a stack reads like `/preposition + /verb`.
struct RegexPattern: Identifiable, Hashable {
    let slug: String
    let name: String
    let topic: String
    let subtopic: String
    let keywords: [String]
    let pattern: String
    let caseInsensitive: Bool
    let detail: String

    var id: String { slug }
}

/// The pattern catalog plus lookup, ranked search, and a compiled-regex cache. The
/// catalog is a small static array (a few KB of strings), so keeping it resident costs
/// effectively nothing, and every regex is compiled at most once.
enum RegexPatternLibrary {
    /// Preferred topic order; anything else falls in afterwards alphabetically.
    private static let topicOrder = ["Parts of Speech", "Sentence Structure", "Entities", "Writing"]

    /// All patterns (defined in `RegexPatternCatalog.swift`).
    static let all: [RegexPattern] = RegexPatternCatalog.patterns

    private static let bySlug: [String: RegexPattern] = Dictionary(
        all.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a }
    )

    static func pattern(slug: String) -> RegexPattern? { bySlug[slug] }

    static var topics: [String] {
        let present = Set(all.map(\.topic))
        return topicOrder.filter(present.contains) + present.subtracting(topicOrder).sorted()
    }

    static func subtopics(in topic: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for pattern in all where pattern.topic == topic {
            if seen.insert(pattern.subtopic).inserted { ordered.append(pattern.subtopic) }
        }
        return ordered
    }

    static func patterns(topic: String, subtopic: String) -> [RegexPattern] {
        all.filter { $0.topic == topic && $0.subtopic == subtopic }
    }

    /// Rank patterns by how directly they answer the query (exact slug/name first,
    /// then prefixes, then keyword/topic/description hits).
    static func search(_ query: String) -> [RegexPattern] {
        let q = query.trimmingCharacters(in: CharacterSet(charactersIn: " /")).lowercased()
        guard !q.isEmpty else { return [] }
        func score(_ p: RegexPattern) -> Int {
            let name = p.name.lowercased()
            if p.slug == q || name == q { return 0 }
            if p.slug.hasPrefix(q) || name.hasPrefix(q) { return 1 }
            if name.contains(q) || p.slug.contains(q) { return 2 }
            if p.keywords.contains(where: { $0.lowercased().contains(q) }) { return 3 }
            if p.subtopic.lowercased().contains(q) || p.topic.lowercased().contains(q) { return 4 }
            if p.detail.lowercased().contains(q) { return 5 }
            return Int.max
        }
        var scored: [(pattern: RegexPattern, rank: Int)] = []
        for pattern in all {
            let rank = score(pattern)
            if rank != Int.max { scored.append((pattern, rank)) }
        }
        scored.sort { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.pattern.name < rhs.pattern.name
        }
        return scored.map(\.pattern)
    }

    // MARK: Compiled regex (compile each pattern at most once)

    private static var cache: [String: NSRegularExpression] = [:]
    /// Guards `cache` so matching can be driven off the main thread (see
    /// RegexScratchpadView's debounced background pass) without racing the
    /// main-actor reads that still build the row counts.
    private static let cacheLock = NSLock()

    static func regex(for pattern: RegexPattern) -> NSRegularExpression? {
        cacheLock.lock()
        if let cached = cache[pattern.slug] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let options: NSRegularExpression.Options = pattern.caseInsensitive ? [.caseInsensitive] : []
        guard let compiled = try? NSRegularExpression(pattern: pattern.pattern, options: options) else { return nil }
        cacheLock.lock()
        cache[pattern.slug] = compiled
        cacheLock.unlock()
        return compiled
    }

    /// Basic-mode literal matcher: the query escaped, optionally whole-word.
    static func literalRegex(_ query: String, wholeWord: Bool, caseInsensitive: Bool) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: query)
        let body = wholeWord ? "\\b\(escaped)\\b" : escaped
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        return try? NSRegularExpression(pattern: body, options: options)
    }

    /// Count matches of a pattern in `text` (for live per-row counts). Cheap; safe on bad input.
    static func count(of pattern: RegexPattern, in text: String) -> Int {
        guard let regex = regex(for: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
