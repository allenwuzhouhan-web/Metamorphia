import Foundation
import ApplicationServices
#if canImport(AppKit)
import AppKit
#endif

// MARK: - MenuBarReader

/// Walks and invokes the frontmost app's menu bar via `AXUIElement` — entirely local,
/// no pixels touched. Complements `ShortcutAdvisor` (which only captures items that
/// carry a keyboard shortcut) by emitting the **full** menu tree: titles, submenu
/// structure, enabled state, and shortcut annotation.
///
/// This is the "non-screenshot" path for apps whose main canvas is opaque to the
/// Accessibility API (Blender, DaVinci Resolve, CapCut, Unity, most Metal/OpenGL apps).
/// Their menu bars remain fully AX-accessible and expose the vast majority of the
/// operations the app performs.
///
/// **Caching.** A per-`pid` cache with a 30-second TTL avoids repeated deep walks:
/// menu bar structure is stable within an app unless the app is rebooted or the user
/// opens a new document class. Call `invalidateCache()` on app switch.
///
/// **Invocation.** `invoke(path:pid:)` re-walks the live AX tree by title path at the
/// moment of dispatch and calls `AXUIElementPerformAction(item, kAXPressAction)`. This
/// guarantees that a stale snapshot can never produce a wrong press — the check is
/// always against fresh AX state.
public enum MenuBarReader {

    // MARK: - Tuning knobs

    /// Max recursion depth in the menu tree. 5 is enough to cover most real-world menus
    /// (`File → Export → glTF → Options`). Bumping higher costs proportional walk time.
    public static let maxDepth: Int = 5

    /// Safety cap on total emitted items. Blender's full menu bar is ~600 items;
    /// this cap truncates pathological cases.
    public static let maxItems: Int = 800

    /// Cache TTL in seconds. Menu bars are stable — most app-lifetime-long.
    public static let cacheTTL: TimeInterval = 30.0

    // MARK: - Cache

    private struct CacheEntry {
        let items: [MenuItem]
        let capturedAt: Date
    }

    private static var cache: [pid_t: CacheEntry] = [:]
    private static let cacheLock = NSLock()

    /// Drop the cache for a specific pid, or all pids.
    public static func invalidateCache(pid: pid_t? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let pid = pid {
            cache.removeValue(forKey: pid)
        } else {
            cache.removeAll()
        }
    }

    // MARK: - Public API

    /// Read the full menu tree for an app. Returns the cache if fresh; otherwise walks.
    /// First walk for Blender-class apps takes 400–1500 ms; subsequent calls are cache hits.
    /// Thread-safe via an internal NSLock.
    public static func readMenuBar(pid: pid_t) -> [MenuItem] {
        cacheLock.lock()
        let cached = cache[pid]
        cacheLock.unlock()

        if let cached = cached, Date().timeIntervalSince(cached.capturedAt) < cacheTTL {
            return cached.items
        }

        let app = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarValue = menuBarRef,
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return []
        }
        let menuBar = menuBarValue as! AXUIElement

        var items: [MenuItem] = []
        var count = 0
        walkMenuBarRoot(menuBar, items: &items, count: &count)

        cacheLock.lock()
        cache[pid] = CacheEntry(items: items, capturedAt: Date())
        cacheLock.unlock()

        return items
    }

    /// Invoke a menu item identified by its title path (e.g. `["File", "Export…", "glTF 2.0"]`).
    /// Returns `true` on a successful press. Re-walks the live AX tree to find the item —
    /// the cache is NOT used here, because the enabled state and position of an item can
    /// change between captures.
    ///
    /// The press is dispatched via `AXUIElementPerformAction(item, kAXPressAction)` — no
    /// mouse movement, no cursor simulation, no screen reading. The OS applies the menu
    /// item as if the user had clicked it.
    @discardableResult
    public static func invoke(path: [String], pid: pid_t) -> Bool {
        guard !path.isEmpty else { return false }

        let app = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarValue = menuBarRef,
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return false
        }
        let menuBar = menuBarValue as! AXUIElement

        guard let target = findItem(inMenuContainer: menuBar, remainingPath: path) else {
            return false
        }

        // Refuse to press disabled items — mirrors the refuse-gate in LocalDecisionEngine.
        // A disabled press is a no-op on macOS, but we treat it as an explicit failure so
        // callers can react rather than silently succeeding.
        let enabled = AXAttributes.isEnabled(target)
        if !enabled { return false }

        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    // MARK: - Walking

    /// The menu bar's direct children are `AXMenuBarItem` nodes (File, Edit, View, …).
    /// Each has exactly one `AXMenu` child which holds the visible `AXMenuItem` entries.
    /// We emit a MenuItem for every `AXMenuItem` we see, keyed by its title-path.
    private static func walkMenuBarRoot(
        _ menuBar: AXUIElement,
        items: inout [MenuItem],
        count: inout Int
    ) {
        guard let barItems = AXAttributes.getChildren(menuBar) else { return }

        for barItem in barItems {
            guard count < maxItems else { return }
            let role = AXAttributes.getRole(barItem) ?? ""
            guard role == "AXMenuBarItem" else { continue }

            let barTitle = AXAttributes.getTitle(barItem) ?? ""
            // Skip the Apple menu (title is an empty string or ""). It's not app-specific
            // and noisy for agents trying to reason about app operations.
            guard !barTitle.isEmpty else { continue }

            // A menu bar item has one AXMenu child. Walk its items.
            guard let barChildren = AXAttributes.getChildren(barItem),
                  let submenu = barChildren.first(where: { (AXAttributes.getRole($0) ?? "") == "AXMenu" }) else {
                continue
            }

            walkMenuContents(submenu, parentPath: [barTitle], depth: 1, items: &items, count: &count)
        }
    }

    /// Walks the contents of an `AXMenu` node — its children are `AXMenuItem` entries.
    /// For each entry, emits a MenuItem and recurses into any submenu.
    private static func walkMenuContents(
        _ menu: AXUIElement,
        parentPath: [String],
        depth: Int,
        items: inout [MenuItem],
        count: inout Int
    ) {
        guard depth <= maxDepth, count < maxItems else { return }
        guard let menuEntries = AXAttributes.getChildren(menu) else { return }

        for entry in menuEntries {
            guard count < maxItems else { return }
            let role = AXAttributes.getRole(entry) ?? ""
            guard role == "AXMenuItem" else { continue }

            let title = AXAttributes.getTitle(entry) ?? ""
            // Separators have an empty title — skip.
            guard !title.isEmpty else { continue }

            let enabled = AXAttributes.isEnabled(entry)
            let shortcut = extractShortcut(entry)

            // A submenu is a child AXMenu under the AXMenuItem. Detect it so the agent
            // knows this item is a container, not a leaf.
            let entryChildren = AXAttributes.getChildren(entry) ?? []
            let subMenu = entryChildren.first(where: { (AXAttributes.getRole($0) ?? "") == "AXMenu" })
            let hasSubmenu = subMenu != nil

            let currentPath = parentPath + [title]
            items.append(MenuItem(
                title: title,
                path: currentPath,
                shortcut: shortcut,
                enabled: enabled,
                hasSubmenu: hasSubmenu
            ))
            count += 1

            if let subMenu = subMenu {
                walkMenuContents(subMenu, parentPath: currentPath, depth: depth + 1, items: &items, count: &count)
            }
        }
    }

    // MARK: - Invocation helpers

    /// Walks a menu-container AX element looking for an item whose title path matches
    /// `remainingPath`. `container` must be either the root `AXMenuBar` (for the first
    /// path component, which is an `AXMenuBarItem` label like "File") or an `AXMenu`
    /// (for subsequent path components which are `AXMenuItem` labels).
    private static func findItem(
        inMenuContainer container: AXUIElement,
        remainingPath: [String]
    ) -> AXUIElement? {
        guard !remainingPath.isEmpty else { return nil }
        let nextTitle = remainingPath[0]
        let rest = Array(remainingPath.dropFirst())

        guard let children = AXAttributes.getChildren(container) else { return nil }

        for child in children {
            let role = AXAttributes.getRole(child) ?? ""
            // AXMenuBarItem and AXMenuItem both expose their visible label via kAXTitleAttribute.
            guard role == "AXMenuBarItem" || role == "AXMenuItem" else { continue }
            let title = AXAttributes.getTitle(child) ?? ""
            if !titlesMatch(title, nextTitle) { continue }

            if rest.isEmpty {
                // Found the leaf — this is the item to press.
                return child
            }

            // Drill into the child's AXMenu to continue the path.
            guard let grandchildren = AXAttributes.getChildren(child),
                  let submenu = grandchildren.first(where: { (AXAttributes.getRole($0) ?? "") == "AXMenu" }) else {
                return nil
            }
            if let found = findItem(inMenuContainer: submenu, remainingPath: rest) {
                return found
            }
        }
        return nil
    }

    /// Loose title match — trims whitespace and is case-insensitive. Menus like
    /// `"Save…"` vs `"Save..."` (three dots vs ellipsis char) are a recurring headache,
    /// so we also normalize that.
    private static func titlesMatch(_ axTitle: String, _ queryTitle: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{2026}", with: "...")
                .lowercased()
        }
        return normalize(axTitle) == normalize(queryTitle)
    }

    // MARK: - Shortcut formatting

    /// Reads `AXMenuItemCmdChar` + `AXMenuItemCmdModifiers` from an `AXMenuItem` and
    /// formats as a human-readable hotkey string like `"cmd+shift+e"`. Returns `nil`
    /// when the item has no keyboard shortcut, or when the shortcut involves a
    /// virtual key (F-keys, arrows) that we don't attempt to name here.
    private static func extractShortcut(_ menuItem: AXUIElement) -> String? {
        guard let cmdChar = AXAttributes.getString(menuItem, "AXMenuItemCmdChar"),
              !cmdChar.isEmpty else {
            return nil
        }

        var modFlags: UInt = 0
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(menuItem, "AXMenuItemCmdModifiers" as CFString, &value) == .success {
            modFlags = (value as? NSNumber)?.uintValue ?? 0
        }

        // AXMenuItemCmdModifiers encoding (empirically validated):
        //   bit 0 (0x01): Shift
        //   bit 1 (0x02): Option
        //   bit 2 (0x04): Control
        //   bit 3 (0x08): "no Command key" (Cmd is NOT in the shortcut)
        var parts: [String] = []
        if (modFlags & 0x04) != 0 { parts.append("ctrl") }
        if (modFlags & 0x02) != 0 { parts.append("option") }
        if (modFlags & 0x01) != 0 { parts.append("shift") }
        if (modFlags & 0x08) == 0 { parts.append("cmd") }
        parts.append(cmdChar.lowercased())
        return parts.joined(separator: "+")
    }
}
