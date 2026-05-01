import AppKit
import CoreGraphics
import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - PressTool

/// Press the element identified by `ref` (and optional `identity_key`). Picks
/// the fastest path — AX action when the element exposes `.press` and we can
/// locate it in the live tree, else CGEvent click at the element's click point.
/// The LLM no longer needs pixel math: it hands us the ref it saw during
/// `screen_perceive` and we figure out how to land the click.
///
/// Companion to the coordinate-based `click_at` — which stays available as a
/// fallback for OCR-only elements and visually-planned actions. Prefer this
/// tool when the target has a ref.
public struct PressTool: ToolDefinition {
    public let name = "press"
    public let description = """
    Press an element by its ref (@eN) from screen_perceive. Prefers the
    accessibility action path — invisible, no cursor motion, typically under
    20 ms — and falls back to a CGEvent click when the element has no AX
    press action or cannot be located in the live tree. Pass `session_id` to
    reuse the ScreenMap cached by screen_perceive / screen_delta with that
    same id; omit to capture fresh. Optional `identity_key` lets the agent
    re-bind a stored durable key when the snapshot ref has drifted. Returns
    JSON { ref, identity_key?, path: ax|cdp|cursor, latency_ms, succeeded,
    fallback_reason? }.
    """

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "ref": JSONSchema.string(
                description: "Element ref in @eN form, e.g. @e42. Must be a ref seen in a recent screen_perceive / screen_delta snapshot."
            ),
            "session_id": JSONSchema.string(
                description: "Optional session id matching the screen_perceive session that produced the ref. When present, the cached ScreenMap is used instead of recapturing — keeps refs stable and saves a perception tick."
            ),
            "identity_key": JSONSchema.string(
                description: "Optional cross-session identity key (from a stored workflow step or ElementDatabase). If the ref is stale this re-binds it to whatever ref the stabilizer currently assigns to the same element."
            ),
            "button": JSONSchema.enumString(
                description: "Mouse button for the cursor fallback path. Defaults to 'left'. Ignored on the AX action path.",
                values: ["left", "right", "center"]
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
        let identityKey = (args["identity_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sessionID = (args["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let button = parseButton(args["button"] as? String) ?? .left

        // Fetch the ScreenMap: cached per session_id when provided, else a
        // fresh capture. The stabilizer is always the pipeline's — refs in
        // either map were issued by it.
        let map: ScreenMap
        if let sessionID,
           let cached = await SnapshotCache.shared.fetch(sessionID: sessionID) {
            map = cached.map
        } else {
            map = await DefaultComputerPerception.shared.capture(
                forceOCR: false,
                appFilter: nil,
                ocrOverride: .skip
            )
        }

        let stabilizer = PerceptionPipeline.shared.refStabilizer

        do {
            let result = try await SemanticExecutor.shared.press(
                ref: ref,
                identityKey: identityKey,
                in: map,
                stabilizer: stabilizer,
                mouseButton: button
            )
            return encodePressResult(result)
        } catch SemanticExecutor.PressError.unreachable(let missing) {
            return encodeErrorPayload(
                error: "unreachable",
                requestedRef: missing,
                advice: "The element is not in the current ScreenMap. Call screen_perceive to refresh the snapshot, then reissue with the current @eN."
            )
        } catch SemanticExecutor.PressError.gesture(let inner) {
            return encodeErrorPayload(
                error: "gesture_failed",
                requestedRef: ref,
                advice: describeGestureError(inner)
            )
        } catch {
            return encodeErrorPayload(
                error: "unknown",
                requestedRef: ref,
                advice: error.localizedDescription
            )
        }
    }

    // MARK: - Encoding

    private func encodePressResult(_ result: SemanticExecutor.PressResult) -> String {
        var body: [String: Any] = [
            "ref": result.ref.description,
            "path": result.path.rawValue,
            "latency_ms": result.latencyMs,
            "succeeded": result.succeeded,
        ]
        if let key = result.identityKey { body["identity_key"] = key }
        if let reason = result.fallbackReason { body["fallback_reason"] = reason }
        return encodeJSON(body)
    }

    private func encodeErrorPayload(
        error: String,
        requestedRef: ElementRef,
        advice: String
    ) -> String {
        let body: [String: Any] = [
            "error": error,
            "requested_ref": requestedRef.description,
            "advice": advice,
        ]
        return encodeJSON(body)
    }

    private func encodeJSON(_ body: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func parseButton(_ s: String?) -> MouseButton? {
        switch s?.lowercased() {
        case "left":   return .left
        case "right":  return .right
        case "center": return .center
        default:       return nil
        }
    }

    private func describeGestureError(_ error: Error) -> String {
        guard let ge = error as? GestureError else { return error.localizedDescription }
        switch ge {
        case .accessibilityNotTrusted:
            return "Accessibility permission required. Grant access in System Settings → Privacy & Security → Accessibility, then retry."
        case .pointOutOfBounds(let p):
            return "Click point out of bounds: (\(Int(p.x)),\(Int(p.y))). The element may be offscreen or on a detached display."
        case .invalidKey(let k):
            return "Invalid key: \(k)"
        case .eventCreationFailed:
            return "CGEvent creation failed. Retry once; if persistent, quit and reopen the host process."
        }
    }
}

// MARK: - TypeTool

/// Focus an element by ref and type `text` into it. Refuses when Secure Event
/// Input is active and the target is a password field — macOS silently drops
/// synthetic keystrokes there, so returning an explicit error lets the LLM
/// prompt the user instead of looping into the void.
public struct TypeTool: ToolDefinition {
    public let name = "type"
    public let description = """
    Type text into an element addressed by its ref (@eN) from screen_perceive.
    Focuses the element with a click, then injects keystrokes. Optional
    `clear_first` selects all and deletes before typing; optional `press_enter`
    submits after. Refuses secure-input fields with an error describing why.
    Pass `session_id` to reuse a cached ScreenMap from screen_perceive /
    screen_delta. Returns JSON { ref, identity_key?, path, latency_ms,
    characters_typed, pressed_enter }.
    """

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "ref": JSONSchema.string(
                description: "Element ref in @eN form. Must be a ref seen in a recent screen_perceive snapshot. The element should be a text field, text area, or editable content region."
            ),
            "text": JSONSchema.string(
                description: "Payload to type. Supports any Unicode scalar — ASCII routes through the typed keymap, non-ASCII (emoji, CJK) via CGEventKeyboardSetUnicodeString."
            ),
            "press_enter": JSONSchema.boolean(
                description: "Press Return after typing. Useful for chat inputs, search fields, single-line forms. Defaults to false."
            ),
            "clear_first": JSONSchema.boolean(
                description: "Select-all (⌘A) and delete before typing. Replaces the field's current value. Defaults to false."
            ),
            "session_id": JSONSchema.string(
                description: "Optional session id matching the screen_perceive session that produced the ref. When present, reuses the cached ScreenMap."
            ),
        ], required: ["ref", "text"])
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
        guard let text = args["text"] as? String else {
            return "Error: missing required parameter 'text'."
        }
        let pressEnter = (args["press_enter"] as? Bool) ?? false
        let clearFirst = (args["clear_first"] as? Bool) ?? false
        let sessionID = (args["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let map: ScreenMap
        if let sessionID,
           let cached = await SnapshotCache.shared.fetch(sessionID: sessionID) {
            map = cached.map
        } else {
            map = await DefaultComputerPerception.shared.capture(
                forceOCR: false,
                appFilter: nil,
                ocrOverride: .skip
            )
        }
        let stabilizer = PerceptionPipeline.shared.refStabilizer

        do {
            let result = try await SemanticExecutor.shared.type(
                ref: ref,
                text: text,
                pressEnter: pressEnter,
                clearFirst: clearFirst,
                in: map,
                stabilizer: stabilizer
            )
            return encodeTypeResult(result)
        } catch SemanticExecutor.TypeError.unreachable(let missing) {
            return encodeErrorPayload(
                error: "unreachable",
                requestedRef: missing,
                advice: "Element is not in the current ScreenMap. Call screen_perceive and reissue."
            )
        } catch SemanticExecutor.TypeError.notTextInput(let badRef, let role) {
            return encodeErrorPayload(
                error: "not_text_input",
                requestedRef: badRef,
                advice: "Element at \(badRef.description) has role \(role.rawValue) — not a text input. Typing would focus a container and fire keystrokes at whatever was previously focused. Re-disambiguate for a descendant text field (role: textField, textArea, comboBox) and reissue."
            )
        } catch SemanticExecutor.TypeError.secureInputActive(let secure) {
            return encodeErrorPayload(
                error: "secure_input_active",
                requestedRef: secure,
                advice: "Secure Event Input is active. macOS silently drops synthetic keystrokes to secure fields. Ask the user to type this value themselves."
            )
        } catch SemanticExecutor.TypeError.gesture(let inner) {
            return encodeErrorPayload(
                error: "gesture_failed",
                requestedRef: ref,
                advice: describeGestureError(inner)
            )
        } catch {
            return encodeErrorPayload(
                error: "unknown",
                requestedRef: ref,
                advice: error.localizedDescription
            )
        }
    }

    private func encodeTypeResult(_ result: SemanticExecutor.TypeResult) -> String {
        var body: [String: Any] = [
            "ref": result.ref.description,
            "path": result.path.rawValue,
            "latency_ms": result.latencyMs,
            "characters_typed": result.charactersTyped,
            "pressed_enter": result.pressedEnter,
        ]
        if let key = result.identityKey { body["identity_key"] = key }
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func encodeErrorPayload(
        error: String,
        requestedRef: ElementRef,
        advice: String
    ) -> String {
        let body: [String: Any] = [
            "error": error,
            "requested_ref": requestedRef.description,
            "advice": advice,
        ]
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func describeGestureError(_ error: Error) -> String {
        guard let ge = error as? GestureError else { return error.localizedDescription }
        switch ge {
        case .accessibilityNotTrusted:
            return "Accessibility permission required. Grant access in System Settings → Privacy & Security → Accessibility, then retry."
        case .pointOutOfBounds(let p):
            return "Click point out of bounds: (\(Int(p.x)),\(Int(p.y))). The element may be offscreen."
        case .invalidKey(let k):
            return "Invalid key: \(k)"
        case .eventCreationFailed:
            return "CGEvent creation failed. Retry once; if persistent, quit and reopen the host process."
        }
    }
}
