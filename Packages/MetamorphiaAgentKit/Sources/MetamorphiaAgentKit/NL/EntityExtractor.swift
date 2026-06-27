import Foundation
import NaturalLanguage

// MARK: - Public types

public enum EntityType: String, Codable, Sendable {
    case person, org, ticker, topic, place, url, paper, repo
}

public struct ExtractedEntity: Codable, Sendable, Hashable {
    public let canonicalName: String
    public let type: EntityType
    public let surfaceForm: String
    public let confidence: Double

    public init(canonicalName: String, type: EntityType, surfaceForm: String, confidence: Double) {
        self.canonicalName = canonicalName
        self.type = type
        self.surfaceForm = surfaceForm
        self.confidence = confidence
    }
}

// MARK: - EntityExtractor

/// On-device entity extraction using `NaturalLanguage.NLTagger` plus regex
/// supplements. No LLM calls. Latency budget: < 30ms per 100-token turn.
///
/// Thread-safety: struct value type with actor-isolated dependencies accessed
/// only inside `extract(_:)`. All `NLTagger` usage is scoped to each call —
/// NLTagger is not thread-safe but we construct new instances per call, which
/// is fine because this method is expected to complete in < 5ms for typical
/// inputs.
public struct EntityExtractor: Sendable {

    private let aliasStore: EntityAliasStore
    private let termFrequency: RollingTermFrequency

    public init(aliasStore: EntityAliasStore, termFrequency: RollingTermFrequency) {
        self.aliasStore = aliasStore
        self.termFrequency = termFrequency
    }

    // Convenience initialiser using the shared defaults.
    public init(aliasStore: EntityAliasStore) {
        self.aliasStore = aliasStore
        self.termFrequency = RollingTermFrequency()
    }

    // MARK: - Extract

    /// Extract entities from `text`. Async — awaits actor calls directly
    /// instead of blocking on a DispatchSemaphore.
    public func extract(_ text: String) async -> [ExtractedEntity] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var raw: [ExtractedEntity] = []

        // 1. NLTagger: named entities (person / org / place)
        raw.append(contentsOf: extractNamedEntities(from: text))

        // 2. Regex: tickers  $AAPL
        raw.append(contentsOf: extractTickers(from: text))

        // 3. NSDataDetector: URLs
        raw.append(contentsOf: extractURLs(from: text))

        // 4. Regex: DOIs
        raw.append(contentsOf: extractDOIs(from: text))

        // 5. Regex: GitHub repos
        raw.append(contentsOf: extractRepos(from: text))

        // 6. Regex: ISBNs
        raw.append(contentsOf: extractISBNs(from: text))

        // 7. NLTagger lexical: topic nouns + bigrams (async)
        let topics = await extractTopics(from: text)
        raw.append(contentsOf: topics)

        // 8. Canonicalize + dedupe (async)
        return await canonicalizeAndDedupe(raw)
    }

    // MARK: - Named entity extraction (NLTagger .nameType)

    private func extractNamedEntities(from text: String) -> [ExtractedEntity] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var results: [ExtractedEntity] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag else { return true }
            let surface = String(text[range])
            let type: EntityType
            switch tag {
            case .personalName:  type = .person
            case .organizationName: type = .org
            case .placeName: type = .place
            default: return true
            }
            results.append(ExtractedEntity(
                canonicalName: surface,
                type: type,
                surfaceForm: surface,
                confidence: 0.9
            ))
            return true
        }
        return results
    }

    // MARK: - Ticker regex  $[A-Z]{1,5}

    private static let tickerPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\$([A-Z]{1,5})\b"#)
    }()

    private func extractTickers(from text: String) -> [ExtractedEntity] {
        let nsText = text as NSString
        let matches = Self.tickerPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match -> ExtractedEntity? in
            guard match.numberOfRanges > 1 else { return nil }
            let tickerRange = match.range(at: 1)
            guard tickerRange.location != NSNotFound else { return nil }
            let surface = nsText.substring(with: tickerRange)
            return ExtractedEntity(
                canonicalName: surface.uppercased(),
                type: .ticker,
                surfaceForm: "$\(surface)",
                confidence: 0.95
            )
        }
    }

    // MARK: - URL extraction via NSDataDetector

    private static let linkDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private func extractURLs(from text: String) -> [ExtractedEntity] {
        guard let detector = Self.linkDetector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        return matches.compactMap { match -> ExtractedEntity? in
            guard let url = match.url, let host = url.host else { return nil }
            // Strip leading "www."
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard !cleanHost.isEmpty else { return nil }
            let surface = url.absoluteString
            return ExtractedEntity(
                canonicalName: cleanHost,
                type: .url,
                surfaceForm: surface,
                confidence: 0.9
            )
        }
    }

    // MARK: - DOI regex  10.XXXX/...

    private static let doiPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"10\.\d{4,9}/[-._;()\/:A-Z0-9]+"#,
            options: .caseInsensitive
        )
    }()

    private func extractDOIs(from text: String) -> [ExtractedEntity] {
        let nsText = text as NSString
        let matches = Self.doiPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.map { match in
            let surface = nsText.substring(with: match.range)
            return ExtractedEntity(
                canonicalName: surface.lowercased(),
                type: .paper,
                surfaceForm: surface,
                confidence: 0.95
            )
        }
    }

    // MARK: - GitHub repo regex

    private static let repoPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"github\.com/([\w.-]+/[\w.-]+)"#,
            options: .caseInsensitive
        )
    }()

    private func extractRepos(from text: String) -> [ExtractedEntity] {
        let nsText = text as NSString
        let matches = Self.repoPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match -> ExtractedEntity? in
            guard match.numberOfRanges > 1 else { return nil }
            let pathRange = match.range(at: 1)
            guard pathRange.location != NSNotFound else { return nil }
            let surface = nsText.substring(with: match.range(at: 0))
            let canonical = nsText.substring(with: pathRange).lowercased()
            return ExtractedEntity(
                canonicalName: canonical,
                type: .repo,
                surfaceForm: surface,
                confidence: 0.9
            )
        }
    }

    // MARK: - ISBN regex (ISBN-10 and ISBN-13)

    // ISBN-13: 978- or 979- prefix, then groups of digits/hyphens totalling 13 digits.
    // ISBN-10: 10 digits (last may be X).
    // We keep it simple — match common printed forms.
    private static let isbnPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bISBN[-: ]*(97[89][-\s]?[\d][-\s]?[\d]{1,5}[-\s]?[\d]{1,7}[-\s]?[\d]{1,6}[-\s]?[\dX]|\b[\d][-\s]?[\d]{1,5}[-\s]?[\d]{1,7}[-\s]?[\dX]\b)"#,
            options: .caseInsensitive
        )
    }()

    private func extractISBNs(from text: String) -> [ExtractedEntity] {
        let nsText = text as NSString
        let matches = Self.isbnPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.map { match in
            let surface = nsText.substring(with: match.range)
            let canonical = surface
                .replacingOccurrences(of: "ISBN", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            return ExtractedEntity(
                canonicalName: canonical,
                type: .paper,
                surfaceForm: surface,
                confidence: 0.85
            )
        }
    }

    // MARK: - Topic extraction (lexical-class nouns, TF-IDF unusualness)

    private static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "of", "to", "in", "on", "for", "with", "at", "by", "from", "into",
        "that", "this", "these", "those", "it", "its", "he", "she", "they",
        "them", "their", "we", "our", "us", "you", "your", "me", "my", "i",
        "and", "or", "but", "if", "then", "so", "yet", "nor", "as",
        "have", "has", "had", "do", "does", "did", "will", "would", "shall",
        "should", "may", "might", "must", "can", "could", "need", "dare",
        "what", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "not", "no", "nor", "only", "just", "also", "even", "still",
        "up", "down", "out", "off", "over", "under", "again", "further",
        "than", "then", "there", "here", "both", "each", "more", "most",
        "other", "some", "any", "such", "same", "own", "about", "after",
        "before", "between", "through", "during", "while", "because",
        "like", "very", "too", "all", "well", "back", "go", "make",
        "know", "think", "see", "come", "give", "want", "look", "use",
        "find", "tell", "call", "keep", "let", "begin", "show", "run",
        "play", "move", "live", "set", "put", "turn", "help", "start",
        // Mass nouns that top frequency rankings but carry no topic signal
        "thing", "stuff", "area", "way", "work",
        "time", "year", "people", "man", "woman",
        "child", "world", "life", "hand", "part", "place", "case",
        "week", "company", "system", "lot", "right", "left", "new", "old",
        "first", "last", "long", "great", "little", "big", "high", "small",
        "next", "early", "young", "important", "public", "private", "real",
        "best", "free", "different", "large", "hard", "following",
    ]

    /// Returns true when a token is an initialism / all-caps abbreviation (≥ 2
    /// chars) — these bypass the 4-char length gate. Examples: AI, ML, UI,
    /// SEC, IPO, NLP.
    private static func isInitialism(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        return token == token.uppercased() && token.allSatisfy({ $0.isLetter || $0.isNumber })
    }

    private func extractTopics(from text: String) async -> [ExtractedEntity] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        // --- Pass 1: collect tagged (word, lexicalClass, range) triples ----
        struct TaggedToken {
            let word: String      // original case
            let lower: String     // lowercased
            let tag: NLTag
        }
        var tokens: [TaggedToken] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            guard let tag else { return true }
            let word = String(text[range])
            tokens.append(TaggedToken(word: word, lower: word.lowercased(), tag: tag))
            return true
        }

        // --- Pass 2: unigram nouns with adjusted length gate -----------------
        var termCounts: [String: Int] = [:]

        for token in tokens {
            guard token.tag == .noun else { continue }
            let word = token.lower
            let original = token.word
            // Length gate: initialisms ≥ 2 chars pass; others need ≥ 4.
            if !Self.isInitialism(original) && word.count < 4 { continue }
            if Self.stopwords.contains(word) { continue }
            // Store under the original-case form for initialisms (AI not ai),
            // lowercase for everything else.
            let key = Self.isInitialism(original) ? original : word
            termCounts[key, default: 0] += 1
        }

        // --- Pass 3: bigram candidates (adj+noun, noun+noun) -----------------
        // Guard against fewer than 2 tokens: `tokens.count - 1` underflows to a
        // negative range and traps when punctuation-only input yields 0 tokens.
        if tokens.count >= 2 {
            for i in 0..<(tokens.count - 1) {
                let a = tokens[i]
                let b = tokens[i + 1]

                let aIsAdj = a.tag == .adjective
                let aIsNoun = a.tag == .noun
                let bIsNoun = b.tag == .noun

                guard (aIsAdj || aIsNoun) && bIsNoun else { continue }

                // Compose: use original case for initialisms, lowercase otherwise.
                let aKey = Self.isInitialism(a.word) ? a.word : a.lower
                let bKey = Self.isInitialism(b.word) ? b.word : b.lower

                // Filter trivial bigrams where both words are stopwords.
                guard !Self.stopwords.contains(a.lower) || !Self.stopwords.contains(b.lower) else { continue }

                let bigram = "\(aKey) \(bKey)"
                termCounts[bigram, default: 0] += 1
            }
        }

        guard !termCounts.isEmpty else { return [] }

        // --- Pass 4: async corpus update + scoring ---------------------------
        // Strategy: score each term by unusualness = 1 / (1 + log(freq + 1))
        // where freq is the rolling corpus count. At startup all terms score
        // 1.0 (novel). Self-calibrates over time.

        let allTerms = Array(termCounts.keys)

        // Observe new terms into the corpus (fire-and-forget is fine here;
        // we read frequencies after the observe in the same actor queue).
        await termFrequency.observe(nouns: allTerms)

        var scored: [(term: String, score: Double)] = []
        for term in allTerms {
            let freq = await termFrequency.frequency(of: term)
            let corpusFreq = Double(freq)
            let unusualness = 1.0 / (1.0 + log(corpusFreq + 1.0))
            let count = termCounts[term] ?? 1
            scored.append((term, unusualness * Double(count)))
        }

        scored.sort { $0.score > $1.score }

        return scored.prefix(5).map { item in
            ExtractedEntity(
                canonicalName: item.term.lowercased(),
                type: .topic,
                surfaceForm: item.term,
                confidence: 0.6
            )
        }
    }

    // MARK: - Canonicalization + deduplication

    private func canonicalizeAndDedupe(_ raw: [ExtractedEntity]) async -> [ExtractedEntity] {
        var canonicalized: [ExtractedEntity] = []
        for entity in raw {
            let canonical = await aliasStore.canonicalize(surface: entity.surfaceForm, type: entity.type)
            canonicalized.append(ExtractedEntity(
                canonicalName: canonical,
                type: entity.type,
                surfaceForm: entity.surfaceForm,
                confidence: entity.confidence
            ))
        }

        // Dedupe: collapse same canonicalName + type, keeping highest confidence.
        var seen: [String: ExtractedEntity] = [:]
        for entity in canonicalized {
            let key = "\(entity.type.rawValue):\(entity.canonicalName)"
            if let existing = seen[key] {
                if entity.confidence > existing.confidence {
                    seen[key] = entity
                }
            } else {
                seen[key] = entity
            }
        }
        return Array(seen.values)
    }
}
