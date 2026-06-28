import AppKit
import ApplicationServices

/// Accessibility bridge that lets Writing Tools read the user's current
/// selection (or the focused window's visible text) in any app and write
/// replacement text back into it.
///
/// Everything here is permission-gated: macOS only answers AX queries when
/// the host app is a trusted accessibility client. Every entry point degrades
/// to `nil`/`false` when permission is missing or any AX call fails — it never
/// crashes, force-unwraps a `CFTypeRef`, or calls `fatalError`.
@MainActor
public enum TextFieldAccess {

    // MARK: - Trust

    /// True if the app is a trusted accessibility client. UI can prompt when false.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Reading the selection

    /// The currently selected text in the frontmost app's focused UI element
    /// (`kAXSelectedTextAttribute`). Returns `nil` when there is no selection,
    /// no focused element, or no accessibility permission.
    public static func selectedText() -> String? {
        guard isTrusted, let element = focusedElement() else { return nil }
        // Never return a selection inside a password field — mirror the
        // secure-field guard used in the window-harvest path. If the subrole
        // attribute is missing, this simply reads as `nil` and we proceed.
        if copyStringAttribute(element, kAXSubroleAttribute) == "AXSecureTextField" {
            return nil
        }
        guard let text = copyStringAttribute(element, kAXSelectedTextAttribute),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Reading the focused window

    /// Best-effort visible text of the focused window. Walks the AX tree from
    /// the focused window down, collecting `AXValue`/`AXStaticText` content, and
    /// caps the result at `maxChars`. Returns `nil` when unavailable.
    public static func focusedWindowText(maxChars: Int) -> String? {
        guard isTrusted, maxChars > 0 else { return nil }
        guard let app = focusedApplication() else { return nil }

        // Prefer the focused window; fall back to the focused element's window
        // or the element itself so single-window utilities still yield text.
        let root: AXUIElement
        if let window = copyElementAttribute(app, kAXFocusedWindowAttribute) {
            root = window
        } else if let element = focusedElement() {
            root = element
        } else {
            return nil
        }

        var collected = ""
        collectText(from: root, into: &collected, maxChars: maxChars, depthBudget: 4_000)

        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Writing the selection

    /// Replace the current selection with `text`. Tries to set
    /// `kAXSelectedTextAttribute` on the focused element when writable;
    /// otherwise falls back to copying `text` to the pasteboard and
    /// synthesizing Cmd+V (restoring the prior pasteboard afterward).
    /// Returns `true` on success.
    @discardableResult
    public static func replaceSelection(with text: String) -> Bool {
        guard isTrusted else { return false }

        if let element = focusedElement(), setSelectedText(element, text) {
            return true
        }

        return pasteViaClipboard(text)
    }

    // MARK: - Pasteboard

    /// Put `text` on the general pasteboard (for an explicit Copy button).
    public static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Focused element / app resolution

    /// The system-wide focused UI element, resolved via the focused app so we
    /// honor the frontmost application rather than our own process.
    private static func focusedElement() -> AXUIElement? {
        if let app = focusedApplication(),
           let element = copyElementAttribute(app, kAXFocusedUIElementAttribute) {
            return element
        }
        // Fallback: ask the system-wide element directly.
        let systemWide = AXUIElementCreateSystemWide()
        return copyElementAttribute(systemWide, kAXFocusedUIElementAttribute)
    }

    /// The frontmost application's AX element.
    private static func focusedApplication() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        return copyElementAttribute(systemWide, kAXFocusedApplicationAttribute)
    }

    // MARK: - Writing helpers

    /// Attempt to set the selected-text attribute. Checks settability first so
    /// we can fall back cleanly when the element is read-only.
    private static func setSelectedText(_ element: AXUIElement, _ text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return result == .success
    }

    /// Copy `text` to the pasteboard and synthesize Cmd+V into the frontmost
    /// app, then restore the previous pasteboard contents shortly after.
    ///
    /// We snapshot the *whole* pasteboard (every item and all of its types),
    /// not just the `.string` flavor, so non-text content survives the round
    /// trip. On restore we compare `changeCount`: if the user copied something
    /// new during the delay, their content wins and we leave it alone.
    private static func pasteViaClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        // Record the change count produced by *our* write so we can tell our
        // own paste apart from a fresh user copy made during the delay.
        let mineChangeCount = pasteboard.changeCount

        guard synthesizePaste() else {
            // Restore immediately — no paste was delivered. Our write is still
            // the latest change, so this is always safe.
            restorePasteboard(snapshot, ifChangeCountEquals: mineChangeCount)
            return false
        }

        // Let the target app consume the paste before we put the old value back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            restorePasteboard(snapshot, ifChangeCountEquals: mineChangeCount)
        }
        return true
    }

    /// Deep-copy every item on `pasteboard` so the contents outlive the
    /// upcoming `clearContents()`. `NSPasteboardItem`s are owned by the
    /// pasteboard, so we rebuild fresh items holding each type's raw data.
    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Restore the snapshotted items, but only if the pasteboard hasn't changed
    /// since our synthesized paste. If the user copied something new in the
    /// meantime (`changeCount` moved past ours), leave their content alone.
    private static func restorePasteboard(_ snapshot: [NSPasteboardItem], ifChangeCountEquals expected: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expected else { return }
        pasteboard.clearContents()
        if !snapshot.isEmpty {
            pasteboard.writeObjects(snapshot)
        }
    }

    /// Synthesize a Cmd+V key-down/key-up pair on the HID event tap. The `v`
    /// key is virtual keycode 9. Returns `false` if events can't be created.
    private static func synthesizePaste() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Safe CFTypeRef accessors

    /// Copy a string attribute, guarding the type so a non-string value can't
    /// crash us via a force cast.
    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Copy an attribute that should be an `AXUIElement`, verifying the CFTypeID
    /// before casting (a force cast on the wrong type crashes the process).
    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Copy the children of an element, guarding the array cast.
    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    // MARK: - Text harvesting

    /// Depth-first walk that accumulates readable text from `AXValue` and
    /// static-text elements. `depthBudget` caps the number of visited nodes so
    /// a pathological tree can't hang us; collection stops once `maxChars` is hit.
    private static func collectText(
        from element: AXUIElement,
        into accumulator: inout String,
        maxChars: Int,
        depthBudget: Int
    ) {
        guard accumulator.count < maxChars else { return }

        var remainingNodes = depthBudget
        // Iterative stack walk to avoid deep recursion on large windows.
        var stack: [AXUIElement] = [element]

        while let node = stack.popLast() {
            if accumulator.count >= maxChars { return }
            remainingNodes -= 1
            if remainingNodes < 0 { return }

            let role = copyStringAttribute(node, kAXRoleAttribute)

            // Skip secure fields — never harvest passwords.
            if copyStringAttribute(node, kAXSubroleAttribute) == "AXSecureTextField" {
                continue
            }

            if let text = readableText(of: node, role: role) {
                appendText(text, to: &accumulator, maxChars: maxChars)
                if accumulator.count >= maxChars { return }
            }

            // Push children in reverse so they're visited in natural order.
            let children = copyChildren(node)
            if !children.isEmpty {
                for child in children.reversed() {
                    stack.append(child)
                }
            }
        }
    }

    /// Pull the best readable text out of a single node.
    private static func readableText(of element: AXUIElement, role: String?) -> String? {
        if role == kAXStaticTextRole {
            if let value = copyStringAttribute(element, kAXValueAttribute), !value.isEmpty { return value }
            if let title = copyStringAttribute(element, kAXTitleAttribute), !title.isEmpty { return title }
            return nil
        }

        // Text areas / fields expose their content through AXValue.
        if role == kAXTextAreaRole || role == kAXTextFieldRole {
            if let value = copyStringAttribute(element, kAXValueAttribute), !value.isEmpty { return value }
        }

        return nil
    }

    /// Append `text` (plus a separator) without overflowing `maxChars`.
    private static func appendText(_ text: String, to accumulator: inout String, maxChars: Int) {
        if !accumulator.isEmpty {
            accumulator.append("\n")
        }
        let room = maxChars - accumulator.count
        guard room > 0 else { return }
        if text.count <= room {
            accumulator.append(text)
        } else {
            accumulator.append(String(text.prefix(room)))
        }
    }
}
