import Foundation

/// Detects destructive/dangerous UI elements based on labels and context.
public enum DangerDetector {

    // MARK: - Danger Level

    public enum DangerLevel: Int, Comparable, Sendable {
        case safe = 0
        case caution = 1
        case dangerous = 2

        public static func < (lhs: DangerLevel, rhs: DangerLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Result of scanning a single element.
    public struct DangerResult: Sendable {
        public let ref: ElementRef
        public let level: DangerLevel
        public let reason: String?

        public init(ref: ElementRef, level: DangerLevel, reason: String?) {
            self.ref = ref
            self.level = level
            self.reason = reason
        }
    }

    // MARK: - Keyword Sets

    /// Keywords that strongly indicate destructive/irreversible actions.
    private static let dangerousKeywords: [String] = [
        "delete account", "delete all", "erase all", "erase content",
        "factory reset", "format disk", "format drive",
        "permanently delete", "permanently remove",
        "remove all", "reset all", "wipe",
        "destroy", "purge", "clear all data",
        "cannot be undone", "irreversible",
        "uninstall", "deauthorize", "revoke all",
    ]

    /// Keywords that indicate potentially dangerous single-word actions.
    private static let dangerousWords: Set<String> = [
        "delete", "remove", "erase", "format",
        "reset", "terminate", "disable", "discard",
    ]

    /// Keywords that indicate state-changing but not necessarily destructive actions.
    private static let cautionKeywords: Set<String> = [
        "submit", "send", "publish", "post",
        "confirm", "apply", "update", "save",
        "enable", "sign out", "log out", "logout",
        "change", "modify", "overwrite", "replace",
        "close", "quit", "shut down", "restart",
    ]

    /// Contexts where caution keywords escalate to dangerous.
    private static let elevatedContextApps: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.Preferences",
        "com.apple.DiskUtility",
        "com.apple.dt.Xcode",              // build/clean operations
    ]

    private static let elevatedContextTitles: [String] = [
        "preferences", "settings", "configuration",
        "admin", "advanced", "security", "privacy",
        "disk utility", "terminal",
    ]

    // MARK: - Scanning

    /// Scan all elements in a ScreenMap for danger.
    public static func scan(elements: [ScreenElement], context: ScanContext) -> [DangerResult] {
        var results: [DangerResult] = []

        for element in elements {
            guard element.role.isInteractive else { continue }
            let result = classify(element: element, context: context)
            if result.level > .safe {
                results.append(result)
            }
        }

        return results
    }

    /// Classify a single element's danger level.
    public static func classify(element: ScreenElement, context: ScanContext) -> DangerResult {
        let labelLower = element.label.lowercased()
        let valueLower = element.value.lowercased()
        let combined = "\(labelLower) \(valueLower)"

        // Check dangerous phrases first (highest signal)
        for keyword in dangerousKeywords {
            if combined.contains(keyword) {
                return DangerResult(ref: element.ref, level: .dangerous, reason: "Contains '\(keyword)'")
            }
        }

        // Check dangerous single words — but only for buttons and menu items
        // (a text field labeled "delete" is not dangerous)
        if element.role == .button || element.role == .menuItem || element.role == .menuBarItem {
            for word in dangerousWords {
                if labelLower.contains(word) {
                    // Context: "Delete" in a text editor is usually safe (delete text)
                    // "Delete" in Settings is dangerous (delete data)
                    if context.isElevated {
                        return DangerResult(ref: element.ref, level: .dangerous, reason: "'\(word)' in settings/admin context")
                    }
                    return DangerResult(ref: element.ref, level: .caution, reason: "Contains '\(word)'")
                }
            }
        }

        // Check caution keywords
        for keyword in cautionKeywords {
            if labelLower.contains(keyword) {
                if context.isElevated {
                    // Escalate caution to dangerous in settings panels
                    return DangerResult(ref: element.ref, level: .dangerous, reason: "'\(keyword)' in settings context")
                }
                return DangerResult(ref: element.ref, level: .caution, reason: "State-changing: '\(keyword)'")
            }
        }

        return DangerResult(ref: element.ref, level: .safe, reason: nil)
    }

    // MARK: - Scan Context

    /// Context about the current app/window for danger assessment.
    public struct ScanContext: Sendable {
        public let appBundleID: String?
        public let windowTitle: String
        public let isElevated: Bool

        public init(appBundleID: String?, windowTitle: String) {
            self.appBundleID = appBundleID
            self.windowTitle = windowTitle

            // Determine if this is an elevated context
            var elevated = false
            if let bundleID = appBundleID, elevatedContextApps.contains(bundleID) {
                elevated = true
            }
            let titleLower = windowTitle.lowercased()
            for keyword in elevatedContextTitles {
                if titleLower.contains(keyword) {
                    elevated = true
                    break
                }
            }
            self.isElevated = elevated
        }
    }
}
