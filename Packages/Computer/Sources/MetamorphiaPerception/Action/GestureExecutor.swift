import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

// MARK: - Public Enums

/// Mouse button for click / drag / press events.
public enum MouseButton: Sendable {
    case left, right, center

    /// Convert to `FeedbackLoopSuppressor.MouseButton` for suppressor registration.
    func toSuppressorButton() -> FeedbackLoopSuppressor.MouseButton {
        switch self {
        case .left:   return .left
        case .right:  return .right
        case .center: return .other
        }
    }

    /// The `CGMouseButton` wire value expected by `CGEvent`.
    var cgButton: CGMouseButton {
        switch self {
        case .left:   return .left
        case .right:  return .right
        case .center: return .center
        }
    }

    /// Which `CGEventType` corresponds to "button down" for this mouse button.
    var downEventType: CGEventType {
        switch self {
        case .left:   return .leftMouseDown
        case .right:  return .rightMouseDown
        case .center: return .otherMouseDown
        }
    }

    /// Which `CGEventType` corresponds to "button up" for this mouse button.
    var upEventType: CGEventType {
        switch self {
        case .left:   return .leftMouseUp
        case .right:  return .rightMouseUp
        case .center: return .otherMouseUp
        }
    }

    /// Which `CGEventType` corresponds to "button held while moving" for this
    /// mouse button. Used for drag interpolation.
    var draggedEventType: CGEventType {
        switch self {
        case .left:   return .leftMouseDragged
        case .right:  return .rightMouseDragged
        case .center: return .otherMouseDragged
        }
    }
}

/// Cardinal direction for a swipe. A swipe is a drag that starts at `origin`
/// and moves `distance` pixels in the named direction.
public enum SwipeDirection: Sendable {
    case left, right, up, down
}

/// Cardinal direction for a scroll wheel event.
public enum ScrollDirection: Sendable {
    case up, down, left, right
}

/// Bitfield of modifier keys held during a key/click event. Converted to
/// `CGEventFlags` when posting.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command  = KeyModifiers(rawValue: 1 << 0)
    public static let shift    = KeyModifiers(rawValue: 1 << 1)
    public static let option   = KeyModifiers(rawValue: 1 << 2)
    public static let control  = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)

    /// Convert to the `CGEventFlags` bitfield expected by `CGEvent.flags`.
    public var cgEventFlags: CGEventFlags {
        var flags = CGEventFlags(rawValue: 0)
        if contains(.command)  { flags.insert(.maskCommand) }
        if contains(.shift)    { flags.insert(.maskShift) }
        if contains(.option)   { flags.insert(.maskAlternate) }
        if contains(.control)  { flags.insert(.maskControl) }
        if contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

/// A single key identity. Either an ASCII character that we'll look up in
/// `KeyMap`, a raw virtual keycode, or a named non-character key.
public enum Key: Sendable {
    case character(Character)
    case keyCode(CGKeyCode)
    // Named keys
    case enter, escape, tab, space, delete, forwardDelete
    case home, end, pageUp, pageDown
    case up, down, left, right
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

/// Errors thrown by `GestureExecutor`.
public enum GestureError: Error, Sendable, Equatable {
    case accessibilityNotTrusted
    case pointOutOfBounds(CGPoint)
    case invalidKey(String)
    case eventCreationFailed
}

// MARK: - GestureExecutor

/// Programmatic control of mouse and keyboard via `CGEvent`. All coordinates
/// use macOS's top-left `CGEvent` space (y grows downward). Use
/// `GestureExecutor.flipY(_:screen:)` to convert from `NSScreen`'s bottom-left
/// Cartesian space when needed.
///
/// **Permissions:** clicking and key synthesis both require the host process
/// to be listed under System Settings → Privacy & Security → Accessibility.
/// Use `isAccessibilityTrusted` to probe; `requestAccessibilityTrust` will
/// trigger the system prompt once per user session.
///
/// **Secure Input Mode:** password fields, some terminals, and 1Password/etc.
/// enable Secure Input while focused — synthetic key events to those fields
/// are silently dropped by the OS. There is no reliable workaround; detection
/// is via `IsSecureEventInputEnabled()`. Callers that must type into secure
/// fields should warn the user and fall back to clipboard paste.
public enum GestureExecutor {

    // MARK: - Mouse Clicks

    /// Click at `point` in top-left CGEvent coordinates. `count` fires the
    /// event sequence `count` times with the `kCGMouseEventClickState` counter
    /// incremented, which is how macOS recognizes double/triple clicks.
    public static func click(
        at point: CGPoint,
        button: MouseButton = .left,
        count: Int = 1,
        suppressor: FeedbackLoopSuppressor? = .shared
    ) throws {
        let clamped = try clamp(point: point)
        try ensureAccessibilityTrusted()

        // Notify suppressor before posting so downstream perception events can
        // be classified as .agent origin. Fire-and-forget via Task — the handle
        // is discarded; classify() scans outstanding handles by fingerprint.
        if let suppressor {
            Task { await suppressor.beginAction(kind: .click(clamped, button.toSuppressorButton())) }
        }

        for i in 1...max(count, 1) {
            try postMouseEvent(
                type: button.downEventType,
                at: clamped,
                button: button,
                clickState: i
            )
            try postMouseEvent(
                type: button.upEventType,
                at: clamped,
                button: button,
                clickState: i
            )
            // Tight enough that macOS considers consecutive clicks a multi-click.
            if i < count {
                usleep(50_000) // 50 ms
            }
        }
    }

    public static func doubleClick(at point: CGPoint, button: MouseButton = .left) throws {
        try click(at: point, button: button, count: 2)
    }

    public static func rightClick(at point: CGPoint) throws {
        try click(at: point, button: .right, count: 1)
    }

    // MARK: - Continuous Motion

    /// Press-drag-release from `start` to `end` with intermediate
    /// `mouseDragged` events every ~16 ms for smooth motion.
    public static func drag(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval = 0.25,
        button: MouseButton = .left
    ) async throws {
        let clampedStart = try clamp(point: start)
        let clampedEnd = try clamp(point: end)
        try ensureAccessibilityTrusted()

        try postMouseEvent(
            type: button.downEventType,
            at: clampedStart,
            button: button,
            clickState: 1
        )

        let steps = max(1, Int(duration / 0.016))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let px = clampedStart.x + (clampedEnd.x - clampedStart.x) * CGFloat(t)
            let py = clampedStart.y + (clampedEnd.y - clampedStart.y) * CGFloat(t)
            try postMouseEvent(
                type: button.draggedEventType,
                at: CGPoint(x: px, y: py),
                button: button,
                clickState: 1
            )
            try await Task.sleep(nanoseconds: 16_000_000) // 16 ms per frame
        }

        try postMouseEvent(
            type: button.upEventType,
            at: clampedEnd,
            button: button,
            clickState: 1
        )
    }

    /// A swipe is a drag in a cardinal direction by `distance` pixels.
    public static func swipe(
        direction: SwipeDirection,
        distance: CGFloat,
        startAt origin: CGPoint,
        duration: TimeInterval = 0.15
    ) async throws {
        let end: CGPoint
        switch direction {
        case .left:  end = CGPoint(x: origin.x - distance, y: origin.y)
        case .right: end = CGPoint(x: origin.x + distance, y: origin.y)
        case .up:    end = CGPoint(x: origin.x, y: origin.y - distance)
        case .down:  end = CGPoint(x: origin.x, y: origin.y + distance)
        }
        try await drag(from: origin, to: end, duration: duration, button: .left)
    }

    // MARK: - Scrolling

    /// Line-based scroll wheel event. `lines` is the unit consumers expect
    /// (one notch of a physical wheel). Horizontal scroll maps to axis 2;
    /// vertical scroll maps to axis 1.
    public static func scroll(
        direction: ScrollDirection,
        lines: Int,
        at point: CGPoint? = nil,
        suppressor: FeedbackLoopSuppressor? = .shared
    ) throws {
        try ensureAccessibilityTrusted()
        if let pt = point {
            try moveMouse(to: pt)
            if let suppressor {
                Task { await suppressor.beginAction(kind: .scroll(pt)) }
            }
        } else if let suppressor {
            Task { await suppressor.beginAction(kind: .scroll(currentMousePosition())) }
        }
        // Sign convention: positive Y = scroll up; positive X = scroll right.
        // Note that macOS "natural scrolling" inverts the physical wheel, but
        // at the CGEvent level we're emitting the logical content motion.
        let (axis1, axis2): (Int32, Int32)
        switch direction {
        case .up:    axis1 =  Int32(lines); axis2 = 0
        case .down:  axis1 = -Int32(lines); axis2 = 0
        case .left:  axis1 = 0; axis2 = -Int32(lines)
        case .right: axis1 = 0; axis2 =  Int32(lines)
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource(),
            units: .line,
            wheelCount: 2,
            wheel1: axis1,
            wheel2: axis2,
            wheel3: 0
        ) else {
            throw GestureError.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    /// Pixel-precise scroll that interpolates across `duration` for smooth
    /// momentum-like motion.
    public static func smoothScroll(
        direction: ScrollDirection,
        pixels: CGFloat,
        duration: TimeInterval = 0.25,
        at point: CGPoint? = nil
    ) async throws {
        try ensureAccessibilityTrusted()
        if let pt = point {
            try moveMouse(to: pt)
        }
        let steps = max(1, Int(duration / 0.016))
        let perStep = pixels / CGFloat(steps)
        for _ in 1...steps {
            let (axis1, axis2): (Int32, Int32)
            let delta = Int32(perStep.rounded())
            switch direction {
            case .up:    axis1 =  delta; axis2 = 0
            case .down:  axis1 = -delta; axis2 = 0
            case .left:  axis1 = 0; axis2 = -delta
            case .right: axis1 = 0; axis2 =  delta
            }
            guard let event = CGEvent(
                scrollWheelEvent2Source: eventSource(),
                units: .pixel,
                wheelCount: 2,
                wheel1: axis1,
                wheel2: axis2,
                wheel3: 0
            ) else {
                throw GestureError.eventCreationFailed
            }
            event.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    // MARK: - Press and Hold

    /// Press the button, wait `duration`, release. Useful for "long press"
    /// interactions on touch-bar or canvas apps that distinguish tap vs. hold.
    public static func longPress(
        at point: CGPoint,
        duration: TimeInterval = 0.5,
        button: MouseButton = .left
    ) async throws {
        let clamped = try clamp(point: point)
        try ensureAccessibilityTrusted()
        try postMouseEvent(
            type: button.downEventType,
            at: clamped,
            button: button,
            clickState: 1
        )
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        try postMouseEvent(
            type: button.upEventType,
            at: clamped,
            button: button,
            clickState: 1
        )
    }

    // MARK: - Keyboard

    public static func keyDown(_ key: Key, modifiers: KeyModifiers = []) throws {
        try ensureAccessibilityTrusted()
        try postKeyboardEvent(key: key, keyDown: true, modifiers: modifiers)
    }

    public static func keyUp(_ key: Key, modifiers: KeyModifiers = []) throws {
        try ensureAccessibilityTrusted()
        try postKeyboardEvent(key: key, keyDown: false, modifiers: modifiers)
    }

    public static func keyPress(
        _ key: Key,
        modifiers: KeyModifiers = [],
        suppressor: FeedbackLoopSuppressor? = .shared
    ) throws {
        if let suppressor {
            let code = try resolveKeyCode(key)
            Task { await suppressor.beginAction(kind: .key(code)) }
        }
        try keyDown(key, modifiers: modifiers)
        try keyUp(key, modifiers: modifiers)
    }

    /// Type `text` character-by-character, honoring ASCII shift requirements.
    /// Non-ASCII characters (e.g. `é`, emoji, CJK) are injected via
    /// `CGEventKeyboardSetUnicodeString` on a synthetic key-0 event.
    public static func typeString(
        _ text: String,
        delayBetweenKeystrokes: TimeInterval = 0.01,
        suppressor: FeedbackLoopSuppressor? = .shared
    ) async throws {
        try ensureAccessibilityTrusted()
        // Register a single paste-class suppression handle for the whole string
        // injection. Individual keystroke handles would flood the outstanding list.
        if let suppressor {
            Task { await suppressor.beginAction(kind: .paste) }
        }
        for step in planTyping(text: text) {
            switch step.mode {
            case .keyCode(let code, let mods):
                try postRawKey(keyCode: code, keyDown: true, flags: mods.cgEventFlags)
                try postRawKey(keyCode: code, keyDown: false, flags: mods.cgEventFlags)
            case .unicode(let scalar):
                try postUnicodeInjection(scalar: scalar)
            }
            if delayBetweenKeystrokes > 0 {
                try await Task.sleep(
                    nanoseconds: UInt64(delayBetweenKeystrokes * 1_000_000_000)
                )
            }
        }
    }

    /// Press modifiers down, then keys in order; release keys in reverse,
    /// then modifiers in reverse. The OS sees modifiers as held for the full
    /// sequence, so chord-style shortcuts (e.g. cmd+shift+3) fire correctly.
    public static func keyCombo(keys: [Key], modifiers: KeyModifiers) throws {
        try ensureAccessibilityTrusted()
        // Press modifiers (as raw events so the flags register before the main key).
        try pressModifiers(modifiers, down: true)
        // Press each key down in order with the modifier flags set.
        var keyCodes: [CGKeyCode] = []
        for key in keys {
            let code = try resolveKeyCode(key)
            keyCodes.append(code)
            try postRawKey(keyCode: code, keyDown: true, flags: modifiers.cgEventFlags)
        }
        // Release in reverse.
        for code in keyCodes.reversed() {
            try postRawKey(keyCode: code, keyDown: false, flags: modifiers.cgEventFlags)
        }
        try pressModifiers(modifiers, down: false)
    }

    // MARK: - Mouse Positioning

    public static func moveMouse(to point: CGPoint) throws {
        let clamped = try clamp(point: point)
        try ensureAccessibilityTrusted()
        guard let event = CGEvent(
            mouseEventSource: eventSource(),
            mouseType: .mouseMoved,
            mouseCursorPosition: clamped,
            mouseButton: .left
        ) else {
            throw GestureError.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    public static func currentMousePosition() -> CGPoint {
        // `CGEvent(source: nil)` returns a generic event whose `.location`
        // reflects the current cursor position in global top-left coordinates.
        if let event = CGEvent(source: nil) {
            return event.location
        }
        return .zero
    }

    // MARK: - Introspection

    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Probe the accessibility trust state, optionally showing the system
    /// prompt. Returns the trusted boolean. Note: the prompt is async — a
    /// `false` return does not mean the user rejected permission, only that
    /// it isn't granted yet.
    @discardableResult
    public static func requestAccessibilityTrust(showPrompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: showPrompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Internal (exposed for tests)

    /// Clamp `point` to the union of all `NSScreen` frames. Throws
    /// `.pointOutOfBounds` if the unclamped point lies more than 200 px
    /// outside every display.
    internal static func clamp(point: CGPoint) throws -> CGPoint {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            // No display enumerable (CI / headless). Pass through — the OS
            // will itself reject anything weird.
            return point
        }

        // Union of all screen frames, converted to top-left CGEvent space.
        // Each NSScreen frame is in bottom-left Cartesian w.r.t. the primary
        // display. Primary (screens[0]) sets the max-Y anchor.
        var union = CGRect.null
        for screen in screens {
            union = union.union(topLeftFrame(for: screen))
        }

        // Enforce the 200 px slack: reject anything unreasonably off-screen.
        let slack: CGFloat = 200
        let withinSlack = point.x >= union.minX - slack
            && point.x <= union.maxX + slack
            && point.y >= union.minY - slack
            && point.y <= union.maxY + slack
        if !withinSlack {
            throw GestureError.pointOutOfBounds(point)
        }

        // Clamp into the union rect (so off-screen-but-close points still
        // click the nearest corner — friendlier than hard-failing).
        let x = min(max(point.x, union.minX), union.maxX - 1)
        let y = min(max(point.y, union.minY), union.maxY - 1)
        return CGPoint(x: x, y: y)
    }

    /// Convert an `NSScreen` frame (bottom-left Cartesian, y up, primary
    /// display height = `NSScreen.screens[0].frame.height`) into top-left
    /// CGEvent space (y down, origin at top-left of the primary display).
    internal static func topLeftFrame(for screen: NSScreen) -> CGRect {
        let primary = NSScreen.screens.first?.frame ?? screen.frame
        let frame = screen.frame
        // In AppKit bottom-left space, a screen with frame (x=0, y=-900, w=1440, h=900)
        // sits *below* the primary display. Flip y: topY = primary.maxY - screen.maxY.
        let topY = primary.maxY - frame.maxY
        return CGRect(x: frame.minX, y: topY, width: frame.width, height: frame.height)
    }

    /// Convert a point between `NSScreen` Cartesian (bottom-left) and
    /// `CGEvent` top-left coordinates. The operation is its own inverse
    /// (involution): `flipY(flipY(p, s), s) == p`.
    internal static func flipY(_ point: CGPoint, screen: NSScreen) -> CGPoint {
        let frame = screen.frame
        // Distance from the bottom of this screen (y=frame.minY) to the point
        // equals the distance from the top of the converted point. The primary
        // anchor also applies when converting between global NSScreen and
        // global CGEvent, but the screen-local involution is simpler here.
        let flippedY = frame.maxY - (point.y - frame.minY) - frame.minY
        return CGPoint(x: point.x, y: flippedY)
    }

    // MARK: - Internal: Typing plan

    /// One unit of work in a typing plan. Either a plain key-code press
    /// (optionally shifted) or a unicode string injection for non-ASCII.
    internal struct TypingStep: Equatable, Sendable {
        enum Mode: Equatable, Sendable {
            case keyCode(CGKeyCode, KeyModifiers)
            case unicode(UnicodeScalar)
        }
        let mode: Mode
    }

    /// Plan the sequence of events needed to type `text`. Exposed internally
    /// for test coverage; the live typing path calls this then posts events.
    internal static func planTyping(text: String) -> [TypingStep] {
        var plan: [TypingStep] = []
        for scalar in text.unicodeScalars {
            if let (code, needsShift) = KeyMap.asciiKey(for: scalar) {
                let mods: KeyModifiers = needsShift ? .shift : []
                plan.append(TypingStep(mode: .keyCode(code, mods)))
            } else {
                plan.append(TypingStep(mode: .unicode(scalar)))
            }
        }
        return plan
    }

    // MARK: - Private: event posting

    private static func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private static func postMouseEvent(
        type: CGEventType,
        at point: CGPoint,
        button: MouseButton,
        clickState: Int
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: eventSource(),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        ) else {
            throw GestureError.eventCreationFailed
        }
        // Required for double/triple click recognition.
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    private static func postKeyboardEvent(
        key: Key,
        keyDown: Bool,
        modifiers: KeyModifiers
    ) throws {
        let code = try resolveKeyCode(key)
        try postRawKey(keyCode: code, keyDown: keyDown, flags: modifiers.cgEventFlags)
    }

    private static func postRawKey(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags
    ) throws {
        guard let event = CGEvent(
            keyboardEventSource: eventSource(),
            virtualKey: keyCode,
            keyDown: keyDown
        ) else {
            throw GestureError.eventCreationFailed
        }
        if !flags.isEmpty {
            event.flags = flags
        }
        event.post(tap: .cghidEventTap)
    }

    private static func postUnicodeInjection(scalar: UnicodeScalar) throws {
        // Create a synthetic key event on keyCode 0 and overwrite its unicode
        // payload. Both down and up carry the character — matches how most
        // IMEs drive the system.
        guard let down = CGEvent(
            keyboardEventSource: eventSource(),
            virtualKey: 0,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: eventSource(),
            virtualKey: 0,
            keyDown: false
        ) else {
            throw GestureError.eventCreationFailed
        }
        let utf16 = Array(String(scalar).utf16)
        utf16.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                down.keyboardSetUnicodeString(
                    stringLength: buf.count,
                    unicodeString: base
                )
                up.keyboardSetUnicodeString(
                    stringLength: buf.count,
                    unicodeString: base
                )
            }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func pressModifiers(_ mods: KeyModifiers, down: Bool) throws {
        // Raw modifier keycodes (left-side variants).
        let pairs: [(KeyModifiers, CGKeyCode)] = [
            (.command, 0x37), // Left Command
            (.shift,   0x38), // Left Shift
            (.option,  0x3A), // Left Option
            (.control, 0x3B), // Left Control
            (.function,0x3F), // Fn
            (.capsLock,0x39), // Caps Lock
        ]
        let ordered = down ? pairs : pairs.reversed()
        for (mod, code) in ordered where mods.contains(mod) {
            try postRawKey(keyCode: code, keyDown: down, flags: [])
        }
    }

    private static func ensureAccessibilityTrusted() throws {
        // In CI / test mode we skip this check so schema tests run fine.
        let env = ProcessInfo.processInfo.environment
        if env["OMNI_CI"] != nil || env["CI"] != nil || env["GITHUB_ACTIONS"] != nil {
            return
        }
        guard AXIsProcessTrusted() || requestAccessibilityTrust(showPrompt: true) else {
            throw GestureError.accessibilityNotTrusted
        }
    }

    /// Lookup the raw `CGKeyCode` for a `Key`. Characters go through
    /// `KeyMap.asciiKey`; unknown characters throw `.invalidKey`.
    internal static func resolveKeyCode(_ key: Key) throws -> CGKeyCode {
        switch key {
        case .keyCode(let code):
            return code
        case .character(let c):
            for scalar in c.unicodeScalars {
                if let (code, _) = KeyMap.asciiKey(for: scalar) {
                    return code
                }
            }
            throw GestureError.invalidKey(String(c))

        case .enter:         return 0x24
        case .escape:        return 0x35
        case .tab:           return 0x30
        case .space:         return 0x31
        case .delete:        return 0x33 // Backspace
        case .forwardDelete: return 0x75 // Forward Delete
        case .home:          return 0x73
        case .end:           return 0x77
        case .pageUp:        return 0x74
        case .pageDown:      return 0x79
        case .up:            return 0x7E
        case .down:          return 0x7D
        case .left:          return 0x7B
        case .right:         return 0x7C
        case .f1:            return 0x7A
        case .f2:            return 0x78
        case .f3:            return 0x63
        case .f4:            return 0x76
        case .f5:            return 0x60
        case .f6:            return 0x61
        case .f7:            return 0x62
        case .f8:            return 0x64
        case .f9:            return 0x65
        case .f10:           return 0x6D
        case .f11:           return 0x67
        case .f12:           return 0x6F
        }
    }
}

// MARK: - KeyMap

/// Static character-to-keycode mapping for US-ANSI layout. Shifted characters
/// are folded in (e.g. `A` returns (0x00, needsShift: true)). Non-ASCII
/// characters return `nil` — those go through `CGEventKeyboardSetUnicodeString`.
internal enum KeyMap {

    /// Lookup an ASCII scalar. Returns `(keyCode, needsShift)` where
    /// `needsShift` tells the caller to hold Shift.
    static func asciiKey(for scalar: UnicodeScalar) -> (CGKeyCode, Bool)? {
        if let raw = unshifted[scalar] {
            return (raw, false)
        }
        if let raw = shifted[scalar] {
            return (raw, true)
        }
        return nil
    }

    /// Convenience for named test assertions like `KeyMap.keyCode(for: "a")`.
    /// Returns only the keycode; the caller tracks shift state.
    static func keyCode(for char: Character) -> CGKeyCode? {
        for scalar in char.unicodeScalars {
            if let (code, _) = asciiKey(for: scalar) {
                return code
            }
        }
        return nil
    }

    // MARK: - Tables (US ANSI layout)

    /// Characters that require NO modifier. Source: Apple's
    /// /System/Library/Frameworks/Carbon.framework/…/Events.h.
    private static let unshifted: [UnicodeScalar: CGKeyCode] = [
        // Letters a-z
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04,
        "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F,
        "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D,
        "m": 0x2E,

        // Digits 0-9
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16,
        "5": 0x17, "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,

        // Punctuation (unshifted side)
        "=":  0x18,
        "-":  0x1B,
        "]":  0x1E,
        "[":  0x21,
        "'":  0x27,
        ";":  0x29,
        "\\": 0x2A,
        ",":  0x2B,
        "/":  0x2C,
        ".":  0x2F,
        "`":  0x32,

        // Whitespace
        " ":  0x31, // space
        "\t": 0x30, // tab
        "\n": 0x24, // enter → newline
        "\r": 0x24, // carriage return → enter
    ]

    /// Characters produced by holding Shift (same physical keycodes as their
    /// `unshifted` counterparts).
    private static let shifted: [UnicodeScalar: CGKeyCode] = [
        // Capital letters — same codes as their lowercase pair
        "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04,
        "G": 0x05, "Z": 0x06, "X": 0x07, "C": 0x08, "V": 0x09,
        "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F,
        "Y": 0x10, "T": 0x11, "O": 0x1F, "U": 0x20, "I": 0x22,
        "P": 0x23, "L": 0x25, "J": 0x26, "K": 0x28, "N": 0x2D,
        "M": 0x2E,

        // Shifted digits → punctuation row
        "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "^": 0x16,
        "%": 0x17, "(": 0x19, "&": 0x1A, "*": 0x1C, ")": 0x1D,

        // Shifted punctuation
        "+":  0x18,
        "_":  0x1B,
        "}":  0x1E,
        "{":  0x21,
        "\"": 0x27,
        ":":  0x29,
        "|":  0x2A,
        "<":  0x2B,
        "?":  0x2C,
        ">":  0x2F,
        "~":  0x32,
    ]
}
