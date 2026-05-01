import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

/// Reads the full UI tree of any running application via Accessibility APIs.
/// Progressive depth: tries shallow (6) first, deepens to 12 if insufficient.
///
/// **Viewport-focused traversal (Rank 5)**: When a viewport rect is provided (or
/// auto-derived from the focused window's bounds), the traversal skips elements
/// whose bounds fall completely outside the viewport — with a generous 800px
/// slack so partially-visible scroll regions still contribute. Interactive
/// elements are always kept (virtualized-list rows sometimes report zero
/// bounds), and containers with unknown bounds are preserved so their children
/// can be evaluated individually.
public enum AXReader {

    // MARK: - Cache

    private static let cacheLock = NSLock()
    private static var cachedResult: AXReadResult?
    private static var cacheTimestamp: Date = .distantPast
    private static var cachePID: pid_t = 0
    private static var cachedViewport: CGRect?
    public static var cacheTTL: TimeInterval = 0.15

    public static func invalidateCache() {
        cacheLock.lock()
        cachedResult = nil
        cachedViewport = nil
        cacheLock.unlock()
    }

    // MARK: - Raw Element

    public struct RawElement {
        public let role: String
        public let subrole: String
        public let title: String
        public let value: String
        public let description: String
        public let label: String
        public let identifier: String
        public let position: CGPoint?
        public let size: CGSize?
        public let depth: Int
        public let state: ElementState
        public let actions: [ElementAction]

        public init(role: String, subrole: String, title: String, value: String, description: String, label: String, identifier: String, position: CGPoint?, size: CGSize?, depth: Int, state: ElementState, actions: [ElementAction]) {
            self.role = role
            self.subrole = subrole
            self.title = title
            self.value = value
            self.description = description
            self.label = label
            self.identifier = identifier
            self.position = position
            self.size = size
            self.depth = depth
            self.state = state
            self.actions = actions
        }
    }

    public struct AXReadResult {
        public let appName: String
        public let appBundleID: String?
        public let pid: pid_t
        public let windowTitle: String
        public let elements: [RawElement]
        public let timestamp: Date

        public init(appName: String, appBundleID: String?, pid: pid_t, windowTitle: String, elements: [RawElement], timestamp: Date) {
            self.appName = appName
            self.appBundleID = appBundleID
            self.pid = pid
            self.windowTitle = windowTitle
            self.elements = elements
            self.timestamp = timestamp
        }
    }

    // MARK: - Read

    /// Read the frontmost app's UI tree. Returns cached result if within TTL.
    ///
    /// - Parameter viewport: When non-nil, elements fully outside this rect (by
    ///   more than 800 px in every direction) are skipped. When nil, the
    ///   focused-window bounds are used automatically; if the window has no
    ///   bounds either, falls back to unfiltered traversal.
    public static func readFrontmostApp(viewport: CGRect? = nil) -> AXReadResult? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        cacheLock.lock()
        if pid == cachePID, let cached = cachedResult,
           viewportsEqual(viewport, cachedViewport),
           Date().timeIntervalSince(cacheTimestamp) < cacheTTL {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = readApp(
            pid: pid,
            name: frontApp.localizedName ?? "Unknown",
            bundleID: frontApp.bundleIdentifier,
            viewport: viewport
        )

        if let result = result {
            cacheLock.lock()
            cachedResult = result
            cacheTimestamp = Date()
            cachePID = pid
            // Cache the EFFECTIVE viewport used — either the explicit one or
            // the one auto-derived inside readApp. We re-derive here so the
            // cache key matches the next call with the same `viewport` arg.
            cachedViewport = viewport
            cacheLock.unlock()
        }
        return result
    }

    /// Read a specific app by PID.
    ///
    /// - Parameter viewport: Optional viewport rect in screen coordinates. When
    ///   nil, auto-derives from the focused window's bounds. When both are
    ///   unavailable, no viewport filtering is applied.
    /// - Parameter fromObserverCallback: When `true`, bypasses the 150 ms cache
    ///   entirely (both read and write). Observer callbacks imply "state just
    ///   changed" — caching would re-serve stale data. Default is `false`,
    ///   which preserves existing behavior unchanged.
    public static func readApp(pid: pid_t, name: String, bundleID: String?, viewport: CGRect? = nil, fromObserverCallback: Bool = false) -> AXReadResult? {
        if fromObserverCallback {
            return readAppUncached(pid: pid, name: name, bundleID: bundleID, viewport: viewport)
        }
        let appElement = AXUIElementCreateApplication(pid)

        guard let windowElement = AXAttributes.getFocusedWindow(appElement) else {
            return nil
        }

        let windowTitle = AXAttributes.getTitle(windowElement) ?? ""

        // Auto-derive viewport from the focused window bounds when not provided.
        let effectiveViewport: CGRect?
        if let viewport = viewport {
            effectiveViewport = viewport
        } else if let pos = AXAttributes.getPosition(windowElement),
                  let size = AXAttributes.getSize(windowElement),
                  size.width > 0, size.height > 0 {
            effectiveViewport = CGRect(origin: pos, size: size)
        } else {
            // No bounds on window — fall through to unfiltered traversal.
            effectiveViewport = nil
        }

        // Progressive depth: shallow first, deepen if insufficient
        var elements: [RawElement] = []
        var visibleCount = 0
        traverseElement(
            windowElement,
            depth: 0,
            maxDepth: 6,
            viewport: effectiveViewport,
            elements: &elements,
            visibleCount: &visibleCount
        )

        let interactiveCount = elements.filter { ElementRole.from(axRole: $0.role).isInteractive }.count
        if interactiveCount < 5 {
            elements.removeAll()
            visibleCount = 0
            traverseElement(
                windowElement,
                depth: 0,
                maxDepth: 12,
                viewport: effectiveViewport,
                elements: &elements,
                visibleCount: &visibleCount
            )
        }

        return AXReadResult(
            appName: name,
            appBundleID: bundleID,
            pid: pid,
            windowTitle: windowTitle,
            elements: elements,
            timestamp: Date()
        )
    }

    /// Core uncached read. Called by `readApp(fromObserverCallback: true)` to
    /// bypass the NSLock-protected cache on both read and write paths.
    /// Identical traversal logic to `readApp`; factored out to avoid duplication.
    private static func readAppUncached(pid: pid_t, name: String, bundleID: String?, viewport: CGRect?) -> AXReadResult? {
        let appElement = AXUIElementCreateApplication(pid)

        guard let windowElement = AXAttributes.getFocusedWindow(appElement) else {
            return nil
        }

        let windowTitle = AXAttributes.getTitle(windowElement) ?? ""

        let effectiveViewport: CGRect?
        if let viewport = viewport {
            effectiveViewport = viewport
        } else if let pos = AXAttributes.getPosition(windowElement),
                  let size = AXAttributes.getSize(windowElement),
                  size.width > 0, size.height > 0 {
            effectiveViewport = CGRect(origin: pos, size: size)
        } else {
            effectiveViewport = nil
        }

        var elements: [RawElement] = []
        var visibleCount = 0
        traverseElement(
            windowElement,
            depth: 0,
            maxDepth: 6,
            viewport: effectiveViewport,
            elements: &elements,
            visibleCount: &visibleCount
        )

        let interactiveCount = elements.filter { ElementRole.from(axRole: $0.role).isInteractive }.count
        if interactiveCount < 5 {
            elements.removeAll()
            visibleCount = 0
            traverseElement(
                windowElement,
                depth: 0,
                maxDepth: 12,
                viewport: effectiveViewport,
                elements: &elements,
                visibleCount: &visibleCount
            )
        }

        return AXReadResult(
            appName: name,
            appBundleID: bundleID,
            pid: pid,
            windowTitle: windowTitle,
            elements: elements,
            timestamp: Date()
        )
    }

    // MARK: - Traversal

    internal static let maxElements = 1000
    internal static let maxVisibleElements = 500

    /// Slack (in px) around the viewport. Elements whose bounds lie completely
    /// outside the expanded rect are dropped, with the assumption that
    /// off-screen content within one "scroll height" (~800 px) might slide in
    /// shortly and is worth keeping for subtree recursion.
    internal static let viewportSlack: CGFloat = 800

    /// Decision emitted by `shouldTraverse` for a single AX element. The
    /// traversal loop translates this into (record?, recurse?) behavior.
    internal enum TraverseDecision: Equatable {
        case keepAndRecord   // record this element and recurse into children
        case recordOnly      // record but don't recurse (e.g. secure text field)
        case recurseOnly     // skip recording but recurse (deep-empty-container)
        case skip            // drop entirely
    }

    /// Pure filter helper — unit-testable without a live AX tree.
    ///
    /// - Returns: Whether to record the element, recurse into it, both, or
    ///   neither. See `TraverseDecision` cases for semantics.
    internal static func shouldTraverse(
        elementBounds: CGRect?,
        role: ElementRole,
        viewport: CGRect?,
        depth: Int,
        hasContent: Bool = true
    ) -> TraverseDecision {
        // No viewport → no filtering. Keep record/recurse based on content/role.
        guard let viewport = viewport else {
            if depth > 4 && !role.isInteractive && !hasContent {
                return .recurseOnly
            }
            if hasContent || role.isInteractive {
                return .keepAndRecord
            }
            // No content, non-interactive, shallow depth → still recurse (may
            // have interactive descendants), just don't record the container.
            return .recurseOnly
        }

        // Interactive elements are ALWAYS kept — virtualized-list rows, hidden
        // menu items, collapsed toolbars etc. frequently report bounds of
        // (0,0,0,0) or clipped rects while still being the AX click target.
        if role.isInteractive {
            return .keepAndRecord
        }

        // Unknown bounds: can't filter, preserve to be safe.
        guard let bounds = elementBounds else {
            // Non-interactive, bounds unknown. Apply the deep-empty-container
            // optimization if applicable; otherwise keepAndRecord.
            if depth > 4 && !hasContent {
                return .recurseOnly
            }
            return hasContent ? .keepAndRecord : .recurseOnly
        }

        // Within viewport (or overlapping it): keep and recurse.
        if bounds.intersects(viewport) {
            if depth > 4 && !hasContent {
                return .recurseOnly
            }
            return hasContent ? .keepAndRecord : .recurseOnly
        }

        // Fully outside viewport. Check slack: if the element is within 800 px
        // in every direction of the viewport, its subtree may still contain
        // visible children — recurse but don't record the container itself.
        if isNearViewport(bounds: bounds, viewport: viewport, slack: viewportSlack) {
            return .recurseOnly
        }

        // Far from viewport — safe to skip.
        return .skip
    }

    /// True when `bounds` is within `slack` pixels of `viewport` in every
    /// direction (i.e. horizontal AND vertical gap are both ≤ slack).
    private static func isNearViewport(bounds: CGRect, viewport: CGRect, slack: CGFloat) -> Bool {
        let dx = max(0, max(viewport.minX - bounds.maxX, bounds.minX - viewport.maxX))
        let dy = max(0, max(viewport.minY - bounds.maxY, bounds.minY - viewport.maxY))
        return dx <= slack && dy <= slack
    }

    /// Cache-key viewport comparison (treats nil == nil as equal).
    private static func viewportsEqual(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs == rhs
        default: return false
        }
    }

    private static func traverseElement(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        viewport: CGRect?,
        elements: inout [RawElement],
        visibleCount: inout Int
    ) {
        guard depth < maxDepth,
              elements.count < maxElements,
              visibleCount < maxVisibleElements else { return }

        let role = AXAttributes.getRole(element) ?? ""
        let subrole = AXAttributes.getSubrole(element) ?? ""

        // Skip secure text fields entirely — don't expose passwords.
        // Preserved from pre-Rank-5 semantics: record the field (with empty
        // value) and the .password state flag, but don't recurse into it. The
        // viewport filter is intentionally NOT applied here — password fields
        // are always rendered where the user can see them, and if AX reports
        // them off-screen it's almost certainly a virtualized form we still
        // want to expose.
        if subrole == "AXSecureTextField" {
            let position = AXAttributes.getPosition(element)
            let size = AXAttributes.getSize(element)
            var state = AXAttributes.buildState(element, subrole: subrole)
            state.insert(.password)
            let actions = AXAttributes.getActions(element).compactMap { ElementAction.from(axAction: $0) }

            elements.append(RawElement(
                role: role, subrole: subrole,
                title: AXAttributes.getTitle(element) ?? "Password",
                value: "", // Never expose password values
                description: AXAttributes.getDescription(element) ?? "",
                label: AXAttributes.getLabel(element) ?? "",
                identifier: AXAttributes.getIdentifier(element) ?? "",
                position: position, size: size, depth: depth,
                state: state, actions: actions
            ))
            if let pos = position, let sz = size,
               let vp = viewport,
               CGRect(origin: pos, size: sz).intersects(vp) {
                visibleCount += 1
            } else if viewport == nil {
                visibleCount += 1
            }
            return
        }

        let typedRole = ElementRole.from(axRole: role)

        // Read geometry BEFORE content so shouldTraverse can evaluate viewport.
        let position = AXAttributes.getPosition(element)
        let size = AXAttributes.getSize(element)
        let elementBounds: CGRect?
        if let pos = position, let sz = size {
            elementBounds = CGRect(origin: pos, size: sz)
        } else {
            elementBounds = nil
        }

        // We need a preliminary content check to feed into shouldTraverse, but
        // only the cheap string attributes. Read them once and reuse below.
        let title = AXAttributes.getTitle(element) ?? ""
        let value = AXAttributes.getValue(element) ?? ""
        let description = AXAttributes.getDescription(element) ?? ""
        let label = AXAttributes.getLabel(element) ?? ""
        let identifier = AXAttributes.getIdentifier(element) ?? ""
        let hasContent = !title.isEmpty || !value.isEmpty || !description.isEmpty || !label.isEmpty

        let decision = shouldTraverse(
            elementBounds: elementBounds,
            role: typedRole,
            viewport: viewport,
            depth: depth,
            hasContent: hasContent
        )

        switch decision {
        case .skip:
            return

        case .recurseOnly:
            recurseChildren(
                element,
                depth: depth,
                maxDepth: maxDepth,
                viewport: viewport,
                elements: &elements,
                visibleCount: &visibleCount
            )

        case .recordOnly, .keepAndRecord:
            let state = AXAttributes.buildState(element, subrole: subrole)
            let actions = AXAttributes.getActions(element).compactMap { ElementAction.from(axAction: $0) }

            elements.append(RawElement(
                role: role, subrole: subrole,
                title: title,
                value: String(value.prefix(500)),
                description: description,
                label: label,
                identifier: identifier,
                position: position, size: size, depth: depth,
                state: state, actions: actions
            ))

            // Count toward the "visible" budget only when the element actually
            // overlaps the viewport (or when no viewport is active). This is
            // what makes maxVisibleElements a tight budget on what the LLM
            // ultimately sees.
            if let bounds = elementBounds, let vp = viewport {
                if bounds.intersects(vp) { visibleCount += 1 }
            } else {
                visibleCount += 1
            }

            if decision == .keepAndRecord {
                recurseChildren(
                    element,
                    depth: depth,
                    maxDepth: maxDepth,
                    viewport: viewport,
                    elements: &elements,
                    visibleCount: &visibleCount
                )
            }
        }
    }

    private static func recurseChildren(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        viewport: CGRect?,
        elements: inout [RawElement],
        visibleCount: inout Int
    ) {
        guard let children = AXAttributes.getChildren(element) else { return }
        for child in children {
            guard elements.count < maxElements,
                  visibleCount < maxVisibleElements else { return }
            traverseElement(
                child,
                depth: depth + 1,
                maxDepth: maxDepth,
                viewport: viewport,
                elements: &elements,
                visibleCount: &visibleCount
            )
        }
    }

    // MARK: - Test Helpers

    /// Apply viewport filtering to an array of pre-built `RawElement`s. Used
    /// by unit tests that want to exercise the filter/cap logic without a
    /// live AX hierarchy. The filter honors the same `shouldTraverse` rules
    /// and the `maxVisibleElements` cap.
    ///
    /// Note: This is a flat-list simulation. Real traversal is tree-aware
    /// (`.recurseOnly` still descends), but for integration-style cap tests
    /// a flat filter is the cleanest API.
    internal static func filterRawElementsByViewport(
        _ input: [RawElement],
        viewport: CGRect?
    ) -> [RawElement] {
        var output: [RawElement] = []
        var visibleCount = 0
        for raw in input {
            guard output.count < maxElements,
                  visibleCount < maxVisibleElements else { break }

            let role = ElementRole.from(axRole: raw.role)
            let bounds: CGRect?
            if let pos = raw.position, let sz = raw.size {
                bounds = CGRect(origin: pos, size: sz)
            } else {
                bounds = nil
            }
            let hasContent = !raw.title.isEmpty || !raw.value.isEmpty
                || !raw.description.isEmpty || !raw.label.isEmpty

            let decision = shouldTraverse(
                elementBounds: bounds,
                role: role,
                viewport: viewport,
                depth: raw.depth,
                hasContent: hasContent
            )

            switch decision {
            case .skip, .recurseOnly:
                continue
            case .recordOnly, .keepAndRecord:
                output.append(raw)
                if let b = bounds, let vp = viewport {
                    if b.intersects(vp) { visibleCount += 1 }
                } else {
                    visibleCount += 1
                }
            }
        }
        return output
    }
}
