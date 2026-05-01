import Foundation
import ApplicationServices
import AppKit

/// Discovers and suggests keyboard shortcuts as alternatives to mouse clicks.
/// Parses menu bar items for AXMenuItemCmdChar + AXMenuItemCmdModifiers.
public enum ShortcutAdvisor {

    // MARK: - Shortcut

    public struct Shortcut: Sendable {
        public let menuPath: [String]       // ["File", "Save"]
        public let key: String              // "S"
        public let modifiers: String        // "Cmd" or "Cmd+Shift"
        public let displayString: String    // "⌘S" or "⌘⇧S"

        public init(menuPath: [String], key: String, modifiers: String, displayString: String) {
            self.menuPath = menuPath
            self.key = key
            self.modifiers = modifiers
            self.displayString = displayString
        }
    }

    /// A suggestion to use a keyboard shortcut instead of clicking.
    public struct ShortcutSuggestion: Sendable {
        public let elementRef: ElementRef
        public let elementLabel: String
        public let shortcut: Shortcut
        public let reason: String

        public init(elementRef: ElementRef, elementLabel: String, shortcut: Shortcut, reason: String) {
            self.elementRef = elementRef
            self.elementLabel = elementLabel
            self.shortcut = shortcut
            self.reason = reason
        }
    }

    // MARK: - Discovery

    /// Discover all keyboard shortcuts from the frontmost app's menu bar.
    public static func discoverShortcuts() -> [Shortcut] {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return [] }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get the menu bar
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return [] }

        let menuBarElement = menuBar as! AXUIElement

        var shortcuts: [Shortcut] = []
        guard let menuItems = AXAttributes.getChildren(menuBarElement) else { return [] }

        for menuItem in menuItems {
            let menuTitle = AXAttributes.getTitle(menuItem) ?? ""
            guard !menuTitle.isEmpty else { continue }

            // Get submenu
            var submenuRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(menuItem, "AXChildren" as CFString, &submenuRef) == .success,
                  let submenuChildren = submenuRef as? [AXUIElement] else { continue }

            for submenu in submenuChildren {
                parseMenuItems(submenu, path: [menuTitle], shortcuts: &shortcuts, depth: 0)
            }
        }

        return shortcuts
    }

    /// Suggest shortcuts for elements the agent is about to click.
    public static func suggestShortcuts(for elements: [ScreenElement], shortcuts: [Shortcut]) -> [ShortcutSuggestion] {
        var suggestions: [ShortcutSuggestion] = []

        for el in elements {
            guard el.role.isInteractive, !el.label.isEmpty else { continue }
            let elLower = el.label.lowercased()

            // Find a shortcut whose menu item label matches this element
            for shortcut in shortcuts {
                let menuLabel = shortcut.menuPath.last?.lowercased() ?? ""
                if menuLabel == elLower || menuLabel.contains(elLower) || elLower.contains(menuLabel) {
                    suggestions.append(ShortcutSuggestion(
                        elementRef: el.ref,
                        elementLabel: el.label,
                        shortcut: shortcut,
                        reason: "Use \(shortcut.displayString) instead of clicking \"\(el.label)\""
                    ))
                    break
                }
            }
        }

        return suggestions
    }

    /// Get a shortcut map as a compact string for LLM context.
    public static func formatForLLM(_ shortcuts: [Shortcut]) -> String {
        guard !shortcuts.isEmpty else { return "" }
        var lines = ["Shortcuts:"]
        for s in shortcuts.prefix(30) {
            lines.append("  \(s.displayString) — \(s.menuPath.joined(separator: " > "))")
        }
        if shortcuts.count > 30 {
            lines.append("  ... +\(shortcuts.count - 30) more")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Menu Parsing

    private static func parseMenuItems(_ menu: AXUIElement, path: [String], shortcuts: inout [Shortcut], depth: Int) {
        guard depth < 4 else { return }
        guard let items = AXAttributes.getChildren(menu) else { return }

        for item in items {
            let title = AXAttributes.getTitle(item) ?? ""
            guard !title.isEmpty, title != "separator" else { continue }

            // Check for keyboard shortcut
            let cmdChar = AXAttributes.getString(item, "AXMenuItemCmdChar")
            let cmdModifiers = getModifiers(item)

            if let key = cmdChar, !key.isEmpty {
                let modStr = formatModifiers(cmdModifiers)
                let display = "\(modStr)\(key)"
                shortcuts.append(Shortcut(
                    menuPath: path + [title],
                    key: key,
                    modifiers: modStr,
                    displayString: display
                ))
            }

            // Recurse into submenus
            if let children = AXAttributes.getChildren(item) {
                for child in children {
                    let childRole = AXAttributes.getRole(child) ?? ""
                    if childRole == "AXMenu" {
                        parseMenuItems(child, path: path + [title], shortcuts: &shortcuts, depth: depth + 1)
                    }
                }
            }
        }
    }

    private static func getModifiers(_ element: AXUIElement) -> UInt {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXMenuItemCmdModifiers" as CFString, &value) == .success else {
            return 0 // Default: Cmd only
        }
        return (value as? NSNumber)?.uintValue ?? 0
    }

    /// Format modifier flags into a human-readable string.
    /// AXMenuItemCmdModifiers: 0 = Cmd, bit 0 = Shift removed, bit 1 = Opt removed, bit 2 = Ctrl removed
    /// Apple uses an inverted scheme: 0 means Cmd only, adding bits REMOVES modifiers from Cmd+Shift+Opt+Ctrl
    private static func formatModifiers(_ flags: UInt) -> String {
        // The AX modifier value is actually straightforward:
        // 0 = Cmd, 1 = Cmd+Shift, 2 = Cmd+Opt, 4 = Cmd+Ctrl, combinations thereof
        // But Apple's implementation varies. Let's use the practical mapping:
        var parts: [String] = ["⌘"]

        // Bit mapping (empirical):
        if flags & 1 != 0 { parts.insert("⇧", at: 0) }    // Shift
        if flags & 2 != 0 { parts.insert("⌥", at: 0) }    // Option
        if flags & 4 != 0 { parts.insert("⌃", at: 0) }    // Control

        return parts.joined()
    }
}
