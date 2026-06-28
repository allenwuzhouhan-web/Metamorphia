/*
 * Metamorphia – Intelligence Glass
 *
 * EXPLICIT-INVOKE ONLY accessor for the focused text field's selected text.
 *
 * ## Privacy contract
 * This file ONLY fires when the user explicitly invokes a Writing Tools action
 * (via the Writing Tools panel or the NSServices menu). It is never wired to
 * TriggerBus or any ambient observation channel.
 *
 * The secure-field gate mirrors the checks inside PrivacyFirewall.evaluate
 * (PrivacyFirewall.swift:232-237) but does NOT call PrivacyFirewall.admit,
 * because the firewall's allowedKinds whitelist fails closed on any kind not
 * registered for ambient emission — calling admit here would deny legitimate
 * text for the wrong reason while still blocking secure fields. Instead we
 * replicate the two relevant predicates directly:
 *   1. AX role == "AXSecureTextField"  (mirrors PrivacyFirewall.swift:232)
 *   2. SecureInputProbe.isActive()     (mirrors PrivacyFirewall.swift:235)
 * This gives identical security semantics at the relevant gates.
 *
 * ## SelectionTracker invariant preserved
 * SelectionTracker.swift is NOT modified; it remains range-length-only.
 * This file is the only place kAXSelectedTextAttribute is read for content.
 */

import AppKit
import ApplicationServices
import Foundation
import MetamorphiaPerception

// MARK: - TextFieldAccess

/// Reads and writes the selected text of the frontmost application's focused
/// element. All access is explicit-invoke only — never ambient.
@MainActor
enum TextFieldAccess {

    // MARK: - Capture

    /// A snapshot of the focused element at the moment of capture.
    struct Capture {
        /// PID of the owning application.
        let pid: pid_t
        /// AX role string, e.g. "AXTextArea".
        let role: String
        /// The selected text content (never empty after a successful capture).
        let text: String
    }

    // MARK: - Errors

    enum AccessError: Error {
        /// No frontmost application or no focused UI element.
        case noFocus
        /// The focused element is a secure text field; access denied.
        case secureField
        /// The selection is empty or the attribute is absent.
        case noSelection
        /// An AX call returned an unexpected error code.
        case axFailed
        /// The target process did not respond within the deadline.
        case timeout
    }

    // MARK: - Capture

    /// Read the selected text of the frontmost app's focused element.
    ///
    /// - Throws: `AccessError` describing why capture failed.
    /// - Returns: A `Capture` containing the pid, role, and selected text.
    static func captureSelection() throws -> Capture {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AccessError.noFocus
        }
        let pid = app.processIdentifier

        do {
            guard let capture = try AXTimeoutQueue.shared.run(pid: pid, timeout: 0.1, {
                Self.readCapture(pid: pid)
            }) else {
                throw AccessError.noFocus
            }
            return capture
        } catch is AXTimeoutError {
            throw AccessError.timeout
        } catch is AXPoisonedError {
            throw AccessError.timeout
        } catch let e as AccessError {
            throw e
        } catch {
            throw AccessError.axFailed
        }
    }

    // MARK: - Write-back

    /// Write `replacement` back into the focused element's current selection.
    ///
    /// Primary path: `AXUIElementSetAttributeValue` with `kAXSelectedTextAttribute`.
    /// Fallback: copy to clipboard and synthesize Cmd-V.
    ///
    /// - Parameters:
    ///   - replacement: The text to place in the current selection.
    ///   - capture: The `Capture` that identified the target process.
    static func writeBack(_ replacement: String, to capture: Capture) {
        let pid = capture.pid
        var succeeded = false

        // Attempt AX write under a short timeout.
        if let result = try? AXTimeoutQueue.shared.run(pid: pid, timeout: 0.1, { () -> Bool in
            let appElement = AXUIElementCreateApplication(pid)
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            ) == .success, let focusedRef else { return false }
            let focused = focusedRef as! AXUIElement  // swiftlint:disable:this force_cast

            let setResult = AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextAttribute as CFString,
                replacement as CFTypeRef
            )
            return setResult == .success
        }) {
            succeeded = result
        }

        if !succeeded {
            pasteViaClipboard(replacement)
        }
    }

    // MARK: - Private AX read

    /// Must be called from within an `AXTimeoutQueue.run` block. `nonisolated`
    /// because that block runs on the timeout queue, off the main actor; this
    /// method only touches the thread-safe AX C API and the nonisolated
    /// `SecureInputProbe.isActive()`.
    nonisolated private static func readCapture(pid: pid_t) -> Capture? {
        // Step 1: obtain the focused element.
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement  // swiftlint:disable:this force_cast

        // Step 2: read the role.
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXRoleAttribute as CFString,
            &roleRef
        ) == .success, let role = roleRef as? String else { return nil }

        // Step 3: secure-field gate (mirrors PrivacyFirewall.evaluate lines 232-237).
        if role == "AXSecureTextField" { return nil }
        if SecureInputProbe.isActive() { return nil }

        // Step 4: read the selected text content.
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &textRef
        ) == .success, let text = textRef as? String, !text.isEmpty else { return nil }

        return Capture(pid: pid, role: role, text: text)
    }

    // MARK: - Clipboard fallback

    private static func pasteViaClipboard(_ text: String) {
        // Save existing contents (best-effort; only saves the first plain-text item).
        let pb = NSPasteboard.general
        let prior = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        synthesizeCmdV()

        // Restore prior pasteboard contents after a brief delay so that the
        // Cmd-V keystroke has time to be delivered before we overwrite again.
        let restore = prior
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let restore {
                pb.clearContents()
                pb.setString(restore, forType: .string)
            }
        }
    }

    private static func synthesizeCmdV() {
        // Guard against synthesizing keystrokes while secure event input is active.
        guard !SecureInputProbe.isActive() else { return }

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 0x09  // 'v'

        guard let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let vUp   = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false)
        else { return }

        vDown.flags = .maskCommand
        vUp.flags   = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
    }
}
