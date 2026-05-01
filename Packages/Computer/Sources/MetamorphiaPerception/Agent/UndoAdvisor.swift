import Foundation
import ApplicationServices
import AppKit

/// Tracks undo availability and action reversibility.
/// Checks Edit > Undo menu state to determine if the last action can be undone.
public enum UndoAdvisor {

    // MARK: - Undo State

    public struct UndoState: Sendable {
        public let canUndo: Bool
        public let undoLabel: String?       // "Undo Typing", "Undo Delete", etc.
        public let canRedo: Bool
        public let redoLabel: String?
        public let shortcut: String?        // "⌘Z"

        public init(canUndo: Bool, undoLabel: String?, canRedo: Bool, redoLabel: String?, shortcut: String?) {
            self.canUndo = canUndo
            self.undoLabel = undoLabel
            self.canRedo = canRedo
            self.redoLabel = redoLabel
            self.shortcut = shortcut
        }

        /// Human-readable summary.
        public var summary: String {
            if canUndo {
                return "Undo available: \(undoLabel ?? "Undo") (\(shortcut ?? "⌘Z"))"
            }
            return "No undo available"
        }
    }

    /// An assessment of whether an action is reversible.
    public struct ReversibilityAssessment: Sendable {
        public let elementRef: ElementRef
        public let isReversible: Bool
        public let reversalMethod: String?  // "Cmd+Z", "click again to toggle", etc.
        public let confidence: Float        // 0-1

        public init(elementRef: ElementRef, isReversible: Bool, reversalMethod: String?, confidence: Float) {
            self.elementRef = elementRef
            self.isReversible = isReversible
            self.reversalMethod = reversalMethod
            self.confidence = confidence
        }
    }

    // MARK: - Query

    /// Check the current undo/redo state by querying the Edit menu.
    public static func checkUndoState() -> UndoState {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return UndoState(canUndo: false, undoLabel: nil, canRedo: false, redoLabel: nil, shortcut: nil)
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get menu bar
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            return UndoState(canUndo: false, undoLabel: nil, canRedo: false, redoLabel: nil, shortcut: nil)
        }

        let menuBarElement = menuBar as! AXUIElement

        // Find Edit menu
        guard let editMenu = findEditMenu(menuBarElement) else {
            return UndoState(canUndo: false, undoLabel: nil, canRedo: false, redoLabel: nil, shortcut: nil)
        }

        // Find Undo and Redo items
        var undoLabel: String? = nil
        var canUndo = false
        var redoLabel: String? = nil
        var canRedo = false

        guard let editItems = AXAttributes.getChildren(editMenu) else {
            return UndoState(canUndo: false, undoLabel: nil, canRedo: false, redoLabel: nil, shortcut: nil)
        }

        for submenu in editItems {
            guard let items = AXAttributes.getChildren(submenu) else { continue }
            for item in items {
                let title = AXAttributes.getTitle(item) ?? ""
                let titleLower = title.lowercased()
                let enabled = AXAttributes.getBool(item, kAXEnabledAttribute) ?? false

                if titleLower.hasPrefix("undo") {
                    undoLabel = title
                    canUndo = enabled
                }
                if titleLower.hasPrefix("redo") {
                    redoLabel = title
                    canRedo = enabled
                }
            }
        }

        return UndoState(
            canUndo: canUndo,
            undoLabel: undoLabel,
            canRedo: canRedo,
            redoLabel: redoLabel,
            shortcut: canUndo ? "⌘Z" : nil
        )
    }

    /// Assess whether interacting with an element is likely reversible.
    public static func assessReversibility(element: ScreenElement, map: ScreenMap) -> ReversibilityAssessment {
        let labelLower = element.label.lowercased()

        // Toggles/checkboxes are always reversible (click again)
        if element.role == .checkbox || element.role == .toggle || element.role == .radioButton {
            return ReversibilityAssessment(
                elementRef: element.ref,
                isReversible: true,
                reversalMethod: "Click again to toggle back",
                confidence: 0.95
            )
        }

        // Text fields — typing is reversible via Cmd+Z
        if element.role == .textField || element.role == .textArea {
            return ReversibilityAssessment(
                elementRef: element.ref,
                isReversible: true,
                reversalMethod: "⌘Z to undo",
                confidence: 0.9
            )
        }

        // Tabs — always reversible (click the previous tab)
        if element.role == .tab || element.role == .radioButton {
            return ReversibilityAssessment(
                elementRef: element.ref,
                isReversible: true,
                reversalMethod: "Click previous tab to go back",
                confidence: 0.95
            )
        }

        // Known destructive keywords — not reversible
        let destructiveWords = ["delete", "remove", "erase", "permanently", "format", "uninstall"]
        for word in destructiveWords {
            if labelLower.contains(word) {
                return ReversibilityAssessment(
                    elementRef: element.ref,
                    isReversible: false,
                    reversalMethod: nil,
                    confidence: 0.8
                )
            }
        }

        // Send/submit — usually not reversible
        let sendWords = ["send", "submit", "publish", "post"]
        for word in sendWords {
            if labelLower.contains(word) {
                return ReversibilityAssessment(
                    elementRef: element.ref,
                    isReversible: false,
                    reversalMethod: nil,
                    confidence: 0.7
                )
            }
        }

        // Navigation buttons — reversible (go back)
        let navWords = ["back", "forward", "next", "previous", "open", "go"]
        for word in navWords {
            if labelLower.contains(word) {
                return ReversibilityAssessment(
                    elementRef: element.ref,
                    isReversible: true,
                    reversalMethod: "Navigate back",
                    confidence: 0.7
                )
            }
        }

        // Default: probably reversible via Cmd+Z for most button clicks
        return ReversibilityAssessment(
            elementRef: element.ref,
            isReversible: true,
            reversalMethod: "⌘Z may undo",
            confidence: 0.5
        )
    }

    // MARK: - Helpers

    private static func findEditMenu(_ menuBar: AXUIElement) -> AXUIElement? {
        guard let items = AXAttributes.getChildren(menuBar) else { return nil }
        for item in items {
            let title = AXAttributes.getTitle(item) ?? ""
            if title == "Edit" {
                return item
            }
        }
        return nil
    }
}
