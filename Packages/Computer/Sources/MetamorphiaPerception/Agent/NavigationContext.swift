import Foundation
import ApplicationServices
import AppKit

/// Computes rich breadcrumb navigation path from toolbar, tab bar, sidebar, and window title.
/// e.g., ["Safari", "GitHub - Computer", "Code tab", "Sources/ folder"]
public enum NavigationContext {

    /// Build a breadcrumb path from the current app state.
    public static func build(
        appName: String,
        windowTitle: String,
        elements: [ScreenElement]
    ) -> [String] {
        var breadcrumb: [String] = [appName]

        // Window title (skip if it's just the app name repeated)
        if !windowTitle.isEmpty && windowTitle != appName {
            breadcrumb.append(windowTitle)
        }

        // Active tab (selected radio button or tab in a tab group)
        if let activeTab = findActiveTab(in: elements) {
            // Only add if not already captured in window title
            if !windowTitle.lowercased().contains(activeTab.lowercased()) {
                breadcrumb.append(activeTab)
            }
        }

        // Sidebar selection (selected item in an outline/list)
        if let sidebarSelection = findSidebarSelection(in: elements) {
            breadcrumb.append(sidebarSelection)
        }

        // Toolbar path components (some apps show path bars)
        let pathComponents = findPathBar(in: elements)
        breadcrumb.append(contentsOf: pathComponents)

        return breadcrumb
    }

    /// Build navigation from raw AX tree (more detailed than ScreenElement-based).
    public static func buildFromAX() -> [String]? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = frontApp.localizedName ?? "Unknown"
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        guard let window = AXAttributes.getFocusedWindow(appElement) else { return nil }
        let windowTitle = AXAttributes.getTitle(window) ?? ""

        var breadcrumb: [String] = [appName]
        if !windowTitle.isEmpty && windowTitle != appName {
            breadcrumb.append(windowTitle)
        }

        // Deep search for navigation-relevant elements
        var navElements: [NavElement] = []
        findNavElements(element: window, depth: 0, maxDepth: 6, results: &navElements)

        // Active tab
        if let tab = navElements.first(where: { $0.type == .activeTab }) {
            if !windowTitle.lowercased().contains(tab.label.lowercased()) {
                breadcrumb.append(tab.label)
            }
        }

        // Sidebar selection
        if let sidebar = navElements.first(where: { $0.type == .sidebarSelection }) {
            breadcrumb.append(sidebar.label)
        }

        // Segmented control selection
        if let segment = navElements.first(where: { $0.type == .segmentSelection }) {
            breadcrumb.append(segment.label)
        }

        return breadcrumb.count > 1 ? breadcrumb : nil
    }

    // MARK: - Element-Based Finders

    private static func findActiveTab(in elements: [ScreenElement]) -> String? {
        // Look for selected tab or radio button in a tab bar
        for el in elements {
            if (el.role == .tab || el.role == .radioButton) && el.state.contains(.selected) {
                let label = el.label.trimmingCharacters(in: .whitespaces)
                if !label.isEmpty {
                    return label
                }
            }
        }
        return nil
    }

    private static func findSidebarSelection(in elements: [ScreenElement]) -> String? {
        // Look for selected items in outlines/lists (typically sidebars are on the left)
        for el in elements {
            guard el.state.contains(.selected),
                  !el.label.isEmpty,
                  let bounds = el.bounds else { continue }

            // Heuristic: sidebar items are usually on the left third of the screen
            if bounds.origin.x < 400 && (el.role == .staticText || el.role == .unknown || el.role == .button) {
                // Check parent context — should be in a list/outline
                if let parentRef = el.parentRef {
                    let parent = elements.first(where: { $0.ref == parentRef })
                    if parent?.role == .outline || parent?.role == .list || parent?.role == .scrollArea {
                        return el.label
                    }
                }
            }
        }
        return nil
    }

    private static func findPathBar(in elements: [ScreenElement]) -> [String] {
        // Some apps (Finder, Xcode) show a path bar with breadcrumb buttons
        // Look for a sequence of buttons with ">" or "/" separators
        var pathButtons: [(label: String, x: CGFloat)] = []

        for el in elements {
            guard el.role == .button || el.role == .staticText,
                  !el.label.isEmpty,
                  let bounds = el.bounds else { continue }

            // Path bars are usually near the bottom or in a toolbar
            // Look for small buttons in a horizontal row
            if bounds.height < 30 && bounds.width < 200 {
                let label = el.label.trimmingCharacters(in: .whitespaces)
                if !label.isEmpty && label != ">" && label != "/" && label != "▸" {
                    pathButtons.append((label: label, x: bounds.origin.x))
                }
            }
        }

        // Not a path bar if we don't have multiple adjacent small buttons
        // (This is a heuristic — path bars have 3+ items in a row)
        return []  // Conservative: don't guess. Will be improved with app profiles.
    }

    // MARK: - AX-Based Deep Search

    private struct NavElement {
        let label: String
        let type: NavElementType
    }

    private enum NavElementType {
        case activeTab
        case sidebarSelection
        case segmentSelection
    }

    private static func findNavElements(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        results: inout [NavElement]
    ) {
        guard depth < maxDepth, results.count < 5 else { return }

        let role = AXAttributes.getRole(element) ?? ""
        let selected = AXAttributes.getBool(element, "AXSelected") ?? false

        if role == "AXTab" && selected {
            let label = AXAttributes.bestLabel(element)
            if !label.isEmpty {
                results.append(NavElement(label: label, type: .activeTab))
            }
        }

        if role == "AXRadioButton" && selected {
            // Could be a tab in a tab bar or a segmented control
            let label = AXAttributes.bestLabel(element)
            if !label.isEmpty {
                // Check parent — if it's a tab group or radio group
                results.append(NavElement(label: label, type: .activeTab))
            }
        }

        // Outline/list selected rows
        if (role == "AXRow" || role == "AXCell") && selected {
            let label = AXAttributes.bestLabel(element)
            if !label.isEmpty {
                if let pos = AXAttributes.getPosition(element), pos.x < 400 {
                    results.append(NavElement(label: label, type: .sidebarSelection))
                }
            }
        }

        guard let children = AXAttributes.getChildren(element) else { return }
        for child in children {
            findNavElements(element: child, depth: depth + 1, maxDepth: maxDepth, results: &results)
        }
    }
}
