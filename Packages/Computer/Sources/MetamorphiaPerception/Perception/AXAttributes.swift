import Foundation
import ApplicationServices

/// Low-level helpers for reading AXUIElement attributes.
enum AXAttributes {

    // MARK: - String Attributes

    static func getString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func getTitle(_ element: AXUIElement) -> String? {
        getString(element, kAXTitleAttribute)
    }

    static func getValue(_ element: AXUIElement) -> String? {
        getString(element, kAXValueAttribute)
    }

    static func getDescription(_ element: AXUIElement) -> String? {
        getString(element, kAXDescriptionAttribute)
    }

    static func getRole(_ element: AXUIElement) -> String? {
        getString(element, kAXRoleAttribute)
    }

    static func getSubrole(_ element: AXUIElement) -> String? {
        getString(element, kAXSubroleAttribute)
    }

    static func getIdentifier(_ element: AXUIElement) -> String? {
        getString(element, "AXIdentifier")
    }

    static func getLabel(_ element: AXUIElement) -> String? {
        getString(element, "AXLabel")
    }

    // MARK: - Geometry

    static func getPosition(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &point)
        return point
    }

    static func getSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &size)
        return size
    }

    // MARK: - Boolean Attributes

    static func getBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func isEnabled(_ element: AXUIElement) -> Bool {
        getBool(element, kAXEnabledAttribute) ?? true
    }

    static func isFocused(_ element: AXUIElement) -> Bool {
        getBool(element, kAXFocusedAttribute) ?? false
    }

    static func isSelected(_ element: AXUIElement) -> Bool {
        getBool(element, "AXSelected") ?? false
    }

    static func isExpanded(_ element: AXUIElement) -> Bool {
        getBool(element, "AXExpanded") ?? false
    }

    // MARK: - Children

    static func getChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    // MARK: - Actions

    static func getActions(_ element: AXUIElement) -> [String] {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else { return [] }
        return actions
    }

    // MARK: - Focused Window

    static func getFocusedWindow(_ appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // MARK: - State Builder

    /// Build ElementState from AX attributes.
    static func buildState(_ element: AXUIElement, subrole: String) -> ElementState {
        var state: ElementState = []

        if isEnabled(element) {
            state.insert(.enabled)
        } else {
            state.insert(.disabled)
        }

        if isFocused(element) { state.insert(.focused) }
        if isSelected(element) { state.insert(.selected) }
        if isExpanded(element) { state.insert(.expanded) }

        // Checkbox / toggle checked state
        if let val = getValue(element), val == "1" {
            state.insert(.checked)
        }

        if subrole == "AXSecureTextField" { state.insert(.password) }

        return state
    }

    // MARK: - Best Label

    /// Pick the best human-readable label from available attributes.
    static func bestLabel(_ element: AXUIElement) -> String {
        if let title = getTitle(element), !title.isEmpty { return title }
        if let desc = getDescription(element), !desc.isEmpty { return desc }
        if let label = getLabel(element), !label.isEmpty { return label }
        if let value = getValue(element), !value.isEmpty { return String(value.prefix(80)) }
        return ""
    }
}
