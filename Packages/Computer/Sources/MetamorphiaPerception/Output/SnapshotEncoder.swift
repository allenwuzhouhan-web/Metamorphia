import Foundation
import CoreGraphics

/// Encodes ScreenMap to token-efficient JSON with short keys.
/// A 50-element screen encodes to ~1000-1500 tokens.
public enum SnapshotEncoder {

    public static func encode(
        _ map: ScreenMap,
        policy: FilterPolicy = .default
    ) -> String {
        // Rank 1 — viewport/visibility filter pre-encoding.
        let filterResult = ElementFilter.apply(map.elements, in: map, policy: policy)
        return encode(map, filterResult: filterResult)
    }

    /// Escape hatch for callers that already ran the filter and want to reuse
    /// its result (avoids double-filtering for code paths that branch on
    /// `kept`/`priorityByRef`).
    public static func encode(_ map: ScreenMap, filterResult: FilterResult) -> String {
        var json: [String: Any] = [:]
        // Schema v2 adds optional browserDOM field for full HTML capture from supported browsers.
        // v1 encoders can still read this because it's additive; older decoders will ignore browserDOM.
        json["v"] = 2
        json["ts"] = ISO8601DateFormatter().string(from: map.timestamp)
        json["ms"] = map.captureMs

        // Display (legacy single-display field — always a dict, primary display).
        // Schema-compatible with v1 consumers; anyone aware of multi-display
        // should read the `displays` array below.
        json["display"] = [
            "w": map.display.width,
            "h": map.display.height,
            "scale": map.display.scale
        ]

        // Displays array — added in v2.1 (additive, backward compatible). Each
        // entry carries id/index/name/origin/width/height/scale/isMain so a
        // consumer can reconstruct the full display layout.
        json["displays"] = map.displays.map { d -> [String: Any] in
            [
                "id": d.id,
                "index": d.index,
                "name": d.name,
                "origin": [Int(d.origin.x), Int(d.origin.y)],
                "w": d.width,
                "h": d.height,
                "scale": d.scale,
                "main": d.isMain
            ]
        }

        // Focused app
        var focus: [String: Any] = [
            "app": map.focusedApp.name,
            "pid": map.focusedApp.pid
        ]
        if let bundle = map.focusedApp.bundleID {
            focus["bundle"] = bundle
        }
        json["focus"] = focus

        // Windows
        json["windows"] = map.windows.map { win -> [String: Any] in
            var w: [String: Any] = [
                "idx": win.index,
                "app": win.appName,
                "title": win.title,
                "bounds": boundsArray(win.bounds),
                "focused": win.isFocused
            ]
            if let bundle = win.appBundleID {
                w["bundle"] = bundle
            }
            // Window's display index only emitted when non-default (non-main)
            // to keep the single-display payload identical to v2.0.
            if win.displayIndex > 0 {
                w["disp"] = win.displayIndex
            }
            return w
        }

        // Navigation
        if let nav = map.navigation {
            json["nav"] = nav
        }

        // Elements (the main payload) — post-filter. Unfiltered elements are
        // still referenced via `parent` chains because refs remain valid.
        json["elements"] = filterResult.kept.map { encodeElement($0) }

        // Rank 1 — filter stats. Only emitted when any drop happened so the
        // common full-pass case doesn't grow the JSON payload by even one key.
        if filterResult.totalDropped > 0 {
            var dropped: [String: Int] = [:]
            if filterResult.droppedOutsideWindow > 0 { dropped["outside"]  = filterResult.droppedOutsideWindow }
            if filterResult.droppedTooSmall > 0      { dropped["tiny"]     = filterResult.droppedTooSmall }
            if filterResult.droppedClipped > 0       { dropped["clipped"]  = filterResult.droppedClipped }
            if filterResult.droppedOccluded > 0      { dropped["occluded"] = filterResult.droppedOccluded }
            if filterResult.droppedDeep > 0          { dropped["deep"]     = filterResult.droppedDeep }
            json["filter"] = [
                "kept": filterResult.totalKept,
                "total": filterResult.totalInput,
                "dropped": dropped
            ] as [String: Any]
        }

        // Safety
        json["safety"] = [
            "dangers": map.safety.dangers.map { $0.description },
            "sensitive": map.safety.sensitive.map { $0.description },
            "drift": map.safety.driftDetected
        ]

        // Metadata
        json["meta"] = [
            "ax_pct": roundToTwo(map.metadata.axCoveragePercent),
            "ocr": map.metadata.ocrUsed,
            "count": map.metadata.elementCount,
            "interactive": map.metadata.interactiveCount,
            "offscreen": map.metadata.offScreenHint as Any
        ]

        // Browser DOM (optional). Full HTML is included here because this encoder is for
        // local consumers (cache, disk, local LLM). The compact LLM-facing formatter in
        // TextFormatter.swift emits only url/title/byte-count — never the full HTML to Claude.
        if let dom = map.browserDOM {
            json["dom"] = [
                "url": dom.url,
                "title": dom.title,
                "html": dom.html,
                "bytes": dom.html.utf8.count,
                "at": ISO8601DateFormatter().string(from: dom.fetchedAt),
                "src": dom.source.rawValue
            ]
        }

        // Menu bar tree (the "non-screenshot" path). Full tree emitted to local
        // consumers. The LLM-facing text formatter produces a shorter summary.
        if !map.menus.isEmpty {
            json["menus"] = map.menus.map { item -> [String: Any] in
                var m: [String: Any] = [
                    "title": item.title,
                    "path": item.path,
                    "enabled": item.enabled
                ]
                if let shortcut = item.shortcut { m["sc"] = shortcut }
                if item.hasSubmenu { m["sub"] = true }
                return m
            }
        }

        return serializeJSON(json)
    }

    // MARK: - Element Encoding

    /// Public wrapper around the internal `encodeElement` shape used for the
    /// main `encode(_:)` payload. Exposed for `DeltaEncoder` so the `added`
    /// array of a delta payload uses the same element shape as the full
    /// snapshot — preserves consumer symmetry between baseline and delta.
    public static func encodeElementFull(_ el: ScreenElement) -> [String: Any] {
        encodeElement(el)
    }

    /// Public wrapper that shapes a `FieldChange` into the same JSON dict
    /// format used by the delta encoder. Included in `SnapshotEncoder` so the
    /// encoder layer remains the single place that owns the "element JSON
    /// shape" contract.
    public static func encodeElementChange(_ change: FieldChange) -> [String: Any] {
        var out: [String: Any] = ["ref": change.ref.description]
        for (key, wrapped) in change.fields {
            out[key] = wrapped.value
        }
        return out
    }

    private static func encodeElement(_ el: ScreenElement) -> [String: Any] {
        var e: [String: Any] = [
            "ref": el.ref.description,
            "role": el.role.rawValue,
            "lbl": el.label
        ]

        if !el.value.isEmpty && el.value != el.label {
            e["val"] = String(el.value.prefix(100))
        }

        if let bounds = el.bounds {
            e["bounds"] = boundsArray(bounds)
        }

        if let click = el.clickPoint {
            e["click"] = [Int(click.x), Int(click.y)]
        }

        let stateNames = el.state.names
        if !stateNames.isEmpty {
            e["state"] = stateNames
        }

        if !el.actions.isEmpty {
            e["actions"] = el.actions.map { $0.rawValue }
        }

        e["win"] = el.windowIndex
        // Display index only emitted when non-zero — saves tokens in the
        // common single-display case where everything lives on display 0.
        if el.displayIndex > 0 {
            e["disp"] = el.displayIndex
        }
        e["depth"] = el.depth

        if let parent = el.parentRef {
            e["parent"] = parent.description
        }

        e["src"] = el.source.rawValue

        if el.confidence < 1.0 {
            e["conf"] = roundToTwo(el.confidence)
        }

        return e
    }

    // MARK: - Helpers

    private static func boundsArray(_ rect: CGRect) -> [Int] {
        [Int(rect.origin.x), Int(rect.origin.y), Int(rect.width), Int(rect.height)]
    }

    private static func roundToTwo(_ value: Float) -> Float {
        (value * 100).rounded() / 100
    }

    /// Minimal JSON serializer that produces compact output.
    private static func serializeJSON(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }

    /// Pretty-printed JSON for human readability.
    public static func encodePretty(_ map: ScreenMap, policy: FilterPolicy = .default) -> String {
        // Re-parse the compact JSON and re-serialize with formatting
        let compact = encode(map, policy: policy)
        guard let data = compact.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return compact
        }
        return String(data: pretty, encoding: .utf8) ?? compact
    }
}
