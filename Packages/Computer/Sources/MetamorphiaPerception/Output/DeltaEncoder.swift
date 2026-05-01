import Foundation
import CoreGraphics

// MARK: - Any-Encodable Scalar Wrapper
//
// `AnyEncodable` is ComputerLib's minimal scalar envelope for `FieldChange`.
// We deliberately don't import Omni's `AnyCodable` here — ComputerLib has
// zero knowledge of the LLM stack above it. Internals are serialized through
// `JSONSerialization` so the value must be a JSON-fundamental (String, Int,
// Double, Bool, Array/Dict of same, or NSNull).

/// Type-erased JSON-fundamental wrapper used by `FieldChange`. Stored as `Any`
/// because the field payload is heterogeneous (strings for labels, arrays for
/// bounds, arrays of strings for state, etc.) and is ultimately fed into
/// `JSONSerialization`.
public struct AnyEncodable: @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }
}

// MARK: - Delta Payload

/// Top-level delta payload emitted once per `captureDelta` call. Encodes both
/// the baseline (first-capture) and subsequent-capture shapes so consumers can
/// pattern-match on `isBaseline` without a second type.
public struct DeltaPayload: Sendable {
    public let sessionID: String
    public let sequenceNumber: Int
    /// True on the very first capture of a session — `baselineJSON` is the
    /// full `SnapshotEncoder.encode` output. Subsequent captures flip this to
    /// `false` and populate `delta`.
    public let isBaseline: Bool
    public let timestamp: Date
    public let captureMs: Int

    /// Full snapshot JSON if `isBaseline == true`, else nil.
    public let baselineJSON: String?

    /// Delta payload if `isBaseline == false`, else nil.
    public let delta: DeltaBody?

    public init(
        sessionID: String,
        sequenceNumber: Int,
        isBaseline: Bool,
        timestamp: Date,
        captureMs: Int,
        baselineJSON: String?,
        delta: DeltaBody?
    ) {
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.isBaseline = isBaseline
        self.timestamp = timestamp
        self.captureMs = captureMs
        self.baselineJSON = baselineJSON
        self.delta = delta
    }
}

/// The non-baseline portion of a `DeltaPayload`. Added/removed/changed/retained
/// refs are partitioned so a consumer can re-play the delta against a local
/// cache of the baseline snapshot.
public struct DeltaBody: Sendable {
    /// Full element bodies for new or identity-promoted refs.
    public let added: [ScreenElement]
    /// Refs that existed in the previous snapshot but aren't in the current.
    public let removedRefs: [ElementRef]
    /// Field-level changes for refs that survived both snapshots.
    public let changed: [FieldChange]
    /// Refs present in both snapshots with no changes — emitted explicitly so
    /// the LLM knows they're still valid references.
    public let retained: [ElementRef]
    /// Filter-stat deltas (kept-count before/after, per-rule drop deltas).
    public let filterStats: FilterStatsDelta
    /// Meta changes (app switch, window title, navigation, safety dangers).
    public let metaChanges: MetaChange?

    public init(
        added: [ScreenElement],
        removedRefs: [ElementRef],
        changed: [FieldChange],
        retained: [ElementRef],
        filterStats: FilterStatsDelta,
        metaChanges: MetaChange?
    ) {
        self.added = added
        self.removedRefs = removedRefs
        self.changed = changed
        self.retained = retained
        self.filterStats = filterStats
        self.metaChanges = metaChanges
    }
}

/// Field-level diff for a ref that persisted across snapshots. The `fields`
/// dictionary contains only the keys that changed, so an empty dict means
/// "nothing changed" and the entry is omitted from `DeltaBody.changed`.
public struct FieldChange: Sendable {
    public let ref: ElementRef
    public let fields: [String: AnyEncodable]

    public init(ref: ElementRef, fields: [String: AnyEncodable]) {
        self.ref = ref
        self.fields = fields
    }
}

/// Diff of `FilterResult` counters between the previous and current capture.
/// Positive `droppedChanges` values mean "more dropped this tick".
public struct FilterStatsDelta: Sendable {
    public let keptNow: Int
    public let keptBefore: Int
    /// Per-rule delta: positive = more dropped than last tick, negative = fewer.
    public let droppedChanges: [String: Int]

    public init(keptNow: Int, keptBefore: Int, droppedChanges: [String: Int]) {
        self.keptNow = keptNow
        self.keptBefore = keptBefore
        self.droppedChanges = droppedChanges
    }
}

/// Top-level screen meta changes — app switch, window title, navigation, and
/// safety-danger deltas. Present on `DeltaBody.metaChanges` only when at least
/// one of these fields moved.
public struct MetaChange: Sendable {
    /// `nil` if unchanged.
    public let focusedApp: String?
    /// `nil` if unchanged.
    public let windowTitle: String?
    public let navigationChanged: Bool
    public let addedDangers: [String]
    public let removedDangers: [String]

    public init(
        focusedApp: String?,
        windowTitle: String?,
        navigationChanged: Bool,
        addedDangers: [String],
        removedDangers: [String]
    ) {
        self.focusedApp = focusedApp
        self.windowTitle = windowTitle
        self.navigationChanged = navigationChanged
        self.addedDangers = addedDangers
        self.removedDangers = removedDangers
    }

    /// True when nothing moved at all — used by `buildPayload` to elide
    /// `metaChanges` from the body when possible.
    public var isEmpty: Bool {
        focusedApp == nil && windowTitle == nil
            && !navigationChanged
            && addedDangers.isEmpty && removedDangers.isEmpty
    }
}

// MARK: - Delta Encoder

/// Rank 2 — Ref-only delta encoding for LLM.
///
/// Each `screen_perceive` call without delta encoding ships ~150 bytes/element
/// × up to 500 elements = 75 KB of JSON. On the second call right after, 95%
/// of elements are unchanged — huge waste. `DeltaEncoder.buildPayload` walks
/// the previous and current `ScreenMap`s, consults the `IdentityTier` of each
/// ref, and emits a minimal ref-partitioned diff:
///
/// - `added` carries full element bodies (new refs or fallback-tier refs).
/// - `removedRefs` is ref-only.
/// - `changed` carries only the fields that changed, with a bounds tolerance
///   of 4 px to dampen jitter.
/// - `retained` is ref-only so the LLM knows they're still valid.
///
/// Tier rules:
/// - `.identifier`/`.label` refs are trusted across snapshots — missing-then-
///   reappearing refs become removed+added (not edited).
/// - `.position` refs emit bounds in their change so the consumer can
///   re-anchor them.
/// - `.fallback` refs are treated as brand new every capture — even a
///   coincidental ref-number match between snapshots gets emitted as added.
public enum DeltaEncoder {

    // MARK: Bounds tolerance

    /// Per-dimension tolerance for bounds changes. Below 4 px in all four
    /// dimensions the bounds delta is considered noise (scroll jitter, hairline
    /// re-layout) and omitted from the field change.
    public static let boundsTolerance: CGFloat = 4.0

    // MARK: - Build payload

    /// Construct a `DeltaPayload` from the previous/current `ScreenMap`s and
    /// their corresponding tier snapshots.
    ///
    /// - Parameters:
    ///   - previous: The last snapshot stored for this session (nil on the
    ///     first call).
    ///   - current: The freshly-captured `ScreenMap`.
    ///   - previousTiers: `RefStabilizer.tierSnapshot()` captured at the
    ///     previous build time. Nil means "we never saw this session before".
    ///   - currentTiers: `RefStabilizer.tierSnapshot()` captured after the
    ///     current `capture()` completed.
    ///   - sessionID: Opaque session key (the tool caller's choice).
    ///   - sequenceNumber: 0-based sequence within this session.
    ///   - policy: Filter policy shared across both snapshots.
    public static func buildPayload(
        previous: ScreenMap?,
        current: ScreenMap,
        previousTiers: [ElementRef: IdentityTier]?,
        currentTiers: [ElementRef: IdentityTier],
        sessionID: String,
        sequenceNumber: Int,
        policy: FilterPolicy = .default
    ) -> DeltaPayload {
        // First call in a session — emit baseline JSON directly so the consumer
        // seeds its local cache. This is the only code path that ships the
        // full SnapshotEncoder output.
        guard let previous else {
            let baseline = SnapshotEncoder.encode(current, policy: policy)
            return DeltaPayload(
                sessionID: sessionID,
                sequenceNumber: sequenceNumber,
                isBaseline: true,
                timestamp: current.timestamp,
                captureMs: current.captureMs,
                baselineJSON: baseline,
                delta: nil
            )
        }

        // Run the filter on both snapshots. The consumer only sees post-filter
        // elements on the baseline, so the delta must be computed on the same
        // set to avoid "adds" for elements the consumer never saw.
        let prevFiltered = ElementFilter.apply(
            previous.elements, in: previous,
            policy: policy, tierSnapshot: previousTiers
        )
        let currFiltered = ElementFilter.apply(
            current.elements, in: current,
            policy: policy, tierSnapshot: currentTiers
        )

        let prevByRef = Dictionary(
            prevFiltered.kept.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currByRef = Dictionary(
            currFiltered.kept.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let prevRefs = Set(prevByRef.keys)
        let currRefs = Set(currByRef.keys)

        var added: [ScreenElement] = []
        var removedRefs: [ElementRef] = []
        var changed: [FieldChange] = []
        var retained: [ElementRef] = []

        // --- Added: currRefs \ prevRefs, plus fallback-tier refs in currRefs.
        let addedByDiff = currRefs.subtracting(prevRefs)
        let fallbackCurrent = Set(
            currByRef.keys.filter { currentTiers[$0] == .fallback }
        )
        let addedSet = addedByDiff.union(fallbackCurrent)
        for ref in addedSet {
            if let el = currByRef[ref] { added.append(el) }
        }

        // --- Removed: prevRefs \ currRefs, plus refs whose previous tier was
        // fallback (so a coincidental ref-number match isn't treated as edit).
        let removedByDiff = prevRefs.subtracting(currRefs)
        // Also drop prev-fallback refs that technically survived — they're
        // already slotted under `added` by the fallback-set union above, so
        // we surface the prev ref as removed too.
        let prevFallbackStillInCurrent = prevRefs.intersection(currRefs)
            .filter { previousTiers?[$0] == .fallback || currentTiers[$0] == .fallback }
        let removedSet = removedByDiff.union(prevFallbackStillInCurrent)
        for ref in removedSet { removedRefs.append(ref) }

        // --- Changed + retained: the intersection minus fallback-refs already
        // handled above.
        let commonRefs = prevRefs.intersection(currRefs)
            .subtracting(prevFallbackStillInCurrent)
        for ref in commonRefs {
            guard let prev = prevByRef[ref], let curr = currByRef[ref] else { continue }
            let tier = currentTiers[ref] ?? .fallback
            let fields = diffFields(prev: prev, curr: curr, tier: tier)
            if fields.isEmpty {
                retained.append(ref)
            } else {
                changed.append(FieldChange(ref: ref, fields: fields))
            }
        }

        // --- Filter-stats delta.
        let droppedBefore: [String: Int] = [
            "outside":  prevFiltered.droppedOutsideWindow,
            "tiny":     prevFiltered.droppedTooSmall,
            "clipped":  prevFiltered.droppedClipped,
            "occluded": prevFiltered.droppedOccluded,
            "deep":     prevFiltered.droppedDeep
        ]
        let droppedNow: [String: Int] = [
            "outside":  currFiltered.droppedOutsideWindow,
            "tiny":     currFiltered.droppedTooSmall,
            "clipped":  currFiltered.droppedClipped,
            "occluded": currFiltered.droppedOccluded,
            "deep":     currFiltered.droppedDeep
        ]
        var droppedChanges: [String: Int] = [:]
        for (key, nowValue) in droppedNow {
            let beforeValue = droppedBefore[key] ?? 0
            let delta = nowValue - beforeValue
            if delta != 0 { droppedChanges[key] = delta }
        }
        let filterStats = FilterStatsDelta(
            keptNow: currFiltered.totalKept,
            keptBefore: prevFiltered.totalKept,
            droppedChanges: droppedChanges
        )

        // --- Meta changes.
        let focusedAppChange: String? =
            (previous.focusedApp.name != current.focusedApp.name) ? current.focusedApp.name : nil
        let prevTitle = previous.windows.first(where: { $0.isFocused })?.title ?? ""
        let currTitle = current.windows.first(where: { $0.isFocused })?.title ?? ""
        let windowTitleChange: String? = (prevTitle != currTitle) ? currTitle : nil
        let navChanged = (previous.navigation ?? []) != (current.navigation ?? [])
        let prevDangers = Set(previous.safety.dangers.map { $0.description })
        let currDangers = Set(current.safety.dangers.map { $0.description })
        let addedDangers = Array(currDangers.subtracting(prevDangers)).sorted()
        let removedDangers = Array(prevDangers.subtracting(currDangers)).sorted()
        let meta = MetaChange(
            focusedApp: focusedAppChange,
            windowTitle: windowTitleChange,
            navigationChanged: navChanged,
            addedDangers: addedDangers,
            removedDangers: removedDangers
        )
        let metaChanges: MetaChange? = meta.isEmpty ? nil : meta

        // Stable ordering for deterministic output (tests rely on this).
        added.sort { $0.ref.index < $1.ref.index }
        removedRefs.sort { $0.index < $1.index }
        changed.sort { $0.ref.index < $1.ref.index }
        retained.sort { $0.index < $1.index }

        let body = DeltaBody(
            added: added,
            removedRefs: removedRefs,
            changed: changed,
            retained: retained,
            filterStats: filterStats,
            metaChanges: metaChanges
        )

        return DeltaPayload(
            sessionID: sessionID,
            sequenceNumber: sequenceNumber,
            isBaseline: false,
            timestamp: current.timestamp,
            captureMs: current.captureMs,
            baselineJSON: nil,
            delta: body
        )
    }

    // MARK: - Field diffing

    /// Compare `prev` and `curr` field-by-field, producing only the keys that
    /// changed. Bounds are compared with `boundsTolerance`; position-tier refs
    /// always include bounds on *any* change since the consumer uses them to
    /// re-anchor. Click-points are included when the element has click support
    /// and they changed appreciably.
    static func diffFields(
        prev: ScreenElement,
        curr: ScreenElement,
        tier: IdentityTier
    ) -> [String: AnyEncodable] {
        var out: [String: AnyEncodable] = [:]

        if prev.label != curr.label {
            out["label"] = AnyEncodable(curr.label)
        }
        if prev.value != curr.value {
            out["value"] = AnyEncodable(String(curr.value.prefix(100)))
        }
        if prev.state != curr.state {
            out["state"] = AnyEncodable(curr.state.names)
        }
        if prev.actions != curr.actions {
            out["actions"] = AnyEncodable(curr.actions.map { $0.rawValue })
        }
        if prev.parentRef != curr.parentRef {
            out["parent"] = AnyEncodable(curr.parentRef?.description ?? NSNull())
        }
        // Bounds: always emit if any side is nil and the other isn't, else
        // apply the tolerance. For position-tier refs, suppress the tolerance
        // entirely so a 2 px drift still reaches the consumer (who depends on
        // bounds for re-anchoring).
        if boundsDiffer(prev: prev.bounds, curr: curr.bounds, tier: tier) {
            if let b = curr.bounds {
                out["bounds"] = AnyEncodable([
                    Int(b.origin.x), Int(b.origin.y),
                    Int(b.width), Int(b.height)
                ] as [Int])
            } else {
                out["bounds"] = AnyEncodable(NSNull())
            }
        }
        // Click-point: only emit when bounds moved appreciably too. An
        // identical bounds with a drifted click-point can happen in some AX
        // trees; we ship it if it crosses the tolerance.
        if clickDiffer(prev: prev.clickPoint, curr: curr.clickPoint) {
            if let c = curr.clickPoint {
                out["click"] = AnyEncodable([Int(c.x), Int(c.y)] as [Int])
            } else {
                out["click"] = AnyEncodable(NSNull())
            }
        }
        return out
    }

    /// True if the bounds materially differ. Nil/non-nil mismatch always
    /// counts; otherwise each axis must exceed `boundsTolerance`. For
    /// `position` tier refs the tolerance is suppressed — the consumer uses
    /// bounds to re-anchor so any drift matters.
    static func boundsDiffer(prev: CGRect?, curr: CGRect?, tier: IdentityTier) -> Bool {
        switch (prev, curr) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case (.some(let p), .some(let c)):
            if tier == .position {
                return p != c
            }
            let tol = boundsTolerance
            return abs(p.origin.x - c.origin.x) >= tol
                || abs(p.origin.y - c.origin.y) >= tol
                || abs(p.width    - c.width)    >= tol
                || abs(p.height   - c.height)   >= tol
        }
    }

    /// Click-point delta threshold. Uses the same 4-px tolerance as bounds
    /// origin drift.
    static func clickDiffer(prev: CGPoint?, curr: CGPoint?) -> Bool {
        switch (prev, curr) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case (.some(let p), .some(let c)):
            return abs(p.x - c.x) >= boundsTolerance
                || abs(p.y - c.y) >= boundsTolerance
        }
    }

    // MARK: - JSON encoding

    /// Encode a `DeltaPayload` as compact JSON. Shape for baseline:
    ///
    ///     {"v":1,"session":"...","seq":0,"baseline":true,"ts":"...",
    ///      "ms":12,"snapshot":<snapshot-json>}
    ///
    /// Shape for delta:
    ///
    ///     {"v":1,"session":"...","seq":3,"baseline":false,"ts":"...",
    ///      "ms":8,"delta":{"added":[...], "removed":["@e7"], "changed":[...],
    ///      "retained":["@e12","@e13"], "filter":{...}, "meta":{...}}}
    public static func encode(_ payload: DeltaPayload) -> String {
        var json: [String: Any] = [
            "v": 1,
            "session": payload.sessionID,
            "seq": payload.sequenceNumber,
            "baseline": payload.isBaseline,
            "ts": ISO8601DateFormatter().string(from: payload.timestamp),
            "ms": payload.captureMs
        ]

        if payload.isBaseline {
            // Embed snapshot as a nested JSON object. We parse the string back
            // into a dict so the final output is a single well-formed doc (not
            // a string containing escaped JSON).
            if let baseline = payload.baselineJSON,
               let data = baseline.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                json["snapshot"] = obj
            }
        } else if let delta = payload.delta {
            var body: [String: Any] = [:]
            body["added"]    = delta.added.map { SnapshotEncoder.encodeElementFull($0) }
            body["removed"]  = delta.removedRefs.map { $0.description }
            body["changed"]  = delta.changed.map { SnapshotEncoder.encodeElementChange($0) }
            body["retained"] = delta.retained.map { $0.description }

            var filter: [String: Any] = [
                "kept_now": delta.filterStats.keptNow,
                "kept_before": delta.filterStats.keptBefore
            ]
            if !delta.filterStats.droppedChanges.isEmpty {
                filter["dropped_delta"] = delta.filterStats.droppedChanges
            }
            body["filter"] = filter

            if let meta = delta.metaChanges {
                var metaDict: [String: Any] = [:]
                if let app = meta.focusedApp { metaDict["app"] = app }
                if let title = meta.windowTitle { metaDict["title"] = title }
                if meta.navigationChanged { metaDict["nav"] = true }
                if !meta.addedDangers.isEmpty { metaDict["danger_added"] = meta.addedDangers }
                if !meta.removedDangers.isEmpty { metaDict["danger_removed"] = meta.removedDangers }
                if !metaDict.isEmpty { body["meta"] = metaDict }
            }
            json["delta"] = body
        }

        return serializeJSON(json)
    }

    /// Text (LLM) format. Delegates to `TextFormatter.formatDelta` for the
    /// non-baseline path; baseline captures go through the standard
    /// `TextFormatter.format` with a `Baseline #<seq>:` header.
    public static func encodeText(_ payload: DeltaPayload, maxElements: Int = 120) -> String {
        TextFormatter.formatDelta(payload, maxElements: maxElements)
    }

    // MARK: - Helpers

    private static func serializeJSON(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }
}
