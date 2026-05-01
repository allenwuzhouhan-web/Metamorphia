/*
 * Metamorphia
 * AX-based text-selection sensor for the activity observation spine.
 *
 * Subscribes via TriggerBus to the `.selection` lane. When the bus delivers
 * an `.axSelectedTextChanged(pid:)` reason, the handler reads the selected
 * range length (CFRange.length only — never the text content) via the
 * Accessibility API and emits `.selectionChanged` into ActivityStream.
 *
 * kAXSelectedTextChangedNotification is posted by:
 *   Safari, Mail, Notes, TextEdit, Xcode, Pages, Numbers, Slack, Messages,
 *   most AppKit text views (NSTextField, NSTextView).
 * Does NOT post in:
 *   VS Code, Sublime Text, Figma, iTerm2, Terminal.app, most Electron apps
 *   with custom canvas text input. No workaround — we simply don't see events.
 */

import AppKit
import ApplicationServices
import Defaults
import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - Defaults key

extension Defaults.Keys {
    /// When false, SelectionTracker.start() is a no-op and no selection events
    /// enter the activity spine. Default: false — opt-in because AX reads on
    /// every text selection change may be noticeable on slower machines.
    static let observeSelection = Key<Bool>(
        "metamorphia.sensor.selection.enabled",
        default: false
    )

    /// Controls whether the super-perceiver uses a push (AX-observer-driven)
    /// or pull (polling) strategy. Push reduces idle CPU at roughly the same
    /// perception latency — AX observers fire on state changes, coalesced
    /// into a TriggerBus batch, and the PushPerceptionDriver drives partial
    /// captures only on the lanes that actually changed. Default: "push" —
    /// users explicitly set "pull" in Settings if they hit AX-observer
    /// trouble on a specific app (Electron apps with weak AX observation
    /// are the usual suspects).
    static let perceptionTriggerMode = Key<String>(
        "metamorphia.perception.triggerMode",
        default: "push"
    )

    /// Phase E — opt-in workflow recorder. When enabled, `SemanticExecutor`
    /// taps every successful `press` / `type` into `SkillRecorder`, and
    /// `SkillCompiler` periodically clusters repeated sequences into
    /// `CompiledSkill`s the user can register as named tools. Default:
    /// false — privacy-sensitive because the recorded steps include
    /// identity keys for elements the user interacted with, so it's
    /// strictly opt-in. All recording stays on-device.
    static let workflowRecorderEnabled = Key<Bool>(
        "metamorphia.learning.workflowRecorder",
        default: false
    )
}

// MARK: - SelectionTracker

/// Emits ``ActivityEvent/selectionChanged`` whenever the user selects text in
/// a frontmost application that supports `kAXSelectedTextChangedNotification`.
///
/// ## Privacy
/// Only the *length* of the selected range (CFRange.length) is read from the
/// Accessibility API. `kAXSelectedTextAttribute` is never accessed — the content
/// never enters this process.
///
/// ## Integration
/// Uses `TriggerBus` as the sole event source. The `AXObserverPool` fires
/// `kAXSelectedTextChangedNotification` → `TriggerBus.post(.axSelectedTextChanged(pid:))`
/// on the AXObserverThread; this class registers a `.selection`-lane handler that
/// wakes on the main actor to do the bounded AX read.
///
/// ## Lifecycle
/// ```swift
/// let tracker = SelectionTracker(stream: activityStream)
/// tracker.start()
/// // ...
/// tracker.stop()
/// ```
@MainActor
public final class SelectionTracker {

    // MARK: - Private state

    private let stream: ActivityStream
    private let bus: TriggerBus
    private let observerPool: AXObserverPool
    private var handlerID: TriggerBus.HandlerID?
    private var running = false
    private var pendingEmit: DispatchWorkItem?

    // MARK: - Init

    public init(
        stream: ActivityStream,
        bus: TriggerBus = .shared,
        observerPool: AXObserverPool = .shared
    ) {
        self.stream = stream
        self.bus = bus
        self.observerPool = observerPool
    }

    // MARK: - Lifecycle

    /// Start the sensor. Idempotent — calling twice registers only one handler.
    public func start() {
        guard !running else { return }
        running = true

        // The pool is shared; calling start() here is safe — it is idempotent.
        observerPool.start()

        handlerID = bus.register(
            interested: [.selection],
            debounceMs: 300
        ) { [weak self] batch in
            await self?.onTrigger(batch)
        }
    }

    /// Stop the sensor. Cancels any pending work and unregisters the handler.
    public func stop() {
        guard running else { return }
        running = false

        pendingEmit?.cancel()
        pendingEmit = nil

        if let id = handlerID {
            // bus.unregister requires @MainActor; we already are.
            bus.unregister(id)
            handlerID = nil
        }

        // Do NOT call observerPool.stop() — other sensors depend on the pool.
    }

    // MARK: - Internal test seam

    /// Exposes the current handler registration ID for unit tests.
    /// Nil before `start()` and after `stop()`.
    var _handlerIDForTest: TriggerBus.HandlerID? { handlerID }

    // MARK: - TriggerBus handler

    private func onTrigger(_ batch: TriggerBatch) async {
        guard Defaults[.observeSelection], running else { return }

        // Collect unique pids from axSelectedTextChanged reasons in this batch.
        var seen = Set<pid_t>()
        for reason in batch.reasons {
            if case .axSelectedTextChanged(let pid) = reason {
                seen.insert(pid)
            }
        }

        for pid in seen {
            guard let (role, len) = readSelectionLength(pid: pid) else { continue }
            guard len > 0, len <= 1_000_000 else { continue }

            let bid = bundleID(for: pid) ?? "unknown"
            let now = Date()

            // Gate through PrivacyFirewall before emit. axRoleHint lets the
            // firewall reject secure-field selections without us ever knowing
            // the selection came from a password field.
            let candidate = PrivacyFirewall.Candidate(
                bundleID: bid,
                kind: "selectionChanged",
                axRoleHint: role,
                at: now
            )
            let (_, drop) = await PrivacyFirewall.shared.admit(lane: "selection", candidate)
            guard case .ok = drop else { continue }

            let event = ActivityEvent.selectionChanged(
                bundleID: bid,
                role: role,
                selectionLength: len,
                at: now
            )
            Task { await stream.emit(event) }
        }
    }

    // MARK: - AX read (length only)

    /// Read the selected range length from the focused UI element of `pid`.
    ///
    /// Returns `(role, length)` where `role` is the AX role string (e.g.
    /// `"AXTextArea"`) and `length` is CFRange.length for the selected range.
    /// Returns `nil` if the pid is unresponsive or does not have a text
    /// selection at the moment of the call.
    ///
    /// - Important: `kAXSelectedTextAttribute` is **never** read. Only
    ///   `kAXSelectedTextRangeAttribute` (a CFRange value type) is accessed.
    private func readSelectionLength(pid: pid_t) -> (role: String, length: Int)? {
        do {
            return try AXTimeoutQueue.shared.run(pid: pid, timeout: 0.1) {
                let appElement = AXUIElementCreateApplication(pid)

                // Step 1: get the focused element.
                var focusedRef: CFTypeRef?
                let focusResult = AXUIElementCopyAttributeValue(
                    appElement,
                    kAXFocusedUIElementAttribute as CFString,
                    &focusedRef
                )
                guard focusResult == .success,
                      let focusedRef = focusedRef else { return nil }
                let focused = focusedRef as! AXUIElement  // swiftlint:disable:this force_cast

                // Step 2: read the role.
                var roleRef: CFTypeRef?
                let roleResult = AXUIElementCopyAttributeValue(
                    focused,
                    kAXRoleAttribute as CFString,
                    &roleRef
                )
                guard roleResult == .success,
                      let role = roleRef as? String else { return nil }

                // Step 3: read the selected range (length only, no text content).
                var rangeRef: CFTypeRef?
                let rangeResult = AXUIElementCopyAttributeValue(
                    focused,
                    kAXSelectedTextRangeAttribute as CFString,
                    &rangeRef
                )
                guard rangeResult == .success,
                      let axValue = rangeRef,
                      CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }

                var range = CFRange()
                let extracted = AXValueGetValue(
                    axValue as! AXValue,  // swiftlint:disable:this force_cast
                    .cfRange,
                    &range
                )
                guard extracted else { return nil }

                return (role, range.length)
            }
        } catch is AXTimeoutError {
            // Pid is wedged; skip silently.
            return nil
        } catch is AXPoisonedError {
            // Pid was recently wedged and is still in the poison window; skip.
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Bundle ID resolution

    private func bundleID(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
