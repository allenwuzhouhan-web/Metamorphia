import Foundation
import CoreGraphics

// MARK: - Filter Policy

/// Tunable knobs for `ElementFilter.apply`. The filter is a pre-encoding pass
/// that drops off-viewport, tiny, clipped, occluded, and deep non-interactive
/// elements so downstream encoders (TextFormatter, SnapshotEncoder) don't ship
/// 500 rows of JSON per capture.
///
/// Rank 1 — Viewport + visibility filter pre-encoding. See `.aggressive` /
/// `.permissive` for preset tradeoffs between token-efficiency and completeness.
public struct FilterPolicy: Sendable {
    /// Drop elements whose bounds don't intersect any window's bounds. When
    /// false, the viewport filter is disabled and every element passes the
    /// first stage.
    public var dropOutsideFocusedWindow: Bool

    /// Drop elements whose area is smaller than this (pixels²).
    public var minElementArea: CGFloat

    /// Drop elements clipped by a parent scroll/list container to less than
    /// this visible fraction.
    public var minVisibleFraction: CGFloat

    /// Drop elements covered by a higher-z element by more than this fraction.
    public var maxOccludedFraction: CGFloat

    /// Drop non-interactive elements deeper than this depth. `nil` disables
    /// the depth filter for non-interactive elements.
    public var maxDepthForNonInteractive: Int?

    /// Depth priority decay for non-interactive elements. `score = 1 / (1 + decay * depth)`.
    /// The score is attached to `FilterResult.priorityByRef` and consumed by
    /// TextFormatter to order tied groups (higher score first).
    public var depthDecayFactor: Float

    /// Always keep these element roles regardless of filters (safety nets).
    public var alwaysKeepRoles: Set<ElementRole>

    /// Keep elements matching these refs even if filters would drop them.
    public var pinnedRefs: Set<ElementRef>

    /// If true, interactive elements are always kept even when bounds fail
    /// filters (virtualized rows, zero-bounds buttons, off-screen tab items
    /// whose click target is still the real entry point).
    public var alwaysKeepInteractive: Bool

    public init(
        dropOutsideFocusedWindow: Bool = true,
        minElementArea: CGFloat = 4.0,
        minVisibleFraction: CGFloat = 0.2,
        maxOccludedFraction: CGFloat = 0.9,
        maxDepthForNonInteractive: Int? = 10,
        depthDecayFactor: Float = 0.15,
        alwaysKeepRoles: Set<ElementRole> = [.sheet, .dialog],
        pinnedRefs: Set<ElementRef> = [],
        alwaysKeepInteractive: Bool = true
    ) {
        self.dropOutsideFocusedWindow = dropOutsideFocusedWindow
        self.minElementArea = minElementArea
        self.minVisibleFraction = minVisibleFraction
        self.maxOccludedFraction = maxOccludedFraction
        self.maxDepthForNonInteractive = maxDepthForNonInteractive
        self.depthDecayFactor = depthDecayFactor
        self.alwaysKeepRoles = alwaysKeepRoles
        self.pinnedRefs = pinnedRefs
        self.alwaysKeepInteractive = alwaysKeepInteractive
    }

    /// Balanced default. Drops hidden/off-viewport/tiny elements but keeps
    /// interactive controls and the top non-interactive content.
    public static let `default` = FilterPolicy()

    /// Tighter thresholds for token-constrained contexts (Claude prompt on
    /// busy screens). More aggressive occlusion drop and a shallower
    /// non-interactive depth cap.
    public static let aggressive = FilterPolicy(
        dropOutsideFocusedWindow: true,
        minElementArea: 16.0,
        minVisibleFraction: 0.35,
        maxOccludedFraction: 0.75,
        maxDepthForNonInteractive: 6,
        depthDecayFactor: 0.25,
        alwaysKeepRoles: [.sheet, .dialog],
        pinnedRefs: [],
        alwaysKeepInteractive: true
    )

    /// Looser thresholds for debugging / local inspection. Disables most
    /// filters so consumers can see everything AXReader emitted.
    public static let permissive = FilterPolicy(
        dropOutsideFocusedWindow: false,
        minElementArea: 0.0,
        minVisibleFraction: 0.0,
        maxOccludedFraction: 1.0,
        maxDepthForNonInteractive: nil,
        depthDecayFactor: 0.05,
        alwaysKeepRoles: [.sheet, .dialog, .staticText, .image],
        pinnedRefs: [],
        alwaysKeepInteractive: true
    )
}

// MARK: - Filter Result

/// Outcome of a filter pass — the kept elements plus per-rule drop counters
/// and a parallel priority map TextFormatter uses to order ties.
public struct FilterResult: Sendable {
    /// Elements that survived all filter rules. Order matches the caller's
    /// input order (stable).
    public let kept: [ScreenElement]

    /// Count of elements dropped because their bounds didn't intersect any
    /// window in `ScreenMap.windows`.
    public let droppedOutsideWindow: Int

    /// Count of elements dropped because `width*height < minElementArea`.
    public let droppedTooSmall: Int

    /// Count of elements dropped because a scroll/table/outline/list ancestor
    /// clipped them to less than `minVisibleFraction`.
    public let droppedClipped: Int

    /// Count of elements dropped because a later-drawn element covered more
    /// than `maxOccludedFraction` of their bounds.
    public let droppedOccluded: Int

    /// Count of non-interactive elements dropped for depth exceeding
    /// `maxDepthForNonInteractive`.
    public let droppedDeep: Int

    /// Total element count that went into the filter.
    public let totalInput: Int

    /// Per-ref priority scores. Higher = more worth showing first.
    /// Consumed by TextFormatter to sort within groups when the maxElements
    /// budget forces trimming.
    public let priorityByRef: [ElementRef: Float]

    public var totalKept: Int { kept.count }
    public var totalDropped: Int { totalInput - totalKept }

    public init(
        kept: [ScreenElement],
        droppedOutsideWindow: Int,
        droppedTooSmall: Int,
        droppedClipped: Int,
        droppedOccluded: Int,
        droppedDeep: Int,
        totalInput: Int,
        priorityByRef: [ElementRef: Float]
    ) {
        self.kept = kept
        self.droppedOutsideWindow = droppedOutsideWindow
        self.droppedTooSmall = droppedTooSmall
        self.droppedClipped = droppedClipped
        self.droppedOccluded = droppedOccluded
        self.droppedDeep = droppedDeep
        self.totalInput = totalInput
        self.priorityByRef = priorityByRef
    }
}

// MARK: - Filter pipeline internals

/// Why an element is in `kept` — drives whether later passes (occlusion) can
/// evict it. File-scope so helper functions can take it as a parameter.
fileprivate enum KeepReason {
    /// An interactive element rescued by `alwaysKeepInteractive`.
    case interactive
    /// A ref caller pinned.
    case pinned
    /// A role in `policy.alwaysKeepRoles` (dialog, sheet, ...).
    case alwaysKeepRole
    /// Rescued by Rank-4 identity-tier promotion — priority demoted to <0.3.
    case tierRescued
    /// Passed every filter without intervention — fair game for occlusion.
    case passedFilters
}

/// Which rule would drop this element, if `reason == nil`.
fileprivate enum DropRule {
    case outsideWindow
    case tooSmall
    case clipped
    case deep
    case occluded
}

/// One element's status as it moves through the pipeline.
fileprivate struct Candidate {
    let element: ScreenElement
    var reason: KeepReason?
    var dropRule: DropRule?
}

// MARK: - Element Filter

/// Pre-encoding visibility filter. Walks `map.elements`, drops ones that an
/// LLM can't plausibly act on or see, and emits a `FilterResult` with drop
/// counters per rule. Rank 1 of the perception-token-efficiency roadmap.
public enum ElementFilter {

    // MARK: Public entry point

    /// Apply the filter to `elements` in the context of `map`.
    ///
    /// - Parameters:
    ///   - elements: The elements to filter. Normally `map.elements`, but
    ///     callers can pass a pre-filtered slice (e.g. after a delta pass).
    ///   - map: The containing map — windows, displays, and element tree
    ///     used for bounds/parent lookups.
    ///   - policy: Tuning knobs. See `FilterPolicy.default` / `.aggressive` / `.permissive`.
    ///   - tierSnapshot: Optional ref→tier map from `RefStabilizer.tierSnapshot()`.
    ///     When supplied, elements that would otherwise be dropped but whose
    ///     ref is at `.identifier` or `.label` tier are kept with a priority
    ///     demotion so user actions referring to labeled items survive across
    ///     captures.
    public static func apply(
        _ elements: [ScreenElement],
        in map: ScreenMap,
        policy: FilterPolicy = .default,
        tierSnapshot: [ElementRef: IdentityTier]? = nil
    ) -> FilterResult {
        // Shared lookups.
        let parents = Dictionary(elements.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let windowRects = collectWindowBounds(map: map)

        var candidates: [Candidate] = []
        candidates.reserveCapacity(elements.count)

        // --- Pass A/B: classify every element ----------------------------------
        for el in elements {
            // A1: alwaysKeepRoles.
            if policy.alwaysKeepRoles.contains(el.role) {
                candidates.append(Candidate(element: el, reason: .alwaysKeepRole, dropRule: nil))
                continue
            }
            // A2: pinned refs.
            if policy.pinnedRefs.contains(el.ref) {
                candidates.append(Candidate(element: el, reason: .pinned, dropRule: nil))
                continue
            }
            // A3: interactive fast-path.
            if policy.alwaysKeepInteractive && el.role.isInteractive {
                candidates.append(Candidate(element: el, reason: .interactive, dropRule: nil))
                continue
            }

            // B1: window filter.
            if policy.dropOutsideFocusedWindow,
               isOutsideAnyWindow(el, windows: map.windows, cachedWindowRects: windowRects) {
                candidates.append(Candidate(element: el, reason: nil, dropRule: .outsideWindow))
                continue
            }
            // B2: min-area filter.
            if let b = el.bounds, policy.minElementArea > 0 {
                if b.width * b.height < policy.minElementArea {
                    candidates.append(Candidate(element: el, reason: nil, dropRule: .tooSmall))
                    continue
                }
            }
            // B3: scroll-clip filter.
            if policy.minVisibleFraction > 0 {
                let visible = clipByParents(el, parents: parents)
                if visible < policy.minVisibleFraction {
                    candidates.append(Candidate(element: el, reason: nil, dropRule: .clipped))
                    continue
                }
            }
            // B4: depth filter for non-interactive.
            if let maxDepth = policy.maxDepthForNonInteractive,
               !el.role.isInteractive,
               el.depth > maxDepth {
                candidates.append(Candidate(element: el, reason: nil, dropRule: .deep))
                continue
            }
            candidates.append(Candidate(element: el, reason: .passedFilters, dropRule: nil))
        }

        // --- Pass E: tier-driven rescue (Rank 4 integration) -------------------
        // An element dropped above but whose ref is at identifier/label tier
        // carries continuity value the user has likely pinned through labels in
        // their action history. Keep it with a priority demotion.
        var demotedRefs: Set<ElementRef> = []
        if let tiers = tierSnapshot {
            for i in candidates.indices {
                guard candidates[i].reason == nil else { continue }
                guard let tier = tiers[candidates[i].element.ref] else { continue }
                if tier == .identifier || tier == .label {
                    candidates[i].reason = .tierRescued
                    candidates[i].dropRule = nil
                    demotedRefs.insert(candidates[i].element.ref)
                }
            }
        }

        // --- Pass C: occlusion --------------------------------------------------
        // Only evict elements whose reason is `.passedFilters` — we don't
        // evict interactive/pinned/alwaysKeepRole/tierRescued via occlusion.
        if policy.maxOccludedFraction < 1.0 {
            applyOcclusionPass(candidates: &candidates, maxOccludedFraction: policy.maxOccludedFraction)
        }

        // --- Tally definitive drops ---------------------------------------------
        var droppedOutsideWindow = 0
        var droppedTooSmall = 0
        var droppedClipped = 0
        var droppedOccluded = 0
        var droppedDeep = 0
        for c in candidates where c.reason == nil {
            switch c.dropRule {
            case .outsideWindow: droppedOutsideWindow += 1
            case .tooSmall:      droppedTooSmall += 1
            case .clipped:       droppedClipped += 1
            case .deep:          droppedDeep += 1
            case .occluded:      droppedOccluded += 1
            case .none:          break
            }
        }

        // --- Pass D: emit + priorities ------------------------------------------
        var out: [ScreenElement] = []
        out.reserveCapacity(candidates.count)
        var priorityByRef: [ElementRef: Float] = [:]
        priorityByRef.reserveCapacity(candidates.count)

        for c in candidates {
            guard c.reason != nil else { continue }
            out.append(c.element)
            var base = depthPriority(c.element, decay: policy.depthDecayFactor)
            // Promote interactive elements so they surface first when a token
            // budget forces trimming.
            if c.element.role.isInteractive { base = min(base + 0.25, 1.5) }
            // Demoted (tier-rescued) refs clamp to < 0.3.
            if demotedRefs.contains(c.element.ref) { base = min(base, 0.25) }
            priorityByRef[c.element.ref] = base
        }

        return FilterResult(
            kept: out,
            droppedOutsideWindow: droppedOutsideWindow,
            droppedTooSmall: droppedTooSmall,
            droppedClipped: droppedClipped,
            droppedOccluded: droppedOccluded,
            droppedDeep: droppedDeep,
            totalInput: elements.count,
            priorityByRef: priorityByRef
        )
    }

    // MARK: - Occlusion pass

    /// Sort surviving candidates by (windowIndex asc, depth asc) — earlier
    /// entries are "behind", later entries are "in front". For each candidate
    /// whose `reason == .passedFilters`, sum the intersecting area of every
    /// later-drawn element and drop if coverage > `maxOccludedFraction`.
    fileprivate static func applyOcclusionPass(
        candidates: inout [Candidate],
        maxOccludedFraction: CGFloat
    ) {
        // Collect surviving indices.
        let surviving: [Int] = candidates.enumerated().compactMap { idx, c in
            c.reason == nil ? nil : idx
        }
        if surviving.count < 2 { return }

        // Build layer order. Lower (windowIndex, depth) = further back.
        let sorted = surviving.sorted { (a, b) in
            let ea = candidates[a].element
            let eb = candidates[b].element
            if ea.windowIndex != eb.windowIndex { return ea.windowIndex < eb.windowIndex }
            return ea.depth < eb.depth
        }

        // Per-candidate: compute cumulative occluder coverage from later entries.
        var toDrop: [Int] = []
        for (position, candIndex) in sorted.enumerated() {
            let cand = candidates[candIndex]
            // Never evict interactive / pinned / alwaysKeepRole / tierRescued.
            // They still serve as occluders of others, but can't be dropped themselves.
            guard cand.reason == .passedFilters else { continue }
            guard let elBounds = cand.element.bounds,
                  elBounds.width > 0, elBounds.height > 0 else { continue }

            let elArea = elBounds.width * elBounds.height
            var coveredArea: CGFloat = 0
            if position + 1 < sorted.count {
                for j in (position + 1)..<sorted.count {
                    let other = candidates[sorted[j]].element
                    guard let ob = other.bounds else { continue }
                    let inter = elBounds.intersection(ob)
                    if !inter.isNull && inter.width > 0 && inter.height > 0 {
                        coveredArea += inter.width * inter.height
                    }
                    if coveredArea >= elArea { break }
                }
            }
            let occludedFraction = min(coveredArea / elArea, 1.0)
            if occludedFraction > maxOccludedFraction {
                toDrop.append(candIndex)
            }
        }

        for idx in toDrop {
            candidates[idx].reason = nil
            candidates[idx].dropRule = .occluded
        }
    }

    // MARK: - Internal helpers (exposed for tests)

    /// Pre-compute the set of rectangles we consider "the viewport". All
    /// window bounds plus any dialog/sheet bounds that escape a window. The
    /// caller uses this for any-intersection checks.
    internal static func collectWindowBounds(map: ScreenMap) -> [CGRect] {
        if map.windows.isEmpty { return [] }
        var rects: [CGRect] = map.windows.map(\.bounds)
        for el in map.elements where el.role == .sheet || el.role == .dialog {
            if let b = el.bounds { rects.append(b) }
        }
        return rects
    }

    /// `true` if `el`'s bounds don't intersect any window rect. Elements
    /// without usable bounds (nil / zero-size) return `false` — we never drop
    /// them via this rule alone.
    internal static func isOutsideAnyWindow(
        _ el: ScreenElement,
        windows: [WindowInfo],
        cachedWindowRects: [CGRect]? = nil
    ) -> Bool {
        guard let b = el.bounds, b.width > 0 || b.height > 0 else { return false }
        let rects = cachedWindowRects ?? windows.map(\.bounds)
        if rects.isEmpty { return false }
        for r in rects {
            if r.intersects(b) { return false }
        }
        return true
    }

    /// Compute the visible fraction of `el` after clipping against every
    /// scroll/table/outline/list ancestor. Returns a value in [0,1]. If `el`
    /// has no usable bounds, returns 1.0 (not dropped by this rule alone).
    internal static func clipByParents(
        _ el: ScreenElement,
        parents: [ElementRef: ScreenElement]
    ) -> CGFloat {
        guard let b = el.bounds, b.width > 0, b.height > 0 else { return 1.0 }
        let totalArea = b.width * b.height
        var visible = b
        var current: ElementRef? = el.parentRef
        var steps = 0
        while let ref = current, let parent = parents[ref], steps < 24 {
            steps += 1
            if isClippingContainer(parent.role),
               let pb = parent.bounds, pb.width > 0, pb.height > 0 {
                visible = visible.intersection(pb)
                if visible.isNull || visible.width <= 0 || visible.height <= 0 {
                    return 0.0
                }
            }
            current = parent.parentRef
        }
        let area = visible.width * visible.height
        return max(0, min(1, area / totalArea))
    }

    /// Roles that clip their descendants. Scroll areas, tables, outlines, lists,
    /// and tab groups all introduce a scroll-viewport-style clipping region.
    private static func isClippingContainer(_ role: ElementRole) -> Bool {
        switch role {
        case .scrollArea, .table, .outline, .list, .tabGroup:
            return true
        default:
            return false
        }
    }

    /// Occlusion probe for unit tests. Given `el` and a list of `others`
    /// considered to be drawn *on top*, return `true` if the element is
    /// covered by more than `maxFraction` of its area.
    internal static func isOccluded(
        _ el: ScreenElement,
        by others: [ScreenElement],
        maxFraction: CGFloat
    ) -> Bool {
        guard let b = el.bounds, b.width > 0, b.height > 0 else { return false }
        let area = b.width * b.height
        var covered: CGFloat = 0
        for o in others {
            guard let ob = o.bounds else { continue }
            let inter = b.intersection(ob)
            if !inter.isNull && inter.width > 0 && inter.height > 0 {
                covered += inter.width * inter.height
            }
            if covered >= area { break }
        }
        return (min(covered, area) / area) > maxFraction
    }

    /// Priority derived from depth: shallower = higher. `score = 1 / (1 + decay * depth)`.
    internal static func depthPriority(_ el: ScreenElement, decay: Float) -> Float {
        let d = max(0, Float(el.depth))
        return 1.0 / (1.0 + decay * d)
    }
}
