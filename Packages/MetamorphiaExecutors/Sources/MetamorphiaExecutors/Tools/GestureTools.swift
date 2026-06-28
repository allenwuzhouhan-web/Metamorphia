import Foundation
import CoreGraphics
import MetamorphiaAgentKit
import MetamorphiaPerception

// AUDIT: These tools synthesize real HID events into the frontmost app and are
// therefore NOT read-only. Their names — `click_at`, `double_click_at`,
// `right_click_at`, `drag`, `swipe`, `long_press`, `type_text`, `key_combo`,
// `move_mouse` — are classified `.elevated` (never `.safe`) in
// `MetamorphiaToolSafetyGate.defaultElevatedTools`, and `PerceptionSafetyInspector`
// escalates the dangerous ones to `.critical`. Keep these names in sync with
// that set; adding a new destructive gesture tool requires updating the gate.

// MARK: - ClickAtTool

/// Synthesize a mouse click at a screen coordinate. Replaces the slow
/// AppleScript `tell application "System Events" to click at {x,y}` path —
/// fires a real `CGEvent` from the HID tap, so it's both faster and delivers
/// to apps that ignore AppleScript events (Electron / Chrome content views,
/// hardened targets, etc.).
public struct ClickAtTool: ToolDefinition {
    public let name = "click_at"
    public let description = "Click at a screen coordinate via CGEvent. Supports left/right/center mouse buttons and repeat counts (count=2 is a double-click, count=3 a triple-click). Coordinates are top-left pixels. Requires Accessibility permission — see `is_accessibility_trusted` if clicks appear to vanish. Returns `clicked (x,y)` on success."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.integer(description: "X coordinate in top-left pixel space."),
            "y": JSONSchema.integer(description: "Y coordinate in top-left pixel space."),
            "button": JSONSchema.enumString(
                description: "Which mouse button to press. Defaults to 'left'.",
                values: ["left", "right", "center"]
            ),
            "count": JSONSchema.integer(
                description: "Click count — 1 (default), 2 for double-click, 3 for triple-click.",
                minimum: 1, maximum: 10
            ),
        ], required: ["x", "y"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let x = optionalInt("x", from: args), let y = optionalInt("y", from: args) else {
            return "Error: missing required parameters: x, y"
        }
        let button = parseMouseButton(args["button"] as? String) ?? .left
        let count = optionalInt("count", from: args) ?? 1

        do {
            try GestureExecutor.click(
                at: CGPoint(x: x, y: y),
                button: button,
                count: count
            )
            return "clicked (\(x),\(y)) button=\(args["button"] as? String ?? "left") count=\(count)"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - DoubleClickAtTool

public struct DoubleClickAtTool: ToolDefinition {
    public let name = "double_click_at"
    public let description = "Double-click (left button) at a screen coordinate. Thin wrapper around `click_at` with count=2 — kept as a separate tool so the agent can pick a semantic intent. Coordinates are top-left pixels."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.integer(description: "X coordinate in top-left pixel space."),
            "y": JSONSchema.integer(description: "Y coordinate in top-left pixel space."),
        ], required: ["x", "y"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let x = optionalInt("x", from: args), let y = optionalInt("y", from: args) else {
            return "Error: missing required parameters: x, y"
        }
        do {
            try GestureExecutor.doubleClick(at: CGPoint(x: x, y: y))
            return "double-clicked (\(x),\(y))"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - RightClickAtTool

public struct RightClickAtTool: ToolDefinition {
    public let name = "right_click_at"
    public let description = "Right-click (secondary button) at a screen coordinate. Triggers contextual menus. Coordinates are top-left pixels."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.integer(description: "X coordinate in top-left pixel space."),
            "y": JSONSchema.integer(description: "Y coordinate in top-left pixel space."),
        ], required: ["x", "y"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let x = optionalInt("x", from: args), let y = optionalInt("y", from: args) else {
            return "Error: missing required parameters: x, y"
        }
        do {
            try GestureExecutor.rightClick(at: CGPoint(x: x, y: y))
            return "right-clicked (\(x),\(y))"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - DragTool

public struct DragTool: ToolDefinition {
    public let name = "drag"
    public let description = "Press-drag-release from one point to another over a duration. Used for text selection, file drag-and-drop, window moving, canvas painting. Interpolates ~60 intermediate points per second for smooth motion. Coordinates are top-left pixels."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "from_x": JSONSchema.integer(description: "Start X coordinate."),
            "from_y": JSONSchema.integer(description: "Start Y coordinate."),
            "to_x":   JSONSchema.integer(description: "End X coordinate."),
            "to_y":   JSONSchema.integer(description: "End Y coordinate."),
            "duration_ms": JSONSchema.integer(
                description: "Drag duration in milliseconds. Default 250. Shorter = faster, may skip UI hit-tests.",
                minimum: 0, maximum: 10_000
            ),
        ], required: ["from_x", "from_y", "to_x", "to_y"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let fx = optionalInt("from_x", from: args),
              let fy = optionalInt("from_y", from: args),
              let tx = optionalInt("to_x", from: args),
              let ty = optionalInt("to_y", from: args) else {
            return "Error: missing required parameters: from_x, from_y, to_x, to_y"
        }
        let durationMS = optionalInt("duration_ms", from: args) ?? 250

        do {
            try await GestureExecutor.drag(
                from: CGPoint(x: fx, y: fy),
                to:   CGPoint(x: tx, y: ty),
                duration: TimeInterval(durationMS) / 1000.0
            )
            return "dragged (\(fx),\(fy)) -> (\(tx),\(ty)) in \(durationMS)ms"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - SwipeTool

public struct SwipeTool: ToolDefinition {
    public let name = "swipe"
    public let description = "Swipe gesture — a directional drag by N pixels. Useful for dismissing notifications, navigating between pages in paginated views, or triggering swipe-to-delete. Direction is left/right/up/down in screen coordinates (down = positive Y in top-left space)."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "direction": JSONSchema.enumString(
                description: "Swipe direction in screen space.",
                values: ["left", "right", "up", "down"]
            ),
            "distance": JSONSchema.integer(
                description: "Swipe distance in pixels.",
                minimum: 1, maximum: 10_000
            ),
            "start_x": JSONSchema.integer(description: "Starting X coordinate."),
            "start_y": JSONSchema.integer(description: "Starting Y coordinate."),
            "duration_ms": JSONSchema.integer(
                description: "Swipe duration in milliseconds. Default 150.",
                minimum: 0, maximum: 10_000
            ),
        ], required: ["direction", "distance", "start_x", "start_y"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let dirStr = args["direction"] as? String,
              let direction = parseSwipeDirection(dirStr) else {
            return "Error: direction must be one of left/right/up/down"
        }
        guard let distance = optionalInt("distance", from: args),
              let sx = optionalInt("start_x", from: args),
              let sy = optionalInt("start_y", from: args) else {
            return "Error: missing required parameters: distance, start_x, start_y"
        }
        let durationMS = optionalInt("duration_ms", from: args) ?? 150

        do {
            try await GestureExecutor.swipe(
                direction: direction,
                distance: CGFloat(distance),
                startAt: CGPoint(x: sx, y: sy),
                duration: TimeInterval(durationMS) / 1000.0
            )
            return "swiped \(dirStr) \(distance)px from (\(sx),\(sy))"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - ScrollTool

public struct ScrollTool: ToolDefinition {
    public let name = "scroll"
    public let description = "Post a scroll-wheel event. `lines` is the unit of a physical wheel notch. Optionally provide x/y — the cursor is moved there first so the scroll lands on the target view. Without x/y, scroll fires at the current cursor position."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "direction": JSONSchema.enumString(
                description: "Scroll direction. up/down scroll vertically; left/right horizontally.",
                values: ["up", "down", "left", "right"]
            ),
            "lines": JSONSchema.integer(
                description: "Number of scroll lines. Positive integer.",
                minimum: 1, maximum: 500
            ),
            "x": JSONSchema.integer(description: "Optional X coordinate — if set, cursor is moved here before scrolling."),
            "y": JSONSchema.integer(description: "Optional Y coordinate — if set, cursor is moved here before scrolling."),
        ], required: ["direction", "lines"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let dirStr = args["direction"] as? String,
              let direction = parseScrollDirection(dirStr) else {
            return "Error: direction must be one of up/down/left/right"
        }
        guard let lines = optionalInt("lines", from: args) else {
            return "Error: missing required parameter: lines"
        }
        let x = optionalInt("x", from: args)
        let y = optionalInt("y", from: args)
        let point: CGPoint? = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil

        do {
            try GestureExecutor.scroll(direction: direction, lines: lines, at: point)
            if let point {
                return "scrolled \(dirStr) \(lines) lines at (\(Int(point.x)),\(Int(point.y)))"
            }
            return "scrolled \(dirStr) \(lines) lines at cursor"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - LongPressTool

public struct LongPressTool: ToolDefinition {
    public let name = "long_press"
    public let description = "Press left button, hold for `duration_ms`, release. Useful for long-press gestures in apps that distinguish tap vs hold (e.g. Dock icons, some Mac App Store links)."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.integer(description: "X coordinate."),
            "y": JSONSchema.integer(description: "Y coordinate."),
            "duration_ms": JSONSchema.integer(
                description: "How long to hold in milliseconds. Default 500.",
                minimum: 1, maximum: 10_000
            ),
        ], required: ["x", "y"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let x = optionalInt("x", from: args), let y = optionalInt("y", from: args) else {
            return "Error: missing required parameters: x, y"
        }
        let durationMS = optionalInt("duration_ms", from: args) ?? 500
        do {
            try await GestureExecutor.longPress(
                at: CGPoint(x: x, y: y),
                duration: TimeInterval(durationMS) / 1000.0
            )
            return "long-pressed (\(x),\(y)) for \(durationMS)ms"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - TypeTextTool

public struct TypeTextTool: ToolDefinition {
    public let name = "type_text"
    public let description = "Type a string at the keyboard focus, character-by-character. ASCII characters go through the US-ANSI keycode table (shifted when needed); non-ASCII use `CGEventKeyboardSetUnicodeString` for direct injection. Note: Secure Input Mode (password fields, 1Password etc.) silently drops synthetic key events — callers should fall back to clipboard paste for those."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "Text to type."),
            "delay_ms": JSONSchema.integer(
                description: "Delay between keystrokes in milliseconds. Default 10. Set higher (30-50) for apps that drop fast input.",
                minimum: 0, maximum: 1000
            ),
        ], required: ["text"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let text = args["text"] as? String else {
            return "Error: missing required parameter: text"
        }
        let delayMS = optionalInt("delay_ms", from: args) ?? 10
        do {
            try await GestureExecutor.typeString(
                text,
                delayBetweenKeystrokes: TimeInterval(delayMS) / 1000.0
            )
            return "typed \(text.count) chars"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - KeyComboTool

public struct KeyComboTool: ToolDefinition {
    public let name = "key_combo"
    public let description = "Fire a keyboard shortcut like cmd+shift+s. Each entry is either a modifier (cmd/shift/option/ctrl/alt/fn/capslock) or a key name (a-z, 0-9, enter/esc/tab/space/delete/up/down/left/right/home/end/pageup/pagedown/f1-f12) or single-character punctuation (a single character in [] {} - = / \\ , . ; ' ` ~ etc.). Order doesn't matter — modifiers are identified by name."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "keys": JSONSchema.array(
                items: ["type": "string"],
                description: "Array of strings. Example: [\"cmd\",\"shift\",\"s\"] for cmd+shift+s; [\"cmd\",\"c\"] for copy."
            ),
        ], required: ["keys"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let rawKeys = args["keys"] as? [Any] else {
            return "Error: missing required parameter: keys (array of strings)"
        }
        let tokens = rawKeys.compactMap { $0 as? String }
        guard !tokens.isEmpty else {
            return "Error: keys must be a non-empty array of strings"
        }
        do {
            let (modifiers, keys) = try Self.parseKeyCombo(tokens)
            guard !keys.isEmpty else {
                return "Error: key combo must include at least one non-modifier key"
            }
            try GestureExecutor.keyCombo(keys: keys, modifiers: modifiers)
            return "pressed \(tokens.joined(separator: "+"))"
        } catch let err as KeyComboParseError {
            return "Error: unknown key '\(err.token)' in combo"
        } catch {
            return "Error: \(describe(error))"
        }
    }

    // MARK: - Parser

    /// Error thrown when a combo token can't be mapped to a modifier or key.
    struct KeyComboParseError: Error {
        let token: String
    }

    /// Parse a combo like `["cmd","shift","s"]` into `(modifiers, keys)`.
    /// Case-insensitive. Recognizes common aliases (cmd/command, alt/option, ctrl/control).
    static func parseKeyCombo(_ tokens: [String]) throws -> (modifiers: KeyModifiers, keys: [Key]) {
        var modifiers: KeyModifiers = []
        var keys: [Key] = []
        for raw in tokens {
            let token = raw.lowercased()
            // Modifiers first (including common aliases).
            if let mod = modifierFromToken(token) {
                modifiers.insert(mod)
                continue
            }
            if let key = keyFromToken(token) {
                keys.append(key)
                continue
            }
            throw KeyComboParseError(token: raw)
        }
        return (modifiers, keys)
    }

    private static func modifierFromToken(_ token: String) -> KeyModifiers? {
        switch token {
        case "cmd", "command", "meta", "super":    return .command
        case "shift":                              return .shift
        case "opt", "option", "alt":               return .option
        case "ctrl", "control":                    return .control
        case "fn", "function":                     return .function
        case "capslock", "caps":                   return .capsLock
        default: return nil
        }
    }

    private static func keyFromToken(_ token: String) -> Key? {
        switch token {
        case "enter", "return":       return .enter
        case "esc", "escape":         return .escape
        case "tab":                   return .tab
        case "space", "spacebar":     return .space
        case "delete", "backspace":   return .delete
        case "forwarddelete", "del":  return .forwardDelete
        case "home":                  return .home
        case "end":                   return .end
        case "pageup", "pgup":        return .pageUp
        case "pagedown", "pgdn":      return .pageDown
        case "up":                    return .up
        case "down":                  return .down
        case "left":                  return .left
        case "right":                 return .right
        case "f1":  return .f1
        case "f2":  return .f2
        case "f3":  return .f3
        case "f4":  return .f4
        case "f5":  return .f5
        case "f6":  return .f6
        case "f7":  return .f7
        case "f8":  return .f8
        case "f9":  return .f9
        case "f10": return .f10
        case "f11": return .f11
        case "f12": return .f12
        default:
            // Single character (letters / digits / punctuation).
            if token.count == 1, let c = token.first {
                return .character(c)
            }
            return nil
        }
    }
}

// MARK: - MoveMouseTool

public struct MoveMouseTool: ToolDefinition {
    public let name = "move_mouse"
    public let description = "Move the mouse cursor to a coordinate without clicking. Useful for hover-triggered UI (tooltips, menu reveals)."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.integer(description: "X coordinate in top-left pixel space."),
            "y": JSONSchema.integer(description: "Y coordinate in top-left pixel space."),
        ], required: ["x", "y"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let x = optionalInt("x", from: args), let y = optionalInt("y", from: args) else {
            return "Error: missing required parameters: x, y"
        }
        do {
            try GestureExecutor.moveMouse(to: CGPoint(x: x, y: y))
            return "moved mouse to (\(x),\(y))"
        } catch {
            return "Error: \(describe(error))"
        }
    }
}

// MARK: - Shared helpers

private func parseMouseButton(_ s: String?) -> MouseButton? {
    switch s?.lowercased() {
    case "left", nil:    return .left
    case "right":        return .right
    case "center":       return .center
    default:             return nil
    }
}

private func parseSwipeDirection(_ s: String) -> SwipeDirection? {
    switch s.lowercased() {
    case "left":  return .left
    case "right": return .right
    case "up":    return .up
    case "down":  return .down
    default: return nil
    }
}

private func parseScrollDirection(_ s: String) -> ScrollDirection? {
    switch s.lowercased() {
    case "up":    return .up
    case "down":  return .down
    case "left":  return .left
    case "right": return .right
    default: return nil
    }
}

private func describe(_ error: Error) -> String {
    if let ge = error as? GestureError {
        switch ge {
        case .accessibilityNotTrusted:
            return "Accessibility permission required. Grant access in System Settings → Privacy & Security → Accessibility."
        case .pointOutOfBounds(let p):
            return "point out of bounds: (\(Int(p.x)),\(Int(p.y)))"
        case .invalidKey(let k):
            return "invalid key: \(k)"
        case .eventCreationFailed:
            return "failed to create CGEvent"
        }
    }
    return error.localizedDescription
}
