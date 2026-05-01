import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Ref-addressable action executor. Lets the LLM say "press this element" and
/// the runtime picks the fastest path that actually lands the click.
///
/// This is the first half of the semantic-action story (Phase A of the Ultimate
/// Computer-Use plan). It lowers semantic ops (`press`, `type`, `focus`) onto
/// three execution paths, ranked fastest-first:
///
///   1. **AX action** — `AXUIElementPerformAction(target, kAXPressAction)` when
///      the element's `actions` includes `.press` and we can locate its live
///      `AXUIElement` counterpart in the current app's AX tree. Zero pixels,
///      zero cursor motion, typically < 20 ms. Proven pattern: MenuBarReader
///      already uses this for menu items.
///   2. **CDP** — `Runtime.evaluate` with `document.querySelector(sel).click()`.
///      Added in Phase C once `BrowserDOMJoiner` annotates elements with
///      `domSelector`. Not wired here yet.
///   3. **CGEvent** — existing `GestureExecutor.click(at: clickPoint)` fallback.
///      This is today's coordinate path rehomed under a ref-based API, so the
///      LLM no longer needs pixel math even before (1) and (2) land.
///
/// The executor operates on an already-captured `ScreenMap`. Callers hand us a
/// ref (or identity key) plus the map they saw it in; `ElementResolver` does
/// the lookup cascade, and this type chooses a path and logs which one fired.
///
/// Feedback-loop suppression is preserved transparently: path (3) routes
/// through `GestureExecutor.click(...)` which already calls
/// `FeedbackLoopSuppressor.beginAction(kind: .click)`. Paths (1) and (2) don't
/// post CGEvents so there's no mouse ripple to suppress, but their AX/DOM
/// notifications flow through the existing trigger bus. Richer AX-notification
/// tagging for path (1) is tracked as a follow-up in Phase A's second slice.
///
/// **Concurrency.** Converted from `enum` (Phase A) to `actor` (PROMAX pass)
/// so parallel `press` / `type` calls don't race on the AX walker, the
/// per-bundle failure counter, or the pid cache. All public entrypoints
/// hop onto the actor's executor — use `SemanticExecutor.shared.press(...)`.
public actor SemanticExecutor {

    // MARK: - Singleton

    public static let shared = SemanticExecutor()

    public init() {}

    // MARK: - Telemetry state (actor-isolated)

    /// Per-bundle count of consecutive AX-action failures. Increments when
    /// `AXUIElementPerformAction` returns non-success; resets on any success.
    /// Populated by the AX dispatch path; consumed by `shouldSkipAXPath` so
    /// the executor stops burning latency on apps that reliably reject AX
    /// actions (Electron hard-mode offenders). Sticky for the process
    /// lifetime — spilling to `AppProfile` is a follow-up.
    private var axFailureCounts: [String: Int] = [:]

    /// Threshold at which the executor demotes a bundle — subsequent press
    /// calls skip the AX path entirely and go directly to CDP / cursor.
    private let axDemotionThreshold = 3

    /// Cache of bundle-id → pid. Looking up the pid via
    /// `NSWorkspace.runningApplications` is O(N) and the list is large on
    /// a busy Mac; caching inside the actor saves ~0.5 ms per press.
    /// Invalidated when AX access fails so stale pids don't linger after
    /// the user quits and relaunches the app.
    private var pidCache: [String: pid_t] = [:]

    // MARK: - Static constants

    /// Wall-clock budget for a single AX tree walk. Electron apps with deep
    /// trees can take hundreds of ms for a 4000-node walk (each
    /// `AXAttributes.getChildren` is an IPC round-trip to the target
    /// process). Cap prevents the cooperative thread from blocking; the
    /// executor falls through to CGEvent on timeout.
    private static let axWalkDeadlineMs: Int = 80


    // MARK: - Path

    /// Which path a press / type / focus dispatch took. Surfaced back to the
    /// LLM so the model learns which apps / elements are AX-friendly and which
    /// still require cursor motion.
    public enum Path: String, Sendable {
        case axAction = "ax"
        case cdp = "cdp"
        case cursor = "cursor"
    }

    // MARK: - Results

    public struct PressResult: Sendable {
        public let ref: ElementRef
        public let identityKey: String?
        public let path: Path
        public let latencyMs: Int
        public let succeeded: Bool
        public let fallbackReason: String?

        public init(
            ref: ElementRef,
            identityKey: String?,
            path: Path,
            latencyMs: Int,
            succeeded: Bool,
            fallbackReason: String?
        ) {
            self.ref = ref
            self.identityKey = identityKey
            self.path = path
            self.latencyMs = latencyMs
            self.succeeded = succeeded
            self.fallbackReason = fallbackReason
        }
    }

    public struct TypeResult: Sendable {
        public let ref: ElementRef
        public let identityKey: String?
        public let path: Path
        public let latencyMs: Int
        public let charactersTyped: Int
        public let pressedEnter: Bool

        public init(
            ref: ElementRef,
            identityKey: String?,
            path: Path,
            latencyMs: Int,
            charactersTyped: Int,
            pressedEnter: Bool
        ) {
            self.ref = ref
            self.identityKey = identityKey
            self.path = path
            self.latencyMs = latencyMs
            self.charactersTyped = charactersTyped
            self.pressedEnter = pressedEnter
        }
    }

    public enum PressError: Error, Sendable {
        /// Element has no known click point and no `.press` AX action — there's
        /// nothing reasonable to invoke. Agents should call `screen_perceive`
        /// and pick a different target.
        case unreachable(ref: ElementRef)
        /// Accessibility permissions missing or the CGEvent post returned an
        /// error. Underlying `GestureError` attached for diagnostics.
        case gesture(Error)
    }

    public enum TypeError: Error, Sendable {
        /// The target element has no click point and its role is not a text
        /// container — typing would bit-bucket at the wrong focus owner.
        case unreachable(ref: ElementRef)
        /// The target element is not a text-accepting role. Typing into it
        /// would focus the container and fire keystrokes at whatever element
        /// happened to hold focus before — a silent data leak risk in chat
        /// apps whose compose label matches a parent `AXGroup`. Agents should
        /// re-disambiguate against a descendant text input.
        case notTextInput(ref: ElementRef, role: ElementRole)
        /// Secure Event Input is active and the target is a password field.
        /// macOS silently drops synthetic keystrokes to secure fields; returning
        /// an explicit error so the LLM can prompt the user instead of looping.
        case secureInputActive(ref: ElementRef)
        case gesture(Error)
    }

    // MARK: - Public API

    /// Press the element identified by `ref` (or its `identityKey`) in `map`.
    /// The executor picks the fastest reachable path and falls back on failure.
    /// Returns a `PressResult` carrying which path actually fired so the agent
    /// loop can feed it back as learning signal.
    @discardableResult
    public func press(
        ref: ElementRef,
        identityKey: String? = nil,
        in map: ScreenMap,
        stabilizer: RefStabilizer? = nil,
        mouseButton: MouseButton = .left
    ) async throws -> PressResult {

        // Resolve ref → element via the cascade. The caller already had a
        // ScreenMap, so step 1 of the cascade is the common case; the later
        // steps exist for stale-tick recovery.
        let resolution = ElementResolver.resolve(
            ref: ref,
            identityKey: identityKey,
            label: nil,
            preferredRole: nil,
            nearPoint: nil,
            in: map,
            stabilizer: stabilizer,
            db: nil
        )

        let element: ScreenElement
        switch resolution {
        case .success(let r): element = r.element
        case .failure:
            // Caller expected a direct hit — surface reachability failure.
            throw PressError.unreachable(ref: ref)
        }

        // Resolve the stored identity_key after the fact for result logging,
        // when the caller didn't hand one in. Cheap (dictionary lookup).
        let resolvedKey = identityKey ?? stabilizer?.identityKey(for: element.ref)

        let started = Date()

        // Path 1 — AX action. Prefer when the element exposes .press and we
        // can find its AXUIElement counterpart in the live tree. Mirror the
        // pattern proven in MenuBarReader.swift:126.
        //
        // Demotion: if the bundle has silently failed 3 AX presses in a row,
        // skip this path and go straight to CDP/cursor. Saves an AX walk
        // per press on known-bad Electron apps. A subsequent real AX success
        // (through a different press) clears the counter.
        if element.actions.contains(.press),
           let bundleID = element.appBundleID,
           !shouldSkipAXPath(for: bundleID),
           let axElement = locateAXElement(for: element, bundleID: bundleID) {
            let result = AXUIElementPerformAction(axElement, kAXPressAction as CFString)
            if result == .success {
                noteAXSuccess(bundleID: bundleID)
                recordPressStep(element: element, identityKey: resolvedKey)
                return PressResult(
                    ref: element.ref,
                    identityKey: resolvedKey,
                    path: .axAction,
                    latencyMs: elapsedMs(from: started),
                    succeeded: true,
                    fallbackReason: nil
                )
            }
            // AX action returned an error. Bump the per-bundle counter so
            // repeat offenders get demoted — sticky until a real AX success
            // clears it. Fall through to CDP or cursor and record the reason.
            let demoted = noteAXFailure(bundleID: bundleID)
            let demotionSuffix = demoted ? ";demoted" : ""
            if let cdpResult = try await tryCDPClick(
                element: element,
                map: map,
                identityKey: resolvedKey,
                started: started,
                axFailureReason: "ax_error=\(result.rawValue)\(demotionSuffix)"
            ) {
                return cdpResult
            }
            return try fallbackToCursor(
                element: element,
                identityKey: resolvedKey,
                mouseButton: mouseButton,
                started: started,
                reason: "ax_error=\(result.rawValue)\(demotionSuffix)"
            )
        }

        // Path 2 — CDP click for browser elements. Fires when the element
        // was joined with a DOM selector by `BrowserDOMJoiner`. The dispatch
        // runs invisibly (no cursor motion) and returns the success/fail
        // envelope directly so we can still fall through to CGEvent if the
        // page's selector matching or CSP rejects the call.
        if let cdpResult = try await tryCDPClick(
            element: element,
            map: map,
            identityKey: resolvedKey,
            started: started,
            axFailureReason: element.actions.contains(.press) ? "ax_element_not_found" : "no_ax_press_action"
        ) {
            return cdpResult
        }

        // Path 3 — CGEvent click. Uses the existing GestureExecutor so
        // FeedbackLoopSuppressor tagging happens automatically.
        return try fallbackToCursor(
            element: element,
            identityKey: resolvedKey,
            mouseButton: mouseButton,
            started: started,
            reason: element.actions.contains(.press) ? "ax_element_not_found" : "no_ax_press_action"
        )
    }

    // MARK: - CDP dispatch path

    /// Try the CDP / Safari `do JavaScript` path. Returns a success
    /// `PressResult` when the dispatch confirmed a matched DOM node was
    /// clicked; returns nil when the path is not applicable (element has no
    /// domSelector, browser not frontmost, or the app is not a supported
    /// browser) so the caller proceeds to CGEvent fallback.
    ///
    /// Guards:
    ///   - `element.domSelector != nil` — the joiner matched a DOM node.
    ///   - `element.appBundleID == map.focusedApp.bundleID` — the selector
    ///     refers to the live frontmost tab, not a stale capture.
    ///   - `BrowserDOMFetcher.isBrowserBundle(bundleID)` — this is a browser
    ///     we know how to drive.
    private func tryCDPClick(
        element: ScreenElement,
        map: ScreenMap,
        identityKey: String?,
        started: Date,
        axFailureReason: String
    ) async throws -> PressResult? {
        guard let selector = element.domSelector,
              let bundleID = element.appBundleID,
              BrowserDOMFetcher.isBrowserBundle(bundleID),
              map.focusedApp.bundleID == bundleID else {
            return nil
        }
        let result = await BrowserDOMFetcher.shared.dispatchClick(
            focusedApp: map.focusedApp,
            selector: selector
        )
        if result.succeeded {
            recordPressStep(element: element, identityKey: identityKey)
            return PressResult(
                ref: element.ref,
                identityKey: identityKey,
                path: .cdp,
                latencyMs: elapsedMs(from: started),
                succeeded: true,
                fallbackReason: axFailureReason.isEmpty ? nil : axFailureReason
            )
        }
        // Dispatch failed — return nil so caller cascades to CGEvent. Keep
        // the CDP failure reason accessible via the cursor path's
        // fallbackReason so telemetry can correlate.
        return nil
    }

    // MARK: - Type

    /// Focus `ref` and type `text` into it. Secure Event Input is detected and
    /// refused up front — macOS silently drops synthetic keystrokes to secure
    /// fields, so returning an error lets the LLM explain the constraint rather
    /// than loop.
    ///
    /// Current path: cursor — click the element to focus it, then
    /// `GestureExecutor.typeString`. AX `kAXValueAttribute` + explicit focus
    /// set is tracked as a Phase-B follow-up; the cursor path is reliable on
    /// every app that accepts a click, which is the wide case today.
    @discardableResult
    public func type(
        ref: ElementRef,
        text: String,
        pressEnter: Bool = false,
        clearFirst: Bool = false,
        in map: ScreenMap,
        stabilizer: RefStabilizer? = nil
    ) async throws -> TypeResult {

        let resolution = ElementResolver.resolve(
            ref: ref,
            identityKey: nil,
            label: nil,
            preferredRole: nil,
            nearPoint: nil,
            in: map,
            stabilizer: stabilizer,
            db: nil
        )
        let element: ScreenElement
        switch resolution {
        case .success(let r): element = r.element
        case .failure: throw TypeError.unreachable(ref: ref)
        }

        // Role gate: refuse to type into anything that isn't a text-accepting
        // element. The disambiguator's label match will happily pick an
        // AXGroup titled "Message composer" — if we focus that with a click,
        // the subsequent typeString fires keystrokes at whatever was
        // previously focused (a quiet data-leak risk in chat apps). Being
        // explicit tells the LLM to re-disambiguate against a descendant
        // text input rather than retry the same ambiguous ref.
        if !isTextAcceptingRole(element.role) {
            throw TypeError.notTextInput(ref: element.ref, role: element.role)
        }

        // Secure Input Mode refusal — password fields are marked via AX subrole.
        // The PrivacyFirewall has the same probe; we duplicate the dlsym here
        // so SemanticExecutor stays independent of the firewall's actor.
        let isPasswordField = element.state.contains(.password)
            || element.subrole == "AXSecureTextField"
        if isPasswordField && SecureInputProbe.isActive() {
            throw TypeError.secureInputActive(ref: element.ref)
        }

        let started = Date()
        let resolvedKey = stabilizer?.identityKey(for: element.ref)

        // Focus the element. Prefer a click at its clickPoint — most text-field
        // focus works the same way the user would focus it: a click. Some apps
        // accept AX focus directly, but the cursor path is universal.
        guard let focusPoint = element.clickPoint ?? element.bounds.map({
            CGPoint(x: $0.midX, y: $0.midY)
        }) else {
            throw TypeError.unreachable(ref: element.ref)
        }
        do {
            try GestureExecutor.click(at: focusPoint, button: .left, count: 1)
        } catch {
            throw TypeError.gesture(error)
        }

        // Optional: clear first via ⌘A + delete. Cheap, matches what a user
        // would do, and works in every text control that accepts keyboard focus.
        if clearFirst {
            do {
                try GestureExecutor.keyCombo(keys: [.character("a")], modifiers: [.command])
                try GestureExecutor.keyPress(.delete)
            } catch {
                throw TypeError.gesture(error)
            }
        }

        // Type the payload. `typeString` already registers a single paste-class
        // suppression handle so perception tags the resulting UI deltas as agent.
        do {
            try await GestureExecutor.typeString(text)
        } catch {
            throw TypeError.gesture(error)
        }

        if pressEnter {
            do { try GestureExecutor.keyPress(.enter) }
            catch { throw TypeError.gesture(error) }
        }

        recordTypeStep(element: element, identityKey: resolvedKey, text: text)
        return TypeResult(
            ref: element.ref,
            identityKey: resolvedKey,
            path: .cursor,
            latencyMs: elapsedMs(from: started),
            charactersTyped: text.count,
            pressedEnter: pressEnter
        )
    }

    /// True when the role can accept keystrokes directly. Web areas and
    /// combo-boxes are included because many browsers / popup pickers expose
    /// their interior text field via a compound role — a cursor click into
    /// their bounds lands on the editable child.
    private func isTextAcceptingRole(_ role: ElementRole) -> Bool {
        switch role {
        case .textField, .textArea, .comboBox, .webArea:
            return true
        default:
            return false
        }
    }

    // MARK: - Cursor fallback

    private func fallbackToCursor(
        element: ScreenElement,
        identityKey: String?,
        mouseButton: MouseButton,
        started: Date,
        reason: String?
    ) throws -> PressResult {
        guard let point = element.clickPoint ?? element.bounds.map({
            CGPoint(x: $0.midX, y: $0.midY)
        }) else {
            throw PressError.unreachable(ref: element.ref)
        }
        do {
            try GestureExecutor.click(at: point, button: mouseButton, count: 1)
        } catch {
            throw PressError.gesture(error)
        }
        recordPressStep(element: element, identityKey: identityKey)
        return PressResult(
            ref: element.ref,
            identityKey: identityKey,
            path: .cursor,
            latencyMs: elapsedMs(from: started),
            succeeded: true,
            fallbackReason: reason
        )
    }

    // MARK: - SkillRecorder hook

    /// Forward a successful press to the ambient skill recorder. Fire-and-
    /// forget inside a Task so recording never delays the executor's
    /// return. The recorder itself gates on `Defaults[.workflowRecorderEnabled]`
    /// (propagated via `SkillRecorder.setEnabled`) — nothing is persisted
    /// unless the user opted in.
    private func recordPressStep(element: ScreenElement, identityKey: String?) {
        guard let key = identityKey else { return }
        let step = SkillStep(
            op: .press,
            identityKey: key,
            appBundleID: element.appBundleID,
            params: [:],
            paramRef: nil,
            resultDigest: nil
        )
        Task { await SkillRecorder.shared.record(step) }
    }

    /// Same hook for successful `type` actions. `text` is the payload the
    /// user (or agent) typed into the target; the skill compiler will
    /// detect variance across repeated runs and turn it into a `SkillParam`.
    private func recordTypeStep(element: ScreenElement, identityKey: String?, text: String) {
        guard let key = identityKey else { return }
        let step = SkillStep(
            op: .type,
            identityKey: key,
            appBundleID: element.appBundleID,
            params: ["text": text],
            paramRef: nil,
            resultDigest: nil
        )
        Task { await SkillRecorder.shared.record(step) }
    }

    // MARK: - AX lookup

    /// Walk the live AX tree for `bundleID`'s frontmost process and return the
    /// `AXUIElement` that best matches `element`. Match criteria, in order:
    ///
    ///   1. AX role string equals the raw role behind `element.role`.
    ///   2. AX title or description equals `element.label` (when label is not
    ///      empty). Label-less elements fall back to bounds-only matching.
    ///   3. Bounds center within 8 px of `element.bounds.mid`.
    ///
    /// Returns nil if no unique match was found. Callers fall back to the
    /// cursor path on nil — better to click visibly than invoke the wrong
    /// element silently.
    private func locateAXElement(
        for element: ScreenElement,
        bundleID: String
    ) -> AXUIElement? {
        guard let pid = pidForBundleID(bundleID) else { return nil }
        let app = AXUIElementCreateApplication(pid)

        let targetRole = axRoleString(for: element.role)
        let targetBounds = element.bounds
        let targetLabelNormalized = Self.normalizeLabel(element.label)

        var best: (AXUIElement, CGFloat)?
        var visited = 0
        let visitLimit = 4_000 // Keep the walker bounded — power users have big AX trees.
        // Wall-clock deadline in addition to the visit cap. `AXAttributes.getChildren`
        // is an IPC round-trip that can take ms on Electron apps — 4 000 visits
        // at 5 ms = 20 s. The deadline short-circuits the walk so the caller
        // doesn't block the cooperative thread (the fallback cursor click is
        // always available).
        let deadline = Date().addingTimeInterval(TimeInterval(Self.axWalkDeadlineMs) / 1000)
        var timedOut = false

        walk(element: app, depth: 0, maxDepth: 18, visited: &visited, limit: visitLimit,
             deadline: deadline, timedOut: &timedOut) { candidate in
            guard let role = AXAttributes.getRole(candidate), role == targetRole else { return }
            // Label match — normalize both sides (lowercase + Unicode fold +
            // whitespace collapse + 40-char truncate) to survive localized
            // strings, trailing ellipses, and animation jitter where the
            // title is briefly "Saving…" rather than "Save". Skip entirely
            // when the target has no label (role + bounds do the work).
            if !targetLabelNormalized.isEmpty {
                let candidateLabel = Self.normalizeLabel(AXAttributes.bestLabel(candidate))
                if candidateLabel != targetLabelNormalized
                    && !candidateLabel.contains(targetLabelNormalized)
                    && !targetLabelNormalized.contains(candidateLabel) {
                    return
                }
            }
            // Bounds proximity — the authoritative tiebreaker when multiple
            // elements share a role+label (two "Close" buttons in sibling
            // dialogs).
            let candidateBounds = axBounds(of: candidate)
            let distance = centerDistance(candidateBounds, targetBounds)
            if best == nil || distance < best!.1 {
                best = (candidate, distance)
            }
        }

        if timedOut { return nil }

        // Size-proportional tolerance — an 8 px hard threshold is too loose
        // for a 16 × 16 toolbar icon (adjacent neighbors ~40 pt away, but an
        // aliased rect center can drift 10+ px) and too tight for a 300 × 48
        // modal button mid-animation (bounds can drift 20+ px between ticks).
        // Scale with the element: ~25 % of the shorter side, clamped to
        // [4, 24] pt so the extremes stay sane.
        let tolerance: CGFloat
        if let b = targetBounds {
            let minSide = min(b.width, b.height)
            tolerance = max(4, min(24, minSide * 0.25))
        } else {
            tolerance = 8
        }
        if let (el, distance) = best, distance <= tolerance {
            return el
        }
        return nil
    }

    private func walk(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visited: inout Int,
        limit: Int,
        deadline: Date,
        timedOut: inout Bool,
        visit: (AXUIElement) -> Void
    ) {
        guard visited < limit, depth <= maxDepth, !timedOut else { return }
        // Deadline is checked per-node rather than per-child so a deep tree
        // still short-circuits quickly without paying for the child array
        // fetch on every level.
        if Date() >= deadline { timedOut = true; return }
        visited += 1
        visit(element)
        guard let children = AXAttributes.getChildren(element) else { return }
        for child in children {
            walk(element: child, depth: depth + 1, maxDepth: maxDepth, visited: &visited,
                 limit: limit, deadline: deadline, timedOut: &timedOut, visit: visit)
            if visited >= limit || timedOut { return }
        }
    }

    /// Lowercase + Unicode fold + whitespace collapse + 40-char truncate.
    /// Mirrors the `RefStabilizer`'s internal label normalization so the AX
    /// walker and the identity-key grammar agree on string identity.
    private static func normalizeLabel(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                 locale: nil)
        let collapsed = folded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(40))
    }

    private func axBounds(of element: AXUIElement) -> CGRect? {
        guard let pos = AXAttributes.getPosition(element),
              let size = AXAttributes.getSize(element) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private func centerDistance(_ lhs: CGRect?, _ rhs: CGRect?) -> CGFloat {
        guard let l = lhs, let r = rhs else { return .greatestFiniteMagnitude }
        let dx = l.midX - r.midX
        let dy = l.midY - r.midY
        return hypot(dx, dy)
    }

    private func pidForBundleID(_ bundleID: String) -> pid_t? {
        if let cached = pidCache[bundleID] { return cached }
        guard let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?
            .processIdentifier else { return nil }
        pidCache[bundleID] = pid
        return pid
    }

    /// Invalidate cached pid / reset failure counters when we observe a
    /// clean AX success — the bundle is behaving, so the next press should
    /// try the AX path again even if we'd previously demoted it.
    private func noteAXSuccess(bundleID: String) {
        axFailureCounts[bundleID] = 0
    }

    /// Increment the failure counter for `bundleID`. Returns true if the
    /// bundle should be demoted (skip AX next time). Once demoted, the
    /// press path still attempts CDP / cursor — only the AX walker is
    /// short-circuited. Sticky until a subsequent `noteAXSuccess`.
    private func noteAXFailure(bundleID: String) -> Bool {
        let count = (axFailureCounts[bundleID] ?? 0) + 1
        axFailureCounts[bundleID] = count
        return count >= axDemotionThreshold
    }

    /// Query whether this bundle has been demoted (>= 3 consecutive AX
    /// failures). Callers consult this before starting the AX walk so we
    /// don't burn latency on a bundle we know won't answer.
    private func shouldSkipAXPath(for bundleID: String) -> Bool {
        (axFailureCounts[bundleID] ?? 0) >= axDemotionThreshold
    }

    /// Reverse of `ElementRole.from(axRole:)`. Strings are stable AX API
    /// constants, so this never breaks with macOS updates. Unknown roles map
    /// to an empty string — callers skip role equality when the role is `.unknown`.
    private func axRoleString(for role: ElementRole) -> String {
        switch role {
        case .button:            return "AXButton"
        case .textField:         return "AXTextField"
        case .textArea:          return "AXTextArea"
        case .checkbox:          return "AXCheckBox"
        case .radioButton:       return "AXRadioButton"
        case .popUpButton:       return "AXPopUpButton"
        case .comboBox:          return "AXComboBox"
        case .slider:            return "AXSlider"
        case .stepper:           return "AXIncrementor"
        case .link:              return "AXLink"
        case .tab:               return "AXTab"
        case .menuItem:          return "AXMenuItem"
        case .menuBarItem:       return "AXMenuBarItem"
        case .colorWell:         return "AXColorWell"
        case .window:            return "AXWindow"
        case .group:             return "AXGroup"
        case .scrollArea:        return "AXScrollArea"
        case .table:             return "AXTable"
        case .outline:           return "AXOutline"
        case .list:              return "AXList"
        case .tabGroup:          return "AXTabGroup"
        case .toolbar:           return "AXToolbar"
        case .menuBar:           return "AXMenuBar"
        case .splitGroup:        return "AXSplitGroup"
        case .sheet:             return "AXSheet"
        case .staticText:        return "AXStaticText"
        case .image:             return "AXImage"
        case .webArea:           return "AXWebArea"
        case .progressIndicator: return "AXProgressIndicator"
        // No AX role for toggle/dialog/OCR/unknown — label-only match.
        case .toggle, .dialog, .toolbarItem, .ocrText, .ocrButton, .unknown:
            return ""
        }
    }

    // MARK: - Timing

    private func elapsedMs(from start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
