import Foundation
import ApplicationServices
import AppKit

/// Detects off-screen content: scrollable areas with hidden items, tab counts, hidden submenus.
public enum OffScreenDetector {

    // MARK: - Off-Screen Info

    /// Summary of content beyond the visible viewport.
    public struct OffScreenInfo: Sendable {
        public let scrollAreas: [ScrollAreaInfo]
        public let totalHiddenItems: Int
        public let hint: String?

        public init(scrollAreas: [ScrollAreaInfo], totalHiddenItems: Int, hint: String?) {
            self.scrollAreas = scrollAreas
            self.totalHiddenItems = totalHiddenItems
            self.hint = hint
        }
    }

    /// Info about a single scrollable region.
    public struct ScrollAreaInfo: Sendable {
        public let elementRef: ElementRef?
        public let label: String
        public let visibleChildren: Int
        public let totalChildren: Int
        public let canScrollDown: Bool
        public let canScrollUp: Bool
        public let canScrollRight: Bool
        public let canScrollLeft: Bool
        public let scrollPercentY: Float?    // 0.0 = top, 1.0 = bottom

        public init(
            elementRef: ElementRef?, label: String,
            visibleChildren: Int, totalChildren: Int,
            canScrollDown: Bool, canScrollUp: Bool,
            canScrollRight: Bool, canScrollLeft: Bool,
            scrollPercentY: Float?
        ) {
            self.elementRef = elementRef
            self.label = label
            self.visibleChildren = visibleChildren
            self.totalChildren = totalChildren
            self.canScrollDown = canScrollDown
            self.canScrollUp = canScrollUp
            self.canScrollRight = canScrollRight
            self.canScrollLeft = canScrollLeft
            self.scrollPercentY = scrollPercentY
        }

        public var hiddenCount: Int { max(0, totalChildren - visibleChildren) }
    }

    // MARK: - Detection

    /// Detect off-screen content from the current AX tree of the frontmost app.
    public static func detect() -> OffScreenInfo {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return OffScreenInfo(scrollAreas: [], totalHiddenItems: 0, hint: nil)
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        guard let window = AXAttributes.getFocusedWindow(appElement) else {
            return OffScreenInfo(scrollAreas: [], totalHiddenItems: 0, hint: nil)
        }

        var scrollAreas: [ScrollAreaInfo] = []
        findScrollAreas(element: window, depth: 0, maxDepth: 8, results: &scrollAreas)

        // Also check tab groups for total tab count
        var tabInfo: [ScrollAreaInfo] = []
        findTabGroups(element: window, depth: 0, maxDepth: 6, results: &tabInfo)
        scrollAreas.append(contentsOf: tabInfo)

        let totalHidden = scrollAreas.reduce(0) { $0 + $1.hiddenCount }

        // Build hint string
        let hint = buildHint(scrollAreas: scrollAreas, totalHidden: totalHidden)

        return OffScreenInfo(scrollAreas: scrollAreas, totalHiddenItems: totalHidden, hint: hint)
    }

    /// Detect off-screen info and annotate elements in a ScreenMap.
    public static func annotate(elements: inout [ScreenElement], info: OffScreenInfo) {
        // Mark elements that are off-screen based on scroll area bounds
        // (Elements that exist in the AX tree but are outside visible scroll bounds)
        // For now, this is a no-op — the AX tree typically only returns visible elements.
        // The real value is in the offScreenHint metadata.
    }

    // MARK: - Scroll Area Discovery

    private static func findScrollAreas(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        results: inout [ScrollAreaInfo]
    ) {
        guard depth < maxDepth, results.count < 10 else { return }

        let role = AXAttributes.getRole(element) ?? ""

        if role == "AXScrollArea" {
            if let info = analyzeScrollArea(element) {
                results.append(info)
            }
        }

        // Also check AXTable, AXOutline, AXList — they have row counts
        if role == "AXTable" || role == "AXOutline" || role == "AXList" {
            if let info = analyzeListContainer(element, role: role) {
                results.append(info)
            }
        }

        // Recurse children
        guard let children = AXAttributes.getChildren(element) else { return }
        for child in children {
            findScrollAreas(element: child, depth: depth + 1, maxDepth: maxDepth, results: &results)
        }
    }

    private static func analyzeScrollArea(_ element: AXUIElement) -> ScrollAreaInfo? {
        let label = AXAttributes.bestLabel(element)

        // Get visible bounds
        guard let _ = AXAttributes.getPosition(element),
              let size = AXAttributes.getSize(element) else { return nil }

        // Count direct children
        let children = AXAttributes.getChildren(element) ?? []
        let childCount = children.count

        // Try to get the content area's actual size via the first child (usually the content view)
        var totalChildren = childCount
        var canScrollDown = false
        var canScrollUp = false
        var canScrollRight = false
        var canScrollLeft = false
        var scrollPercent: Float? = nil

        // Check for scroll bars
        for child in children {
            let childRole = AXAttributes.getRole(child) ?? ""
            if childRole == "AXScrollBar" {
                let orientation = AXAttributes.getString(child, "AXOrientation") ?? ""
                if let value = AXAttributes.getString(child, kAXValueAttribute),
                   let floatVal = Float(value) {
                    if orientation == "AXVerticalOrientation" {
                        scrollPercent = floatVal
                        canScrollDown = floatVal < 0.95
                        canScrollUp = floatVal > 0.05
                    } else if orientation == "AXHorizontalOrientation" {
                        canScrollRight = floatVal < 0.95
                        canScrollLeft = floatVal > 0.05
                    }
                }
            }
        }

        // If there are scroll bars, the content extends beyond visible bounds
        // Try to count the actual items in the content area
        for child in children {
            let childRole = AXAttributes.getRole(child) ?? ""
            if childRole != "AXScrollBar" {
                // This is likely the content view — count its children
                let contentChildren = AXAttributes.getChildren(child) ?? []
                if contentChildren.count > 0 {
                    totalChildren = contentChildren.count
                }
            }
        }

        // Estimate visible children based on viewport
        let visibleChildren: Int
        if totalChildren > 0 && (canScrollDown || canScrollUp) {
            // Rough estimate: visible portion based on scroll area height vs item height
            visibleChildren = min(totalChildren, max(1, Int(size.height / 30))) // assume ~30px per item
        } else {
            visibleChildren = totalChildren
        }

        // Only report if there's actually hidden content
        guard canScrollDown || canScrollUp || canScrollLeft || canScrollRight else { return nil }

        return ScrollAreaInfo(
            elementRef: nil,
            label: label.isEmpty ? "Scroll area" : label,
            visibleChildren: visibleChildren,
            totalChildren: totalChildren,
            canScrollDown: canScrollDown,
            canScrollUp: canScrollUp,
            canScrollRight: canScrollRight,
            canScrollLeft: canScrollLeft,
            scrollPercentY: scrollPercent
        )
    }

    // MARK: - List/Table Analysis

    private static func analyzeListContainer(_ element: AXUIElement, role: String) -> ScrollAreaInfo? {
        let label = AXAttributes.bestLabel(element)

        // AXTable and AXOutline expose row counts
        var rowCount: CFTypeRef?
        let hasRowCount = AXUIElementCopyAttributeValue(element, "AXRows" as CFString, &rowCount) == .success

        let children = AXAttributes.getChildren(element) ?? []

        // Get visible row count
        var visibleRowCount: CFTypeRef?
        let hasVisibleRows = AXUIElementCopyAttributeValue(element, "AXVisibleRows" as CFString, &visibleRowCount) == .success

        let total: Int
        let visible: Int

        if hasRowCount, let rows = rowCount as? [AXUIElement] {
            total = rows.count
            if hasVisibleRows, let visRows = visibleRowCount as? [AXUIElement] {
                visible = visRows.count
            } else {
                visible = min(total, children.count)
            }
        } else {
            total = children.count
            visible = total
        }

        guard total > visible else { return nil }

        let typeName: String
        switch role {
        case "AXTable": typeName = "Table"
        case "AXOutline": typeName = "Outline"
        case "AXList": typeName = "List"
        default: typeName = "Container"
        }

        return ScrollAreaInfo(
            elementRef: nil,
            label: label.isEmpty ? typeName : label,
            visibleChildren: visible,
            totalChildren: total,
            canScrollDown: true,
            canScrollUp: false,
            canScrollRight: false,
            canScrollLeft: false,
            scrollPercentY: nil
        )
    }

    // MARK: - Tab Group Analysis

    private static func findTabGroups(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        results: inout [ScrollAreaInfo]
    ) {
        guard depth < maxDepth else { return }

        let role = AXAttributes.getRole(element) ?? ""
        if role == "AXTabGroup" {
            let children = AXAttributes.getChildren(element) ?? []
            let tabCount = children.filter { AXAttributes.getRole($0) == "AXTab" }.count
            // Visible tabs might be fewer than total if tabs overflow
            let label = AXAttributes.bestLabel(element)
            if tabCount > 0 {
                results.append(ScrollAreaInfo(
                    elementRef: nil,
                    label: label.isEmpty ? "Tab group" : label,
                    visibleChildren: tabCount,
                    totalChildren: tabCount,
                    canScrollDown: false,
                    canScrollUp: false,
                    canScrollRight: false,
                    canScrollLeft: false,
                    scrollPercentY: nil
                ))
            }
        }

        guard let children = AXAttributes.getChildren(element) else { return }
        for child in children {
            findTabGroups(element: child, depth: depth + 1, maxDepth: maxDepth, results: &results)
        }
    }

    // MARK: - Hint Builder

    private static func buildHint(scrollAreas: [ScrollAreaInfo], totalHidden: Int) -> String? {
        guard totalHidden > 0 || scrollAreas.contains(where: { $0.canScrollDown || $0.canScrollRight }) else {
            return nil
        }

        var parts: [String] = []

        for area in scrollAreas {
            if area.hiddenCount > 0 {
                let direction = area.canScrollDown ? "below" : (area.canScrollRight ? "to the right" : "hidden")
                parts.append("\(area.hiddenCount) more items \(direction) in \(area.label)")
            } else if area.canScrollDown {
                parts.append("More content below in \(area.label)")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
