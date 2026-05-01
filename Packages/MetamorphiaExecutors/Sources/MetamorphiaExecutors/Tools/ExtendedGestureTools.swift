import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - WaitTool

/// Sleep for a bounded duration. Exists so the LLM can express "wait for a
/// modal animation to settle" as one tool call instead of asking the host
/// process to add a `Task.sleep`. Capped at 5 s — long waits are a sign the
/// agent should be observing instead of blocking.
public struct WaitTool: ToolDefinition {
    public let name = "wait"
    public let description = "Wait for a bounded number of milliseconds. Useful between computer_batch steps to let animations settle before checking state. Capped at 5000 ms — longer waits are almost always a signal to re-perceive rather than block."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "ms": JSONSchema.integer(
                description: "Milliseconds to wait. Clamped to 0–5000.",
                minimum: 0, maximum: 5_000
            ),
        ], required: ["ms"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            do { args = try parseArguments(arguments) }
            catch { return "Error: failed to parse arguments: \(error.localizedDescription)" }
        }
        let raw = optionalInt("ms", from: args) ?? 0
        let clamped = max(0, min(5_000, raw))
        try await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
        return "waited \(clamped)ms"
    }
}

// MARK: - HoldKeyTool

/// Press a key, hold for N ms, release. Useful for triggering auto-repeat
/// (arrow keys scrolling a list, game-style held controls) and for chords
/// with long modifier windows (⌥-drag for duplicating Finder items).
/// Capped at 3 s so a runaway tool call doesn't jam the keyboard.
public struct HoldKeyTool: ToolDefinition {
    public let name = "hold_key"
    public let description = "Press a key, hold it for a duration, then release. Key names match key_combo tokens (enter, esc, tab, space, delete, up/down/left/right, f1-f12, or a single character). Optional modifiers array uses the same vocabulary as key_combo (cmd, shift, opt, ctrl). Duration capped at 3000 ms."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "key": JSONSchema.string(
                description: "Key token. Single character ('a', '2', '=') or named key (enter, esc, tab, space, delete, up, down, left, right, home, end, pageup, pagedown, f1–f12)."
            ),
            "ms": JSONSchema.integer(
                description: "Hold duration in milliseconds. Clamped to 10–3000.",
                minimum: 10, maximum: 3_000
            ),
            "modifiers": JSONSchema.array(
                items: JSONSchema.string(description: "A modifier token."),
                description: "Optional modifier tokens held with the key (cmd, shift, opt, ctrl, fn)."
            ),
        ], required: ["key", "ms"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) }
        catch { return "Error: failed to parse arguments: \(error.localizedDescription)" }

        guard let keyToken = args["key"] as? String, !keyToken.isEmpty else {
            return "Error: missing required parameter 'key'."
        }
        let rawMs = optionalInt("ms", from: args) ?? 100
        let ms = max(10, min(3_000, rawMs))

        var tokens = [keyToken]
        if let mods = args["modifiers"] as? [String] { tokens.append(contentsOf: mods) }
        let parsed: (modifiers: KeyModifiers, keys: [Key])
        do { parsed = try KeyComboTool.parseKeyCombo(tokens) }
        catch {
            let joined = tokens.joined(separator: ", ")
            return "Error: unrecognized key token(s): \(joined)"
        }
        guard let key = parsed.keys.first else {
            return "Error: no recognizable key in \(keyToken)"
        }

        do {
            try GestureExecutor.keyDown(key, modifiers: parsed.modifiers)
        } catch {
            return "Error: \(describeHoldError(error))"
        }
        // `defer` guarantees release on every exit path — thrown error, Task
        // cancellation during sleep, or a dismissed chat that collapses the
        // surrounding actor. Half-held modifiers leaking into the user's
        // session is a much worse failure mode than a spurious second release.
        defer { try? GestureExecutor.keyUp(key, modifiers: parsed.modifiers) }
        do {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return "held \(keyToken) for \(ms)ms"
        } catch {
            return "Error: \(describeHoldError(error))"
        }
    }

    private func describeHoldError(_ error: Error) -> String {
        guard let ge = error as? GestureError else { return error.localizedDescription }
        switch ge {
        case .accessibilityNotTrusted:
            return "Accessibility permission required."
        case .invalidKey(let k):
            return "Invalid key: \(k)"
        case .eventCreationFailed:
            return "CGEvent creation failed."
        case .pointOutOfBounds:
            return "point out of bounds"
        }
    }
}

// MARK: - MiddleClickTool

/// Middle click (scroll wheel button) on a ref-addressed element. Primary use
/// cases are browser middle-click-to-open-tab and tiling-window-manager pane
/// focus. Routes through `SemanticExecutor.press` so AX action fires when
/// supported; falls back to a center-button CGEvent click.
public struct MiddleClickTool: ToolDefinition {
    public let name = "middle_click"
    public let description = "Middle-click an element by ref (@eN). Common use: browser middle-click-opens-in-new-tab. Prefer this over click_at with button='center' when you have a ref — semantic path first, cursor fallback otherwise. Returns JSON { ref, path, latency_ms, succeeded, fallback_reason? }."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "ref": JSONSchema.string(
                description: "Element ref in @eN form."
            ),
            "session_id": JSONSchema.string(
                description: "Optional session id to reuse the ScreenMap from a prior screen_perceive call."
            ),
        ], required: ["ref"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            do { args = try parseArguments(arguments) }
            catch { return "Error: failed to parse arguments: \(error.localizedDescription)" }
        }
        guard let refString = args["ref"] as? String,
              let ref = ElementRef.parse(refString) else {
            return "Error: missing or malformed 'ref' (expected form @eN)."
        }
        let sessionID = (args["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let map: ScreenMap
        if let sessionID,
           let cached = await SnapshotCache.shared.fetch(sessionID: sessionID) {
            map = cached.map
        } else {
            map = await DefaultComputerPerception.shared.capture(
                forceOCR: false, appFilter: nil, ocrOverride: .skip
            )
        }
        let stabilizer = PerceptionPipeline.shared.refStabilizer

        do {
            // `.center` is GestureExecutor's middle-button case.
            let result = try await SemanticExecutor.shared.press(
                ref: ref,
                identityKey: nil,
                in: map,
                stabilizer: stabilizer,
                mouseButton: .center
            )
            var body: [String: Any] = [
                "ref": result.ref.description,
                "path": result.path.rawValue,
                "latency_ms": result.latencyMs,
                "succeeded": result.succeeded,
            ]
            if let reason = result.fallbackReason { body["fallback_reason"] = reason }
            let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - ZoomTool

/// Zoom in / out of the focused app. Most native macOS apps respond to
/// ⌘= / ⌘-; Preview, Safari, Photos, Maps all honor these. A private
/// CGEventCreateMagnifyEvent API exists for continuous pinch gestures but
/// is gated behind undocumented function symbols — we skip it and keep the
/// key-combo path, which is universal.
public struct ZoomTool: ToolDefinition {
    public let name = "zoom"
    public let description = "Zoom the focused app in or out. Uses ⌘= (zoom in) or ⌘- (zoom out) — the universal macOS convention. `steps` controls how many presses to send (each step is one zoom increment in the host app). Positive steps zoom in, negative zoom out."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "steps": JSONSchema.integer(
                description: "How many zoom increments to apply. Positive = zoom in (⌘=). Negative = zoom out (⌘-). Clamped to -20…20.",
                minimum: -20, maximum: 20
            ),
        ], required: ["steps"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) }
        catch { return "Error: failed to parse arguments: \(error.localizedDescription)" }
        guard let rawSteps = optionalInt("steps", from: args) else {
            return "Error: missing required parameter 'steps'."
        }
        let steps = max(-20, min(20, rawSteps))
        if steps == 0 { return "no-op (steps=0)" }

        // Use raw keycodes so the zoom chord survives any keyboard layout —
        // `⌘=` on QWERTZ is a shifted key, on AZERTY the glyph lives somewhere
        // else entirely, but apps bind the virtual keycode (kVK_ANSI_Equal /
        // kVK_ANSI_Minus) regardless of layout. The character-matching path
        // via `.character("=")` silently falls through on non-US layouts.
        let kVK_ANSI_Equal: CGKeyCode = 0x18
        let kVK_ANSI_Minus: CGKeyCode = 0x1B
        let key: Key = steps > 0 ? .keyCode(kVK_ANSI_Equal) : .keyCode(kVK_ANSI_Minus)
        let count = abs(steps)
        do {
            for _ in 0..<count {
                try GestureExecutor.keyCombo(keys: [key], modifiers: [.command])
                try await Task.sleep(nanoseconds: 30_000_000) // 30ms between steps
            }
            return "zoom \(steps > 0 ? "in" : "out") x\(count)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - SwitchDisplayTool

/// Move the cursor to the center of display `n` so subsequent interactions
/// target that display. macOS has no "focus a display" API — warping the
/// cursor is the standard convention and matches how Mission Control, Spaces,
/// and most multi-display apps decide which display is active.
public struct SwitchDisplayTool: ToolDefinition {
    public let name = "switch_display"
    public let description = "Move the cursor to the center of display N (0-indexed into `list_displays`). macOS apps that are display-aware key off the cursor location to decide which display is active — this tool is the standard way to shift focus between monitors. Returns the display's resolved center coordinate on success."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "n": JSONSchema.integer(
                description: "0-indexed display number. Call `list_displays` to enumerate.",
                minimum: 0, maximum: 15
            ),
        ], required: ["n"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) }
        catch { return "Error: failed to parse arguments: \(error.localizedDescription)" }
        guard let idx = optionalInt("n", from: args) else {
            return "Error: missing required parameter 'n'."
        }
        let screens = NSScreen.screens
        guard idx >= 0, idx < screens.count else {
            return "Error: display index \(idx) out of range (have \(screens.count) displays)."
        }
        guard let primary = screens.first else {
            return "Error: no primary display."
        }
        // NSScreen frames share a single bottom-left-origin plane whose y=0 is
        // the primary display's bottom edge; CGWarpMouseCursorPosition expects
        // a top-left-origin global plane whose y=0 is the primary's top edge.
        // The correct flip is `primary.frame.maxY - ns.y` — not
        // `primary.frame.height`, which only coincides when the primary's
        // origin is (0,0) and every target display lives within its vertical
        // span. On setups with a display above or below the primary (common
        // with stacked monitors) the old arithmetic produced off-screen or
        // negative points.
        let screen = screens[idx]
        let targetFrame = screen.frame
        let flipY = primary.frame.maxY
        let center = CGPoint(
            x: targetFrame.midX,
            y: flipY - targetFrame.midY
        )
        let result = CGWarpMouseCursorPosition(center)
        guard result == .success else {
            return "Error: CGWarpMouseCursorPosition failed (\(result.rawValue))."
        }
        // Re-associate mouse with cursor so subsequent motion isn't decoupled.
        CGAssociateMouseAndMouseCursorPosition(1)
        return "cursor moved to display \(idx) at (\(Int(center.x)),\(Int(center.y)))"
    }
}

// MARK: - ListGrantedApplicationsTool

/// Report which apps the agent can actually observe and act on. On macOS
/// accessibility permission is a binary process-level grant, so there is no
/// per-app scoping — the useful signal is which apps are currently running
/// and which of those the perception pipeline has profiled (a proxy for
/// "have we seen enough AX from this app to be confident?").
public struct ListGrantedApplicationsTool: ToolDefinition {
    public let name = "list_granted_applications"
    public let description = "List apps the agent can observe and drive. Returns JSON { accessibility_trusted: bool, apps: [{ bundle_id, name, pid, activation_policy, observed: bool, needs_ocr: bool? }] }. Accessibility is a process-level grant on macOS (not per-app) — `accessibility_trusted` tells you whether the foundational permission is in place. Per-app `observed` is true when the perception pipeline has profiled the app; `needs_ocr` is the learned hint from AppProfile."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let trusted = AXIsProcessTrusted()
        let running = NSWorkspace.shared.runningApplications

        var apps: [[String: Any]] = []
        apps.reserveCapacity(running.count)
        for app in running {
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            // Skip LSUIElement/background services — they're not drivable UIs.
            if app.activationPolicy == .prohibited { continue }

            let profile = ElementDatabase.shared.getAppProfile(bundleID: bundleID)
            // Live AX probe: even if the DB says we profiled this app, the
            // user may have revoked accessibility at the process scope since.
            // Ask the live AX server whether it answers — if it refuses
            // (apiDisabled / notImplemented), `observed` must reflect the
            // current truth, not stale persistence. Cheap (single attribute
            // copy) and runs once per enumerated app.
            let axReachable = probeAXReachable(pid: app.processIdentifier)
            var entry: [String: Any] = [
                "bundle_id": bundleID,
                "name": app.localizedName ?? bundleID,
                "pid": Int(app.processIdentifier),
                "activation_policy": describeActivationPolicy(app.activationPolicy),
                "observed": profile != nil && axReachable,
                "ax_reachable": axReachable,
            ]
            if let p = profile {
                entry["needs_ocr"] = p.needsOCR
            }
            apps.append(entry)
        }
        // Sort deterministically by bundle id so the LLM sees stable ordering.
        apps.sort { ($0["bundle_id"] as? String ?? "") < ($1["bundle_id"] as? String ?? "") }

        let body: [String: Any] = [
            "accessibility_trusted": trusted,
            "apps": apps,
        ]
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func describeActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular:    return "regular"
        case .accessory:  return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    /// True when the AX server for `pid` answers a role query. A `.success`
    /// response means we currently have permission to read the app's tree; any
    /// other response (including `.apiDisabled` after the user revoked the
    /// Accessibility grant, or `.notImplemented` for Electron/Carbon apps that
    /// silently refuse AX) means we should treat the app as unobserved even if
    /// ElementDatabase has a historical profile.
    private func probeAXReachable(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value)
        return result == .success && value != nil
    }
}
