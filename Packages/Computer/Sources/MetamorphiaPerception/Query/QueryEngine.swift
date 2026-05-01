import Foundation
import CoreGraphics

// MARK: - Query Engine (Rank 6)
//
// Takes a parsed `Selector` plus a `ScreenMap` and returns ranked matches.
// Integrates with Rank 1 (filter-first pipeline) and Rank 4 (tier snapshot)
// so downstream callers get the same filtering + stability ranking the rest
// of the encoder paths use.

// MARK: - Query Result

/// One matched element, projected into a compact shape that the selector API
/// can encode as JSON / surface to the LLM. `matchScore` is the product of
/// per-predicate scores — exact predicates contribute 1.0; fuzzy contributes
/// ≤ 1.0. `stabilityScore` mirrors `RefStabilizer.stabilityScore` so the
/// caller can rank by "how likely this ref survives the next capture."
public struct QueryResult: Sendable, Equatable {
    public let ref: ElementRef
    public let role: ElementRole
    public let label: String
    public let click: CGPoint?
    public let bounds: CGRect?
    public let displayIndex: Int
    public let tier: IdentityTier
    public let stabilityScore: Float
    public let matchScore: Float

    public init(
        ref: ElementRef,
        role: ElementRole,
        label: String,
        click: CGPoint?,
        bounds: CGRect?,
        displayIndex: Int,
        tier: IdentityTier,
        stabilityScore: Float,
        matchScore: Float
    ) {
        self.ref = ref
        self.role = role
        self.label = label
        self.click = click
        self.bounds = bounds
        self.displayIndex = displayIndex
        self.tier = tier
        self.stabilityScore = stabilityScore
        self.matchScore = matchScore
    }
}

// MARK: - Query Options

/// Tunables for `QueryEngine.execute`. Defaults are tuned for "LLM wants to
/// pick a button" — `applyFilter = true` + `.permissive` drops the really
/// obvious noise (tiny elements, off-screen) but keeps everything else the
/// user might plausibly be asking about.
public struct QueryOptions: Sendable {
    /// Max matches to return. Post-sort truncation.
    public var maxResults: Int

    /// Run `ElementFilter.apply` before query so dropped elements don't match.
    /// Callers that need to query hidden elements (tests, introspection)
    /// disable this.
    public var applyFilter: Bool

    /// Which filter preset to use when `applyFilter` is true. `.permissive`
    /// keeps more elements; `.aggressive` drops tighter.
    public var filterPolicy: FilterPolicy

    /// How to order results before truncation. Default is `.matchScore` so
    /// the best-matching element lands at index 0.
    public var sortBy: QuerySortOrder

    /// When false, non-interactive elements are dropped after filtering.
    /// Useful when the caller only wants actionable picks.
    public var includeNonInteractive: Bool

    /// Minimum match-score to include. Default `0.3` matches the spec.
    /// Lowered by callers that want fuzzy matches with weak overlap.
    public var minimumScore: Float

    public init(
        maxResults: Int = 50,
        applyFilter: Bool = true,
        filterPolicy: FilterPolicy = .permissive,
        sortBy: QuerySortOrder = .matchScore,
        includeNonInteractive: Bool = true,
        minimumScore: Float = 0.3
    ) {
        self.maxResults = maxResults
        self.applyFilter = applyFilter
        self.filterPolicy = filterPolicy
        self.sortBy = sortBy
        self.includeNonInteractive = includeNonInteractive
        self.minimumScore = minimumScore
    }
}

/// Result ordering.
public enum QuerySortOrder: Sendable {
    /// Highest match-score first (ties broken by stabilityScore then topToBottom).
    case matchScore
    /// Smallest bounds.midY first.
    case topToBottom
    /// Smallest bounds.minX first.
    case leftToRight
    /// Highest stabilityScore first (identifier > label > position > fallback).
    case stabilityScore
}

// MARK: - QueryEngine

public enum QueryEngine {

    // MARK: - Parse + execute

    /// Parse a raw selector string. Thin pass-through to `SelectorParser`.
    public static func parse(_ raw: String) throws -> Selector {
        try SelectorParser.parse(raw)
    }

    /// Convenience: parse + execute in one call. Most callers reach for this.
    public static func query(
        _ raw: String,
        in map: ScreenMap,
        tiers: [ElementRef: IdentityTier],
        options: QueryOptions = QueryOptions()
    ) throws -> [QueryResult] {
        let selector = try parse(raw)
        return execute(selector, in: map, tiers: tiers, options: options)
    }

    /// Run a pre-parsed selector against a map. Does not throw — all validation
    /// happened at parse time.
    public static func execute(
        _ selector: Selector,
        in map: ScreenMap,
        tiers: [ElementRef: IdentityTier],
        options: QueryOptions = QueryOptions()
    ) -> [QueryResult] {
        // 1. Run the filter if requested. `applyFilter = false` is useful for
        //    debugging and for queries that explicitly target hidden elements.
        let candidates: [ScreenElement]
        if options.applyFilter {
            let result = ElementFilter.apply(
                map.elements,
                in: map,
                policy: options.filterPolicy,
                tierSnapshot: tiers.isEmpty ? nil : tiers
            )
            candidates = result.kept
        } else {
            candidates = map.elements
        }

        // 2. Index elements by ref for parent/ancestor lookups.
        let byRef: [ElementRef: ScreenElement] = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.ref, $0) }
        )

        // 3. `nearRef` needs the anchor element's position up front.
        //    Pre-resolve every nearRef predicate so we don't re-lookup per row.
        let nearAnchors = collectNearAnchors(
            selector: selector,
            candidates: candidates
        )

        // 4. Score every element.
        var matches: [(QueryResult, ScreenElement)] = []
        matches.reserveCapacity(candidates.count)
        for element in candidates {
            if !options.includeNonInteractive && !element.role.isInteractive {
                continue
            }
            let score = evaluate(
                predicates: selector.predicates,
                element: element,
                byRef: byRef,
                nearAnchors: nearAnchors,
                tiers: tiers
            )
            guard score >= options.minimumScore else { continue }
            let tier = tiers[element.ref] ?? .fallback
            let result = QueryResult(
                ref: element.ref,
                role: element.role,
                label: element.label,
                click: element.clickPoint,
                bounds: element.bounds,
                displayIndex: element.displayIndex,
                tier: tier,
                stabilityScore: stabilityScoreForTier(tier),
                matchScore: score
            )
            matches.append((result, element))
        }

        // 5. Sort.
        sort(matches: &matches, order: options.sortBy)

        // 6. Truncate.
        let truncated = matches.prefix(max(0, options.maxResults))
        return truncated.map { $0.0 }
    }

    // MARK: - Evaluation

    /// Returns a score in [0, 1]. 0 means any predicate returned false; > 0
    /// means every predicate matched (product of per-predicate scores).
    private static func evaluate(
        predicates: [Predicate],
        element: ScreenElement,
        byRef: [ElementRef: ScreenElement],
        nearAnchors: [ElementRef: CGPoint],
        tiers: [ElementRef: IdentityTier]
    ) -> Float {
        var product: Float = 1.0
        for p in predicates {
            let score = score(
                predicate: p,
                element: element,
                byRef: byRef,
                nearAnchors: nearAnchors,
                tiers: tiers
            )
            if score <= 0 { return 0 }
            product *= score
        }
        return product
    }

    /// Score one predicate. 0 → no match. 1 → strict match. < 1 → fuzzy match.
    private static func score(
        predicate: Predicate,
        element: ScreenElement,
        byRef: [ElementRef: ScreenElement],
        nearAnchors: [ElementRef: CGPoint],
        tiers: [ElementRef: IdentityTier]
    ) -> Float {
        switch predicate {
        case .role(let r):
            return element.role == r ? 1 : 0

        case .roleIn(let set):
            return set.contains(element.role) ? 1 : 0

        case .labelEquals(let s, let ci):
            let a = element.label
            if ci { return a.caseInsensitiveCompare(s) == .orderedSame ? 1 : 0 }
            return a == s ? 1 : 0

        case .labelRegex(let regex):
            let range = NSRange(location: 0, length: (element.label as NSString).length)
            let match = regex.firstMatch(in: element.label, options: [], range: range)
            return match != nil ? 1 : 0

        case .labelContains(let s, let ci):
            return substringMatch(element.label, needle: s, caseInsensitive: ci) ? 1 : 0

        case .labelStartsWith(let s, let ci):
            if ci {
                return element.label.lowercased().hasPrefix(s.lowercased()) ? 1 : 0
            }
            return element.label.hasPrefix(s) ? 1 : 0

        case .valueContains(let s, let ci):
            // Intercept the NOT-sentinel: the parser uses this to express
            // `!<term>` where no natural inverse exists on the predicate enum.
            if NegationTable.isSentinel(s) {
                guard let original = NegationTable.lookup(s) else { return 0 }
                let inner = score(
                    predicate: original,
                    element: element,
                    byRef: byRef,
                    nearAnchors: nearAnchors,
                    tiers: tiers
                )
                return inner > 0 ? 0 : 1
            }
            return substringMatch(element.value, needle: s, caseInsensitive: ci) ? 1 : 0

        case .parentLabel(let s, let ci):
            guard let pref = element.parentRef, let parent = byRef[pref] else { return 0 }
            return substringMatch(parent.label, needle: s, caseInsensitive: ci) ? 1 : 0

        case .inContainer(let s, let ci):
            // Walk the ancestor chain; match if any ancestor's label contains.
            var current: ElementRef? = element.parentRef
            var steps = 0
            while let ref = current, let parent = byRef[ref], steps < 32 {
                if substringMatch(parent.label, needle: s, caseInsensitive: ci) { return 1 }
                current = parent.parentRef
                steps += 1
            }
            return 0

        case .depthGreater(let n):
            return element.depth > n ? 1 : 0

        case .depthLess(let n):
            return element.depth < n ? 1 : 0

        case .depthEquals(let n):
            return element.depth == n ? 1 : 0

        case .visible(let want):
            let isVisible = !element.state.contains(.offScreen)
                && (element.bounds?.width ?? 0) > 0
                && (element.bounds?.height ?? 0) > 0
            return isVisible == want ? 1 : 0

        case .interactive(let want):
            return element.role.isInteractive == want ? 1 : 0

        case .hasState(let s):
            return element.state.contains(s) ? 1 : 0

        case .lacksState(let s):
            return element.state.contains(s) ? 0 : 1

        case .hasAction(let a):
            return element.actions.contains(a) ? 1 : 0

        case .displayIndex(let n):
            return element.displayIndex == n ? 1 : 0

        case .refEquals(let ref):
            return element.ref == ref ? 1 : 0

        case .nearRef(let ref, let radius):
            // Anchor point: the query engine pre-resolved the element with
            // this ref in `nearAnchors`. If not present (ref not in filtered
            // set), fail closed — no match.
            guard let anchor = nearAnchors[ref] else { return 0 }
            let elPoint = element.clickPoint ?? (element.bounds?.midPoint ?? .zero)
            let dx = elPoint.x - anchor.x
            let dy = elPoint.y - anchor.y
            let distance = (dx*dx + dy*dy).squareRoot()
            return distance <= radius ? 1 : 0

        case .boundsContains(let p):
            guard let b = element.bounds else { return 0 }
            return b.contains(p) ? 1 : 0

        case .tier(let t):
            let actual = tiers[element.ref] ?? .fallback
            return actual == t ? 1 : 0

        case .confidenceAbove(let f):
            return element.confidence > f ? 1 : 0

        case .labelFuzzyMatches(let target, let threshold):
            let sim = fuzzySimilarity(a: element.label, b: target)
            return sim >= threshold ? sim : 0
        }
    }

    // MARK: - Near anchors

    /// Pre-resolve `nearRef` predicates to their anchor points so we don't
    /// dictionary-lookup per row.
    private static func collectNearAnchors(
        selector: Selector,
        candidates: [ScreenElement]
    ) -> [ElementRef: CGPoint] {
        var result: [ElementRef: CGPoint] = [:]
        var elByRef: [ElementRef: ScreenElement] = [:]
        for el in candidates {
            elByRef[el.ref] = el
        }
        for p in selector.predicates {
            if case .nearRef(let ref, _) = p {
                if let anchor = elByRef[ref] {
                    let pt = anchor.clickPoint ?? (anchor.bounds?.midPoint ?? .zero)
                    result[ref] = pt
                }
            }
        }
        return result
    }

    // MARK: - Fuzzy similarity

    /// Trigram Jaccard similarity between two label strings. Returns [0, 1].
    /// This is deliberately simple; fancier algorithms (Jaro-Winkler, token
    /// set ratio) only outperform on specific shapes we don't have yet.
    internal static func fuzzySimilarity(a: String, b: String) -> Float {
        let norm = { (s: String) in
            s.lowercased().filter { !$0.isWhitespace }
        }
        let la = norm(a)
        let lb = norm(b)
        if la.isEmpty || lb.isEmpty { return 0 }
        if la == lb { return 1 }
        let sa = trigrams(la)
        let sb = trigrams(lb)
        if sa.isEmpty || sb.isEmpty {
            // Too short for trigrams — fall back to character-set Jaccard.
            let ca = Set(la)
            let cb = Set(lb)
            let inter = Float(ca.intersection(cb).count)
            let union = Float(ca.union(cb).count)
            return union == 0 ? 0 : inter / union
        }
        let inter = Float(sa.intersection(sb).count)
        let union = Float(sa.union(sb).count)
        return union == 0 ? 0 : inter / union
    }

    private static func trigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 3 else { return [] }
        var out: Set<String> = []
        for i in 0...(chars.count - 3) {
            out.insert(String(chars[i..<(i+3)]))
        }
        return out
    }

    // MARK: - Substring helpers

    private static func substringMatch(_ haystack: String, needle: String, caseInsensitive: Bool) -> Bool {
        if caseInsensitive {
            return haystack.range(of: needle, options: .caseInsensitive) != nil
        }
        return haystack.range(of: needle) != nil
    }

    // MARK: - Sorting

    private static func sort(
        matches: inout [(QueryResult, ScreenElement)],
        order: QuerySortOrder
    ) {
        switch order {
        case .matchScore:
            matches.sort { (a, b) in
                if a.0.matchScore != b.0.matchScore {
                    return a.0.matchScore > b.0.matchScore
                }
                if a.0.stabilityScore != b.0.stabilityScore {
                    return a.0.stabilityScore > b.0.stabilityScore
                }
                let ay = a.1.bounds?.midY ?? CGFloat.greatestFiniteMagnitude
                let by = b.1.bounds?.midY ?? CGFloat.greatestFiniteMagnitude
                return ay < by
            }
        case .topToBottom:
            matches.sort { (a, b) in
                let ay = a.1.bounds?.midY ?? CGFloat.greatestFiniteMagnitude
                let by = b.1.bounds?.midY ?? CGFloat.greatestFiniteMagnitude
                return ay < by
            }
        case .leftToRight:
            matches.sort { (a, b) in
                let ax = a.1.bounds?.minX ?? CGFloat.greatestFiniteMagnitude
                let bx = b.1.bounds?.minX ?? CGFloat.greatestFiniteMagnitude
                return ax < bx
            }
        case .stabilityScore:
            matches.sort { (a, b) in
                if a.0.stabilityScore != b.0.stabilityScore {
                    return a.0.stabilityScore > b.0.stabilityScore
                }
                return a.0.matchScore > b.0.matchScore
            }
        }
    }

    // MARK: - Tier score mirroring

    private static func stabilityScoreForTier(_ tier: IdentityTier) -> Float {
        switch tier {
        case .identifier: return 1.0
        case .menu:       return 0.9
        case .dom:        return 0.85
        case .label:      return 0.75
        case .position:   return 0.5
        case .visual:     return 0.35
        case .fallback:   return 0.2
        }
    }
}

// MARK: - CGRect helpers

extension CGRect {
    fileprivate var midPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
