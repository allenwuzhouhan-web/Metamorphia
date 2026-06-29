import CoreGraphics
import Foundation

/// Join AX-derived `ScreenElement`s to browser DOM nodes so the semantic
/// executor can prefer the CDP execution path when a selector is known.
///
/// Runs purely over already-captured data: the AX elements come from
/// `PerceptionPipeline.buildElements`, the DOM nodes from
/// `BrowserDOMFetcher.fetchInteractiveNodes`. No I/O, no AX calls — this
/// type is a pure function and safe to invoke from any concurrency context.
///
/// Matching happens in three passes of decreasing strictness, first-hit-wins
/// per AX element. Tuning notes live next to each pass — the thresholds were
/// picked to be generous on AX-rich pages (GitHub, Gmail, Notion web) while
/// avoiding spurious matches on icon toolbars where adjacent buttons share
/// labels ("⋮", "×").
public enum BrowserDOMJoiner {

    // MARK: - Public API

    /// Annotation returned per matched AX element. The joiner doesn't mutate
    /// the elements — callers rebuild them via `ScreenElement.annotatingDOM`.
    public struct Annotation: Sendable {
        public let domSelector: String
        public let domNodeId: Int?
        public let isEditable: Bool

        public init(domSelector: String, domNodeId: Int?, isEditable: Bool) {
            self.domSelector = domSelector
            self.domNodeId = domNodeId
            self.isEditable = isEditable
        }
    }

    /// Match AX elements in the browser-bundle scope against DOM nodes.
    /// Only elements whose `appBundleID == browserBundleID` are considered;
    /// native-shell chrome (tab bar, window controls) always falls through.
    public static func annotate(
        elements: [ScreenElement],
        nodes: [DOMInteractiveNode],
        viewportOrigin: CGPoint,
        scaleFactor: CGFloat,
        browserBundleID: String
    ) -> [ElementRef: Annotation] {
        guard !elements.isEmpty, !nodes.isEmpty else { return [:] }

        // Pre-compute each DOM node's AX-space rect. CSS pixels map 1:1 to
        // points on macOS even on Retina — `devicePixelRatio` reported by JS
        // concerns the Retina backing store, not the layout coordinate
        // system. `scaleFactor` is forwarded anyway so an edge-case browser
        // that reports viewport coords in pixels can still be normalized.
        let effectiveScale: CGFloat = scaleFactor <= 0 ? 1.0 : 1.0
        _ = effectiveScale // reserved for future divergence
        let axRects: [CGRect] = nodes.map { node in
            let r = node.rect
            return CGRect(
                x: viewportOrigin.x + r.origin.x,
                y: viewportOrigin.y + r.origin.y,
                width: r.size.width,
                height: r.size.height
            )
        }

        let browserElements = elements.filter { el in
            guard el.appBundleID == browserBundleID else { return false }
            // Containers are rarely DOM-joinable — they're the AXGroup
            // wrappers around the web area. Interactive roles are the
            // productive target set.
            return el.role.isInteractive || el.role == .staticText || el.role == .webArea
        }

        var result: [ElementRef: Annotation] = [:]
        var claimedNodeIndices = Set<Int>()

        // Pass 1: strict IoU + role-compatible. The tight ≥ 0.7 IoU guards
        // against matching a button with its containing toolbar by accident.
        for el in browserElements {
            guard result[el.ref] == nil, let axBounds = el.bounds else { continue }
            var bestIdx: Int?
            var bestIoU: CGFloat = 0.7
            for (i, rect) in axRects.enumerated() where !claimedNodeIndices.contains(i) {
                guard rolesCompatible(axRole: el.role, tag: nodes[i].tag, role: nodes[i].role) else { continue }
                let iou = intersectionOverUnion(axBounds, rect)
                if iou > bestIoU {
                    bestIoU = iou
                    bestIdx = i
                }
            }
            if let i = bestIdx {
                let node = nodes[i]
                result[el.ref] = Annotation(
                    domSelector: node.selector,
                    domNodeId: node.nodeId,
                    isEditable: node.isEditable
                )
                claimedNodeIndices.insert(i)
            }
        }

        // Pass 2: center within 12 pt + label Jaccard ≥ 0.5. Catches
        // elements whose AX bounds expanded to include a surrounding
        // padding region (Slack's compose button, Gmail's Send).
        for el in browserElements {
            guard result[el.ref] == nil, let axBounds = el.bounds else { continue }
            let axCenter = CGPoint(x: axBounds.midX, y: axBounds.midY)
            let axTokens = tokens(from: el.label)
            var bestIdx: Int?
            var bestScore: Float = 0
            for (i, rect) in axRects.enumerated() where !claimedNodeIndices.contains(i) {
                let dCenter = hypot(rect.midX - axCenter.x, rect.midY - axCenter.y)
                guard dCenter <= 12 else { continue }
                let candidateLabel = nodes[i].aria ?? nodes[i].text
                let jaccard = labelJaccard(axTokens, tokens(from: candidateLabel))
                if jaccard >= 0.5 && jaccard > bestScore {
                    bestScore = jaccard
                    bestIdx = i
                }
            }
            if let i = bestIdx {
                let node = nodes[i]
                result[el.ref] = Annotation(
                    domSelector: node.selector,
                    domNodeId: node.nodeId,
                    isEditable: node.isEditable
                )
                claimedNodeIndices.insert(i)
            }
        }

        // Pass 3: fuzzy substring containment within 4 pt-padded AX bounds.
        // Last-ditch — catches elements whose label was captured from AX
        // description while the DOM carries only visible text, or vice versa.
        for el in browserElements {
            guard result[el.ref] == nil, let axBounds = el.bounds else { continue }
            let padded = axBounds.insetBy(dx: -4, dy: -4)
            for (i, rect) in axRects.enumerated() where !claimedNodeIndices.contains(i) {
                guard padded.intersects(rect) else { continue }
                let axLabelLower = el.label.lowercased()
                let nodeText = (nodes[i].aria ?? nodes[i].text).lowercased()
                guard axLabelLower.count >= 3 || nodeText.count >= 3 else { continue }
                if axLabelLower.contains(nodeText) || nodeText.contains(axLabelLower) {
                    let node = nodes[i]
                    result[el.ref] = Annotation(
                        domSelector: node.selector,
                        domNodeId: node.nodeId,
                        isEditable: node.isEditable
                    )
                    claimedNodeIndices.insert(i)
                    break
                }
            }
        }
        return result
    }

    /// Convenience that also returns a fresh `[ScreenElement]` with the
    /// annotations applied. Kept separate from `annotate` so callers that
    /// want to log the match rate can observe the raw dictionary too.
    public static func annotateInPlace(
        elements: [ScreenElement],
        nodes: [DOMInteractiveNode],
        viewportOrigin: CGPoint,
        scaleFactor: CGFloat,
        browserBundleID: String
    ) -> [ScreenElement] {
        let matches = annotate(
            elements: elements,
            nodes: nodes,
            viewportOrigin: viewportOrigin,
            scaleFactor: scaleFactor,
            browserBundleID: browserBundleID
        )
        guard !matches.isEmpty else { return elements }
        return elements.map { el in
            guard let annotation = matches[el.ref] else { return el }
            return el.annotatingDOM(
                selector: annotation.domSelector,
                nodeId: annotation.domNodeId
            )
        }
    }

    /// Locate the browser window's web-area origin in AX-space so the joiner
    /// can translate viewport-relative DOM rects to screen coordinates.
    /// Falls back to the focused window's bounds minus a 28 pt tab-bar
    /// offset when no `AXWebArea` element was captured — better than
    /// nothing on browsers whose AX tree hides the web area.
    public static func viewportOrigin(
        for browserBundleID: String,
        in elements: [ScreenElement],
        focusedWindowBounds: CGRect?
    ) -> CGPoint? {
        let webArea = elements.first(where: { el in
            el.role == .webArea && el.appBundleID == browserBundleID && el.bounds != nil
        })
        if let bounds = webArea?.bounds {
            return CGPoint(x: bounds.origin.x, y: bounds.origin.y)
        }
        if let frame = focusedWindowBounds {
            return CGPoint(x: frame.origin.x, y: frame.origin.y + 28)
        }
        return nil
    }

    /// One-shot pipeline helper: given a ScreenMap that already has a
    /// `browserDOM` capture attached, fetch interactive nodes for the
    /// current tab, resolve the viewport origin from the AX tree, run the
    /// three-pass matcher, and return a new element list with
    /// `domSelector`/`domNodeId` annotations applied. No-op (returns the
    /// original elements) when the frontmost app isn't a browser or when
    /// no nodes / no viewport origin can be resolved.
    ///
    /// Runs in the perception pipeline's hot path per tick. Two safety
    /// properties keep it cheap: (a) `fetchInteractiveNodes`'s fingerprint
    /// cache returns the prior enumeration on an unchanged tab after only a
    /// cheap URL/title probe, so the full-document enumeration JS doesn't
    /// re-run every tick; (b) the three-pass matcher is bounded O(n·m) on
    /// small n,m — a typical page has 30-80 interactive elements.
    public static func enrichElements(
        in elements: [ScreenElement],
        focusedApp: AppInfo,
        focusedWindowBounds: CGRect?,
        fetcher: BrowserDOMFetcher = .shared
    ) async -> [ScreenElement] {
        guard let bundleID = focusedApp.bundleID,
              BrowserDOMFetcher.isBrowserBundle(bundleID) else {
            return elements
        }
        guard let enumeration = await fetcher.fetchInteractiveNodes(focusedApp: focusedApp),
              !enumeration.nodes.isEmpty else {
            return elements
        }
        guard let origin = viewportOrigin(
            for: bundleID,
            in: elements,
            focusedWindowBounds: focusedWindowBounds
        ) else { return elements }
        return annotateInPlace(
            elements: elements,
            nodes: enumeration.nodes,
            viewportOrigin: origin,
            scaleFactor: enumeration.scaleFactor,
            browserBundleID: bundleID
        )
    }

    // MARK: - Matching helpers

    private static func rolesCompatible(
        axRole: ElementRole,
        tag: String,
        role: String?
    ) -> Bool {
        let tagLower = tag.lowercased()
        let roleLower = role?.lowercased() ?? ""
        switch axRole {
        case .button:
            return tagLower == "button"
                || roleLower == "button"
                || (tagLower == "input" && roleLower.isEmpty) // type=submit/reset
                || tagLower == "summary"
        case .link:
            return tagLower == "a" || roleLower == "link"
        case .textField, .textArea:
            return tagLower == "input"
                || tagLower == "textarea"
                || roleLower == "textbox"
                || roleLower == "searchbox"
        case .checkbox:
            return (tagLower == "input" && roleLower == "") || roleLower == "checkbox"
        case .radioButton:
            return roleLower == "radio"
        case .popUpButton, .comboBox:
            return tagLower == "select" || roleLower == "combobox"
        case .tab:
            return roleLower == "tab"
        case .menuItem:
            return roleLower == "menuitem"
        case .webArea:
            // The web area itself never matches a DOM node (it's the root).
            return false
        case .staticText:
            // Labels sometimes appear as `<label>` / `<span>` — accept loose matches.
            return tagLower == "label" || tagLower == "span" || tagLower == "p"
        default:
            return false
        }
    }

    private static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    private static func tokens(from raw: String) -> Set<String> {
        let lower = raw.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        let pieces = lower.components(separatedBy: separators)
        return Set(pieces.filter { $0.count > 2 })
    }

    private static func labelJaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Float {
        if lhs.isEmpty && rhs.isEmpty { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return Float(intersection) / Float(max(1, union))
    }
}
