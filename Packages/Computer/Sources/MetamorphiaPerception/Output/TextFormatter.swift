import Foundation

/// Formats ScreenMap as compact, tree-indented text for direct LLM injection.
/// Groups elements by parent containers so the LLM understands spatial hierarchy
/// (e.g., "Create Page" under "Private" section means creating a private page).
/// ~500-800 tokens for a 50-element screen.
public enum TextFormatter {

    public static func format(
        _ map: ScreenMap,
        maxElements: Int = 120,
        policy: FilterPolicy = .default
    ) -> String {
        // Rank 1 — viewport/visibility filter runs before any per-element
        // formatting so invisible elements never reach the LLM prompt.
        let filterResult = ElementFilter.apply(map.elements, in: map, policy: policy)
        return format(
            map,
            maxElements: maxElements,
            filterResult: filterResult
        )
    }

    /// Escape hatch for callers (tests, benchmarks) that already ran the
    /// filter and want to reuse the result. Keeps the public signature above
    /// pure so `formatForLLM(map)` remains one call.
    public static func format(
        _ map: ScreenMap,
        maxElements: Int,
        filterResult: FilterResult
    ) -> String {
        var lines: [String] = []

        // Header
        lines.append("Screen: \(map.focusedApp.name) — \(map.windows.first(where: { $0.isFocused })?.title ?? "")")
        if let nav = map.navigation {
            lines.append("Nav: \(nav.joined(separator: " > "))")
        }
        // Compact browser-DOM summary — only url/title/bytes, never full HTML to an LLM.
        // The full HTML stays in ScreenMap.browserDOM for local consumers (e.g., LocalDecisionEngine).
        if let dom = map.browserDOM {
            lines.append("DOM: \(dom.url)  \"\(dom.title)\"  (\(dom.html.utf8.count) bytes, \(dom.source.rawValue))")
        }
        // Compact menu-bar summary — top-level menu titles + total count. The full tree
        // stays in ScreenMap.menus for local consumers that can afford the tokens; Claude
        // gets only the gist so we don't blow the prompt budget.
        if !map.menus.isEmpty {
            let topLevels = Array(Set(map.menus.compactMap { $0.path.first })).sorted()
            lines.append("Menus: \(topLevels.joined(separator: ", "))  (\(map.menus.count) items total)")
        }
        // Multi-display header. Only emitted when there's more than one display
        // attached — single-display captures use the legacy layout path
        // unchanged to keep token counts flat.
        let isMultiDisplay = map.displays.count > 1
        if isMultiDisplay {
            let summaries = map.displays.map { d -> String in
                let mainTag = d.isMain ? " (main)" : ""
                return "[\(d.index)] \(d.name)\(mainTag) \(d.width)×\(d.height) @ (\(Int(d.origin.x)),\(Int(d.origin.y)))"
            }
            lines.append("Displays: \(summaries.joined(separator: "  "))")
        }
        lines.append("---")

        // Parent lookup spans the full map (unfiltered) — elements dropped by
        // the filter are still valid ancestry context for elements we keep.
        let elementByRef = Dictionary(
            map.elements.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // All downstream logic works on `kept` instead of `map.elements`.
        let kept = filterResult.kept
        let priorityByRef = filterResult.priorityByRef

        // Separate interactive and content elements.
        let interactive = kept.filter { $0.role.isInteractive }
        let content = kept.filter { !$0.role.isInteractive && !$0.label.isEmpty }

        var shown = 0

        if isMultiDisplay {
            // Multi-display: segment interactive elements by displayIndex and
            // render a per-display subsection. Elements on the main display
            // come first so the typical case (everything on the primary
            // display) looks identical to single-display output up top.
            let byDisplay = Dictionary(grouping: interactive) { $0.displayIndex }
            let orderedDisplays = map.displays.sorted { a, b in
                if a.isMain != b.isMain { return a.isMain }
                return a.index < b.index
            }

            for display in orderedDisplays {
                guard let displayInteractive = byDisplay[display.index], !displayInteractive.isEmpty else { continue }
                if shown >= maxElements { break }
                let mainTag = display.isMain ? " (main)" : ""
                lines.append("── Display \(display.index) (\(display.name))\(mainTag)")

                let grouped = buildSpatialGroups(displayInteractive, elementByRef: elementByRef, allElements: map.elements)
                for group in grouped {
                    if shown >= maxElements { break }
                    if let sectionLabel = group.sectionLabel {
                        let path = group.sectionPath ?? sectionLabel
                        lines.append("   ── \(path)")
                    }
                    // Rank 1 — within a group, sort by priority desc then y-position asc.
                    let sortedElements = sortByPriority(group.elements, priorityByRef: priorityByRef)
                    for el in sortedElements {
                        if shown >= maxElements { break }
                        let indent = group.sectionLabel != nil ? "      " : "   "
                        lines.append(indent + formatElement(el, parentLookup: elementByRef, skipParent: group.sectionLabel != nil))
                        shown += 1
                    }
                }
            }
        } else {
            // Single-display path: original layout, no display headers, no
            // extra indentation. Keeps existing token counts flat.
            let grouped = buildSpatialGroups(interactive, elementByRef: elementByRef, allElements: map.elements)
            for group in grouped {
                if shown >= maxElements { break }
                if let sectionLabel = group.sectionLabel {
                    let path = group.sectionPath ?? sectionLabel
                    lines.append("── \(path)")
                }
                // Rank 1 — within a group, sort by priority desc then y-position asc.
                let sortedElements = sortByPriority(group.elements, priorityByRef: priorityByRef)
                for el in sortedElements {
                    if shown >= maxElements { break }
                    let indent = group.sectionLabel != nil ? "   " : ""
                    lines.append(indent + formatElement(el, parentLookup: elementByRef, skipParent: group.sectionLabel != nil))
                    shown += 1
                }
            }
        }

        let remaining = maxElements - shown
        if remaining > 0 && !content.isEmpty {
            // Content is always sorted by priority too — higher-scoring
            // non-interactive content goes first. Ties broken by y-position.
            let sortedContent = sortByPriority(content, priorityByRef: priorityByRef)
            lines.append("--- Content ---")
            for el in sortedContent.prefix(remaining) {
                lines.append(formatElement(el, parentLookup: elementByRef, skipParent: false))
                shown += 1
            }
        }

        // Footer. The "+N more" counter now reflects (post-filter) omitted
        // elements. Filter-dropped elements are reported separately on the
        // filter-summary line below so consumers can tell "truncated for
        // budget" from "dropped as invisible".
        let totalKept = filterResult.totalKept
        if totalKept > shown {
            lines.append("... +\(totalKept - shown) more elements")
        }

        if let hint = map.metadata.offScreenHint {
            lines.append("[\(hint)]")
        }

        // Safety warnings
        if !map.safety.dangers.isEmpty {
            lines.append("⚠ DANGER: \(map.safety.dangers.map { $0.description }.joined(separator: ", "))")
        }
        if !map.safety.sensitive.isEmpty {
            lines.append("🔒 SENSITIVE: \(map.safety.sensitive.map { $0.description }.joined(separator: ", "))")
        }

        // Rank 1 — filter summary, only when any drop happened.
        if filterResult.totalDropped > 0 {
            lines.append(filterSummaryLine(filterResult))
        }

        lines.append("---")
        lines.append("[\(map.metadata.elementCount) elements, \(map.metadata.interactiveCount) interactive, \(map.captureMs)ms]")

        return lines.joined(separator: "\n")
    }

    // MARK: - Rank 2 — Delta format

    /// Format a `DeltaPayload` for LLM consumption. Baseline captures get a
    /// `Baseline #<seq>:` header prepended to the standard
    /// `TextFormatter.format` output, so the LLM sees a full tree once per
    /// session. Subsequent captures render a compact "Delta #<seq>:" block
    /// summarizing added/changed/removed/retained refs plus filter stats and
    /// meta changes. Total size for a typical tick: <1 KB vs. ~75 KB full.
    public static func formatDelta(_ payload: DeltaPayload, maxElements: Int = 120) -> String {
        if payload.isBaseline {
            return formatBaselineFromPayload(payload, maxElements: maxElements)
        }
        return formatDeltaBody(payload)
    }

    /// Render the baseline — `Baseline #<seq>:` header + normal full-tree
    /// format parsed back from `SnapshotEncoder.encode`. Keeps the text path
    /// symmetric between the two branches: consumers always see a complete
    /// screen on the first call.
    private static func formatBaselineFromPayload(_ payload: DeltaPayload, maxElements: Int) -> String {
        // We only have the JSON baseline from the encoder; the caller who
        // built the payload also has the live ScreenMap though, and can pass
        // through the structured text via `DeltaEncoder.encodeText` if it
        // wants finer control. The canonical public path is
        // `TextFormatter.format(map, maxElements:)` — the delta path above
        // this injects a header and falls through to that. To keep this
        // function pure (no ScreenMap decode), we emit a minimal header +
        // pointer; the real baseline body is produced by `formatBaselineFor`
        // below when the caller has the map.
        let header = "Baseline #\(payload.sequenceNumber): session \(payload.sessionID)"
        return header + "\n" + "(\(payload.captureMs)ms — full snapshot, see baselineJSON)"
    }

    /// Helper invoked by `DefaultComputerPerception.formatDeltaForLLM` when
    /// the live `ScreenMap` is still in hand. Prepends the baseline header
    /// to `TextFormatter.format(map, ...)` so the LLM sees the header plus
    /// the full tree on the first capture.
    public static func formatBaseline(
        _ map: ScreenMap,
        sequenceNumber: Int,
        sessionID: String,
        maxElements: Int = 120,
        policy: FilterPolicy = .default
    ) -> String {
        let header = "Baseline #\(sequenceNumber): session \(sessionID)"
        let body = TextFormatter.format(map, maxElements: maxElements, policy: policy)
        return header + "\n" + body
    }

    /// Render the delta body — one-line meta header followed by grouped
    /// ref lists for added/changed/removed/retained. Mirrors the format
    /// laid out in the Rank 2 spec.
    private static func formatDeltaBody(_ payload: DeltaPayload) -> String {
        var lines: [String] = []
        let delta = payload.delta

        // Header: Delta #N: <app> — <windowTitle>
        // App/title aren't in the payload unless they changed; we synthesize
        // a minimal header on the change signal only.
        var headerParts: [String] = ["Delta #\(payload.sequenceNumber)"]
        if let meta = delta?.metaChanges, let app = meta.focusedApp {
            headerParts.append(app)
        }
        if let meta = delta?.metaChanges, let title = meta.windowTitle {
            headerParts.append("— \(title)")
        }
        lines.append(headerParts.joined(separator: ": ").replacingOccurrences(of: ": —", with: " —"))

        // Δapp: <old→new> — only when the app name changed. We don't know
        // the old app here; MetaChange only carries the new one. Surface as
        // "Δapp: → <new>" so the LLM sees the change marker and the delta
        // encoder remains a pure "new-only" shape.
        if let meta = delta?.metaChanges, let app = meta.focusedApp {
            lines.append("  Δapp: → \(app)")
        }
        if let meta = delta?.metaChanges, let title = meta.windowTitle {
            lines.append("  Δtitle: → \"\(title)\"")
        }
        if delta?.metaChanges?.navigationChanged == true {
            lines.append("  Δnav")
        }
        if let added = delta?.metaChanges?.addedDangers, !added.isEmpty {
            lines.append("  ⚠ +dangers: \(added.joined(separator: ", "))")
        }
        if let removed = delta?.metaChanges?.removedDangers, !removed.isEmpty {
            lines.append("  ✓ -dangers: \(removed.joined(separator: ", "))")
        }

        // +N elements: @eX [role] "Label", …
        if let added = delta?.added, !added.isEmpty {
            let descs = added.prefix(8).map { el in
                "\(el.ref.description) [\(el.role.rawValue)] \"\(String(el.label.prefix(40)))\""
            }.joined(separator: ", ")
            let extra = added.count > 8 ? ", +\(added.count - 8) more" : ""
            lines.append("  +\(added.count) elements: \(descs)\(extra)")
        }

        // ~N changed: @eX.label "old" → "new"; @eY.state enabled → disabled
        if let changed = delta?.changed, !changed.isEmpty {
            var parts: [String] = []
            for fc in changed.prefix(8) {
                // Summarize the first field to keep lines short — the JSON
                // payload has the full set.
                if let firstKey = fc.fields.keys.sorted().first,
                   let value = fc.fields[firstKey] {
                    let rendered = renderFieldValue(value.value)
                    parts.append("\(fc.ref.description).\(firstKey) → \(rendered)")
                } else {
                    parts.append(fc.ref.description)
                }
            }
            let descs = parts.joined(separator: "; ")
            let extra = changed.count > 8 ? "; +\(changed.count - 8) more" : ""
            lines.append("  ~\(changed.count) changed: \(descs)\(extra)")
        }

        // -N removed: @eX, @eY
        if let removed = delta?.removedRefs, !removed.isEmpty {
            let descs = removed.prefix(8).map { $0.description }.joined(separator: ", ")
            let extra = removed.count > 8 ? ", +\(removed.count - 8) more" : ""
            lines.append("  -\(removed.count) removed: \(descs)\(extra)")
        }

        if let retained = delta?.retained {
            lines.append("  [retained \(retained.count) refs]")
        }

        // [filter: kept X/Y this tick (±Z)]
        if let stats = delta?.filterStats {
            let diff = stats.keptNow - stats.keptBefore
            let sign = diff >= 0 ? "+" : ""
            lines.append("  [filter: kept \(stats.keptNow) this tick (\(sign)\(diff) vs last)]")
        }

        lines.append("  (\(payload.captureMs)ms)")

        return lines.joined(separator: "\n")
    }

    /// Render a `FieldChange` value concisely — strings get quoted; arrays
    /// and dicts compact. Used by `formatDeltaBody` when summarizing the
    /// first changed field per ref.
    private static func renderFieldValue(_ value: Any) -> String {
        switch value {
        case let s as String: return "\"\(s)\""
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let b as Bool: return String(b)
        case let arr as [Any]:
            let body = arr.map { renderFieldValue($0) }.joined(separator: ",")
            return "[\(body)]"
        case is NSNull: return "nil"
        default: return String(describing: value)
        }
    }

    // MARK: - Rank 1 helpers

    /// Sort elements within a section by filter priority (desc), then by
    /// y-position asc (top-to-bottom) as a stable tiebreaker. Elements
    /// missing a priority entry fall to the bottom of their bucket.
    private static func sortByPriority(
        _ elements: [ScreenElement],
        priorityByRef: [ElementRef: Float]
    ) -> [ScreenElement] {
        elements.sorted { a, b in
            let pa = priorityByRef[a.ref] ?? 0
            let pb = priorityByRef[b.ref] ?? 0
            if pa != pb { return pa > pb }
            let ay = a.clickPoint?.y ?? a.bounds?.midY ?? .greatestFiniteMagnitude
            let by = b.clickPoint?.y ?? b.bounds?.midY ?? .greatestFiniteMagnitude
            return ay < by
        }
    }

    /// Compact one-liner documenting what the filter dropped. Emitted only
    /// when `totalDropped > 0`.
    private static func filterSummaryLine(_ r: FilterResult) -> String {
        var parts: [String] = []
        if r.droppedOutsideWindow > 0 { parts.append("\(r.droppedOutsideWindow) window") }
        if r.droppedTooSmall > 0      { parts.append("\(r.droppedTooSmall) tiny") }
        if r.droppedClipped > 0       { parts.append("\(r.droppedClipped) clipped") }
        if r.droppedOccluded > 0      { parts.append("\(r.droppedOccluded) occluded") }
        if r.droppedDeep > 0          { parts.append("\(r.droppedDeep) deep") }
        return "[filtered: kept \(r.totalKept)/\(r.totalInput) — dropped \(parts.joined(separator: ", "))]"
    }

    // MARK: - Spatial Grouping

    private struct ElementGroup {
        let sectionLabel: String?
        let sectionPath: String?   // Full ancestor path: "Sidebar > Private"
        let elements: [ScreenElement]
    }

    /// Groups elements by their nearest labeled container ancestor.
    /// Elements under the same section header appear together, making the LLM
    /// understand that "Create Page" under "Private" means a private page.
    private static func buildSpatialGroups(
        _ elements: [ScreenElement],
        elementByRef: [ElementRef: ScreenElement],
        allElements: [ScreenElement]
    ) -> [ElementGroup] {

        // Build ancestry path for an element: walk up parentRef chain collecting labeled containers
        func ancestryPath(for el: ScreenElement) -> (key: String, path: String)? {
            var labels: [String] = []
            var current = el
            // Bound the parent-walk like the sibling helpers (ElementFilter
            // uses steps < 24, QueryEngine uses steps < 32). A visited set plus
            // a step cap guarantee termination even if a malformed ScreenMap
            // contains a parentRef cycle (A.parent = B, B.parent = A).
            var visited: Set<ElementRef> = [el.ref]
            var steps = 0
            while let pRef = current.parentRef, let parent = elementByRef[pRef],
                  steps < 32, visited.insert(pRef).inserted {
                steps += 1
                if parent.role.isContainer && !parent.label.isEmpty {
                    labels.append(String(parent.label.prefix(40)))
                }
                current = parent
            }
            guard !labels.isEmpty else { return nil }
            labels.reverse()
            let path = labels.joined(separator: " > ")
            return (key: path, path: path)
        }

        // Group elements by their section path
        var groupedDict: [(key: String?, path: String?, elements: [ScreenElement])] = []
        var keyIndex: [String: Int] = [:]  // path -> index in groupedDict
        var ungrouped: [ScreenElement] = []

        for el in elements {
            if let ancestry = ancestryPath(for: el) {
                if let idx = keyIndex[ancestry.key] {
                    groupedDict[idx].elements.append(el)
                } else {
                    keyIndex[ancestry.key] = groupedDict.count
                    groupedDict.append((key: ancestry.key, path: ancestry.path, elements: [el]))
                }
            } else {
                ungrouped.append(el)
            }
        }

        // Build result: ungrouped first (top-level), then grouped by section
        var result: [ElementGroup] = []

        if !ungrouped.isEmpty {
            result.append(ElementGroup(sectionLabel: nil, sectionPath: nil, elements: ungrouped))
        }

        // Sort groups by the Y position of their first element (top-to-bottom layout order)
        let sorted = groupedDict.sorted { a, b in
            let aY = a.elements.first?.clickPoint?.y ?? 0
            let bY = b.elements.first?.clickPoint?.y ?? 0
            return aY < bY
        }

        for group in sorted {
            // Only emit a section header if there are 2+ elements or the section label
            // adds meaningful context (not just "window" or generic containers)
            let label = group.path ?? group.key ?? ""
            let isGeneric = label.lowercased() == "window" || label.isEmpty
            if group.elements.count >= 2 || !isGeneric {
                result.append(ElementGroup(
                    sectionLabel: isGeneric ? nil : label,
                    sectionPath: group.path,
                    elements: group.elements
                ))
            } else {
                // Single element in a generic group — just add ungrouped
                result.append(ElementGroup(sectionLabel: nil, sectionPath: nil, elements: group.elements))
            }
        }

        return result
    }

    // MARK: - Element Formatting

    private static func formatElement(_ el: ScreenElement, parentLookup: [ElementRef: ScreenElement], skipParent: Bool) -> String {
        var parts: [String] = []

        // Ref
        parts.append(el.ref.description)

        // Role
        parts.append("[\(el.role.rawValue)]")

        // Label
        let label = String(el.label.prefix(80))
        parts.append("\"\(label)\"")

        // Value (if different from label)
        if !el.value.isEmpty && el.value != el.label {
            parts.append("= \"\(String(el.value.prefix(60)))\"")
        }

        // Parent context for disambiguation (skip if already shown in section header)
        if !skipParent, let parentRef = el.parentRef, let parent = parentLookup[parentRef], !parent.label.isEmpty {
            parts.append("in \"\(String(parent.label.prefix(30)))\"")
        }

        // Position
        if let click = el.clickPoint {
            parts.append("(\(Int(click.x)),\(Int(click.y)))")
        }

        // State (only non-default)
        var stateFlags: [String] = []
        if el.state.contains(.disabled)  { stateFlags.append("disabled") }
        if el.state.contains(.focused)   { stateFlags.append("focused") }
        if el.state.contains(.selected)  { stateFlags.append("selected") }
        if el.state.contains(.expanded)  { stateFlags.append("expanded") }
        if el.state.contains(.checked)   { stateFlags.append("checked") }
        if el.state.contains(.password)  { stateFlags.append("password") }
        if !stateFlags.isEmpty {
            parts.append(stateFlags.joined(separator: ","))
        }

        // Actions
        if !el.actions.isEmpty {
            parts.append(el.actions.map { $0.rawValue }.joined(separator: ","))
        }

        // Confidence (only if low)
        if el.confidence < 0.8 {
            parts.append("conf:\(String(format: "%.0f%%", el.confidence * 100))")
        }

        // Source (only if OCR)
        if el.source != .accessibility {
            parts.append("[\(el.source.rawValue)]")
        }

        return parts.joined(separator: " ")
    }
}
