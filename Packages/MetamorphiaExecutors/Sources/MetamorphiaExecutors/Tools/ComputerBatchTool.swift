import AppKit
import CoreGraphics
import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - ComputerBatchTool

/// Run a sequence of semantic actions atomically with an optional post-condition
/// check. The LLM describes a multi-step UI flow once, the executor runs it in
/// one feedback-suppressed span, recaptures, evaluates the verification, and
/// returns a structured summary.
///
/// This is the primitive that makes multi-step flows reliable under latency.
/// Instead of the agent issuing five separate tool calls with perception ticks
/// in between, it submits one batch and gets back "verified=true" or a precise
/// failure point. That in turn is what Phase E's workflow compiler relies on:
/// a compiled skill is essentially a parametric `computer_batch`.
///
/// Step shapes:
///   { "op": "press", "ref": "@e42", "button": "left|right|center"? }
///   { "op": "type", "ref": "@e15", "text": "hello", "press_enter": bool?,
///     "clear_first": bool? }
///   { "op": "focus", "ref": "@e15" }
///   { "op": "wait", "ms": 300 }
///   { "op": "press_menu", "path": ["File", "Save"] }
///
/// Verify shapes (all optional; omit to skip the check):
///   { "kind": "field_equals", "ref": "@e15", "field": "value|focused|label|title",
///     "equals": "hello" }
///   { "kind": "text_contains", "ref": "@e15", "field": "value|label",
///     "equals": "substring" }
///   { "kind": "exists", "ref": "@e22" }
///   { "kind": "not_exists", "ref": "@e22" }
///   { "kind": "focus_moved_to", "ref": "@e30" }
///
/// `timeout_ms` on verify re-captures up to that many ms after the last step
/// so slow UI animations have time to settle. Defaults to 2000 ms.
public struct ComputerBatchTool: ToolDefinition {
    public let name = "computer_batch"
    public let description = """
    Run an ordered sequence of semantic actions (press, type, focus, wait,
    press_menu) as a single atomic operation and optionally verify a
    post-condition by recapturing the screen and checking a field. Preferred
    over individual tool calls for multi-step flows — saves perception ticks
    and gives the LLM one verified success/failure signal instead of five
    uncorrelated ones. Returns JSON { steps_completed, total_steps, verified,
    latency_ms, failed_at?, error?, verify_detail? }.
    """

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "steps": JSONSchema.array(
                items: JSONSchema.object(properties: [
                    "op": JSONSchema.enumString(
                        description: "Operation kind.",
                        values: ["press", "type", "focus", "wait", "press_menu"]
                    ),
                    "ref": JSONSchema.string(description: "Element ref in @eN form (press/type/focus)."),
                    "text": JSONSchema.string(description: "Text payload (type only)."),
                    "ms": JSONSchema.integer(description: "Duration in milliseconds (wait only)."),
                    "button": JSONSchema.string(description: "Mouse button for press (left|right|center)."),
                    "press_enter": JSONSchema.boolean(description: "Press Return after typing (type only)."),
                    "clear_first": JSONSchema.boolean(description: "Clear before typing (type only)."),
                    "path": JSONSchema.array(
                        items: JSONSchema.string(description: "Menu title at this depth."),
                        description: "Menu bar path for press_menu (e.g. [\"File\", \"Save\"])."
                    ),
                ], required: ["op"]),
                description: "Ordered list of operations to execute."
            ),
            "verify": JSONSchema.object(properties: [
                "kind": JSONSchema.enumString(
                    description: "Which post-condition to check.",
                    values: ["field_equals", "text_contains", "exists", "not_exists", "focus_moved_to"]
                ),
                "ref": JSONSchema.string(description: "Target element ref (most kinds)."),
                "field": JSONSchema.string(description: "Which field to read: value|focused|label|title."),
                "equals": JSONSchema.string(description: "Expected string for equality / contains checks."),
                "timeout_ms": JSONSchema.integer(description: "Settle timeout in ms. Default 2000."),
            ]),
            "stop_on_error": JSONSchema.boolean(
                description: "Abort the batch on the first step failure. Defaults to true."
            ),
            "session_id": JSONSchema.string(
                description: "Optional session id to reuse a ScreenMap cached by screen_perceive / screen_delta."
            ),
        ], required: ["steps"])
    }

    public init() {}

    // AUDIT: `computer_batch` runs an arbitrary ordered sequence of
    // press/type/focus/press_menu actions in a single feedback-suppressed span
    // without re-entering the safety gate per step. To close that bypass it is
    // classified `.critical` in `MetamorphiaToolSafetyGate.defaultCriticalTools`,
    // so `ToolRegistry.execute` prompts the user once (covering the whole flow)
    // before this method is reached. Do not lower that classification without
    // adding per-sub-action inspection here.
    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do { args = try parseArguments(arguments) }
        catch { return "Error: failed to parse arguments: \(error.localizedDescription)" }

        guard let stepsRaw = args["steps"] as? [[String: Any]], !stepsRaw.isEmpty else {
            return "Error: 'steps' must be a non-empty array."
        }
        let stopOnError = (args["stop_on_error"] as? Bool) ?? true
        let sessionID = (args["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // Open the batch span on the suppressor. Every CGEvent / keystroke
        // fired by an individual step still posts its own per-action handle —
        // this span is a longer-lived marker that lets observers correlate
        // the intermediate events as belonging to one agent batch. The handle
        // is released in `defer` below so a thrown / cancelled path still
        // closes the span.
        let suppressor = FeedbackLoopSuppressor.shared
        let batchHandle = await suppressor.beginBatch()
        defer { Task { await suppressor.endBatch(batchHandle) } }

        // Baseline ScreenMap. Step dispatchers may use it directly or ask for
        // a fresh recapture (below) when the previous step was side-effecting
        // enough that the old refs are likely stale. `press_menu` walks the
        // live AX tree and doesn't read from the map.
        var map: ScreenMap
        if let sessionID,
           let cached = await SnapshotCache.shared.fetch(sessionID: sessionID) {
            map = cached.map
        } else {
            map = await DefaultComputerPerception.shared.capture(
                forceOCR: false, appFilter: nil, ocrOverride: .skip
            )
        }
        let stabilizer = PerceptionPipeline.shared.refStabilizer

        let started = Date()
        var completed = 0
        var failureInfo: (index: Int, error: String)?

        for (index, step) in stepsRaw.enumerated() {
            // Recapture between side-effecting steps so post-press refs
            // (a sheet appearing, a list reordering after type) resolve
            // against a map that actually contains them. `wait` and
            // `press_menu` don't address refs and don't warrant a recapture;
            // `focus` uses the same cursor-click path as `press`, so we do
            // recapture before the next ref-addressed op.
            if index > 0, shouldRecaptureBefore(step: step) {
                // Small settle so any animations from the previous step have
                // landed before we re-read the tree. 120 ms matches the
                // dHash content-hash gate cadence elsewhere in perception.
                try? await Task.sleep(nanoseconds: 120_000_000)
                map = await DefaultComputerPerception.shared.capture(
                    forceOCR: false, appFilter: nil, ocrOverride: .skip
                )
            }
            do {
                try await runStep(step, in: map, stabilizer: stabilizer)
                completed += 1
            } catch {
                failureInfo = (index, "\(error)")
                if stopOnError { break }
            }
        }

        // Verify clause: run a real poll loop up to `timeout_ms`, not a single
        // sleep+capture. The schema advertises "re-captures up to that many
        // ms after the last step so slow UI animations have time to settle" —
        // deliver it. On pass we return early so fast-settling flows aren't
        // billed for the full timeout.
        let verify = args["verify"] as? [String: Any]
        let timeoutMs = (verify?["timeout_ms"] as? Int) ?? 2_000
        let clampedTimeout = max(100, min(10_000, timeoutMs))
        let (verifyResult, finalMap) = await pollVerify(
            verify: verify,
            timeoutMs: clampedTimeout,
            stabilizer: stabilizer
        )
        _ = finalMap // Final ScreenMap available for future telemetry; not used here.

        let latencyMs = Int((Date().timeIntervalSince(started) * 1000).rounded())
        return encodeResult(
            totalSteps: stepsRaw.count,
            stepsCompleted: completed,
            failed: failureInfo,
            verified: verifyResult,
            latencyMs: latencyMs
        )
    }

    // MARK: - Recapture + poll helpers

    /// Side-effecting ops that mutate the UI enough that the next step's refs
    /// may not be in the baseline map. `wait` is pure sleep; `press_menu`
    /// addresses menu paths, not refs. Everything else potentially changes
    /// what's on screen.
    private func shouldRecaptureBefore(step: [String: Any]) -> Bool {
        let op = (step["op"] as? String)?.lowercased() ?? ""
        switch op {
        case "wait", "press_menu": return false
        default: return true
        }
    }

    /// Poll the verify clause on fresh ScreenMap captures until it passes or
    /// the timeout expires. Returns the final outcome (or nil when no verify
    /// was requested) plus the last map captured so callers can attach it to
    /// telemetry. Re-capture cadence is 200 ms to stay responsive to real
    /// animations without spinning on the AX bus.
    private func pollVerify(
        verify: [String: Any]?,
        timeoutMs: Int,
        stabilizer: RefStabilizer
    ) async -> (VerifyOutcome?, ScreenMap?) {
        guard let verify else {
            // No verification requested — still give the UI a short settle so
            // the caller's view of "done" means "done and visible".
            try? await Task.sleep(nanoseconds: 200_000_000)
            return (nil, nil)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        var lastMap: ScreenMap?
        var lastOutcome: VerifyOutcome?
        while Date() < deadline {
            let fresh = await DefaultComputerPerception.shared.capture(
                forceOCR: false, appFilter: nil, ocrOverride: .skip
            )
            lastMap = fresh
            let outcome = evaluate(verify: verify, in: fresh, stabilizer: stabilizer)
            lastOutcome = outcome
            if outcome.passed { return (outcome, fresh) }
            // Cooperative wait so animations have time to settle between polls.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return (lastOutcome, lastMap)
    }

    // MARK: - Step dispatch

    private func runStep(
        _ step: [String: Any],
        in map: ScreenMap,
        stabilizer: RefStabilizer
    ) async throws {
        let op = (step["op"] as? String)?.lowercased() ?? ""
        switch op {
        case "press":
            try await runPress(step, in: map, stabilizer: stabilizer)
        case "type":
            try await runType(step, in: map, stabilizer: stabilizer)
        case "focus":
            try runFocus(step, in: map, stabilizer: stabilizer)
        case "wait":
            let ms = max(0, min(5_000, (step["ms"] as? Int) ?? 0))
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        case "press_menu":
            try runPressMenu(step)
        default:
            throw BatchStepError.unknownOp(op)
        }
    }

    private func runPress(
        _ step: [String: Any],
        in map: ScreenMap,
        stabilizer: RefStabilizer
    ) async throws {
        guard let refString = step["ref"] as? String,
              let ref = ElementRef.parse(refString) else {
            throw BatchStepError.missingField("ref")
        }
        let button = parseButton(step["button"] as? String) ?? .left
        _ = try await SemanticExecutor.shared.press(
            ref: ref,
            identityKey: nil,
            in: map,
            stabilizer: stabilizer,
            mouseButton: button
        )
    }

    private func runType(
        _ step: [String: Any],
        in map: ScreenMap,
        stabilizer: RefStabilizer
    ) async throws {
        guard let refString = step["ref"] as? String,
              let ref = ElementRef.parse(refString) else {
            throw BatchStepError.missingField("ref")
        }
        guard let text = step["text"] as? String else {
            throw BatchStepError.missingField("text")
        }
        _ = try await SemanticExecutor.shared.type(
            ref: ref,
            text: text,
            pressEnter: (step["press_enter"] as? Bool) ?? false,
            clearFirst: (step["clear_first"] as? Bool) ?? false,
            in: map,
            stabilizer: stabilizer
        )
    }

    private func runFocus(
        _ step: [String: Any],
        in map: ScreenMap,
        stabilizer: RefStabilizer
    ) throws {
        guard let refString = step["ref"] as? String,
              let ref = ElementRef.parse(refString) else {
            throw BatchStepError.missingField("ref")
        }
        // Focus = click on the click point. Native AX kAXFocusedAttribute set
        // is spotty across apps; a cursor click is the reliable path that all
        // Metamorphia-supported apps respond to.
        let resolution = ElementResolver.resolve(
            ref: ref, identityKey: nil, label: nil, preferredRole: nil,
            nearPoint: nil, in: map, stabilizer: stabilizer, db: nil
        )
        switch resolution {
        case .success(let r):
            guard let point = r.element.clickPoint ?? r.element.bounds.map({
                CGPoint(x: $0.midX, y: $0.midY)
            }) else {
                throw BatchStepError.unreachable(refString)
            }
            do { try GestureExecutor.click(at: point, button: .left, count: 1) }
            catch { throw BatchStepError.gesture("\(error)") }
        case .failure:
            throw BatchStepError.unreachable(refString)
        }
    }

    private func runPressMenu(_ step: [String: Any]) throws {
        guard let path = step["path"] as? [String], !path.isEmpty else {
            throw BatchStepError.missingField("path")
        }
        guard let front = NSWorkspace.shared.frontmostApplication else {
            throw BatchStepError.noFrontmostApp
        }
        let ok = MenuBarReader.invoke(path: path, pid: front.processIdentifier)
        if !ok {
            throw BatchStepError.menuInvokeFailed(path.joined(separator: " > "))
        }
    }

    // MARK: - Verification

    private struct VerifyOutcome {
        let passed: Bool
        let detail: String
    }

    private func evaluate(
        verify: [String: Any],
        in map: ScreenMap,
        stabilizer: RefStabilizer
    ) -> VerifyOutcome {
        let kind = (verify["kind"] as? String)?.lowercased() ?? ""
        let refString = verify["ref"] as? String
        let expected = verify["equals"] as? String
        let field = (verify["field"] as? String)?.lowercased() ?? "value"

        switch kind {
        case "exists":
            guard let refString, let ref = ElementRef.parse(refString) else {
                return VerifyOutcome(passed: false, detail: "malformed ref")
            }
            let present = map.elements.contains(where: { $0.ref == ref })
            return VerifyOutcome(passed: present, detail: present ? "present" : "absent")

        case "not_exists":
            guard let refString, let ref = ElementRef.parse(refString) else {
                return VerifyOutcome(passed: false, detail: "malformed ref")
            }
            let present = map.elements.contains(where: { $0.ref == ref })
            return VerifyOutcome(passed: !present, detail: present ? "present (expected absent)" : "absent")

        case "focus_moved_to":
            guard let refString, let ref = ElementRef.parse(refString) else {
                return VerifyOutcome(passed: false, detail: "malformed ref")
            }
            if let el = map.elements.first(where: { $0.ref == ref }) {
                let focused = el.state.contains(.focused)
                let stateLabel = el.state.names.joined(separator: "|")
                return VerifyOutcome(
                    passed: focused,
                    detail: focused ? "focused" : "not focused (state=\(stateLabel))"
                )
            }
            return VerifyOutcome(passed: false, detail: "ref not found in post-state map")

        case "field_equals":
            guard let refString, let ref = ElementRef.parse(refString),
                  let el = map.elements.first(where: { $0.ref == ref }) else {
                return VerifyOutcome(passed: false, detail: "ref not found")
            }
            let actual = readField(field: field, from: el)
            let match = actual == (expected ?? "")
            return VerifyOutcome(
                passed: match,
                detail: match ? "equal" : "actual='\(actual)' expected='\(expected ?? "")'"
            )

        case "text_contains":
            guard let refString, let ref = ElementRef.parse(refString),
                  let el = map.elements.first(where: { $0.ref == ref }) else {
                return VerifyOutcome(passed: false, detail: "ref not found")
            }
            let actual = readField(field: field, from: el)
            let needle = expected ?? ""
            let match = !needle.isEmpty && actual.contains(needle)
            return VerifyOutcome(
                passed: match,
                detail: match ? "contains" : "actual='\(actual)' missing='\(needle)'"
            )

        default:
            return VerifyOutcome(passed: false, detail: "unknown verify.kind '\(kind)'")
        }
    }

    private func readField(field: String, from el: ScreenElement) -> String {
        switch field {
        case "value":   return el.value
        case "label":   return el.label
        case "title":   return el.label // ScreenElement doesn't split title from label.
        case "focused": return el.state.contains(.focused) ? "true" : "false"
        default:        return el.value
        }
    }

    // MARK: - Encoding

    private func encodeResult(
        totalSteps: Int,
        stepsCompleted: Int,
        failed: (index: Int, error: String)?,
        verified: VerifyOutcome?,
        latencyMs: Int
    ) -> String {
        var body: [String: Any] = [
            "total_steps": totalSteps,
            "steps_completed": stepsCompleted,
            "latency_ms": latencyMs,
        ]
        if let f = failed {
            body["failed_at"] = f.index
            body["error"] = f.error
        }
        if let v = verified {
            body["verified"] = v.passed
            body["verify_detail"] = v.detail
        }
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
}

// MARK: - Errors

private enum BatchStepError: Error, CustomStringConvertible {
    case unknownOp(String)
    case missingField(String)
    case unreachable(String)
    case gesture(String)
    case noFrontmostApp
    case menuInvokeFailed(String)

    var description: String {
        switch self {
        case .unknownOp(let op): return "unknown op '\(op)'"
        case .missingField(let f): return "missing field '\(f)'"
        case .unreachable(let r): return "unreachable ref \(r)"
        case .gesture(let g): return "gesture failed: \(g)"
        case .noFrontmostApp: return "no frontmost app"
        case .menuInvokeFailed(let p): return "menu path not found: \(p)"
        }
    }
}
