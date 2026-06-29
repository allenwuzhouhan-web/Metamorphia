/*
 * Metamorphia
 * Frontmost-app + window-title sensor for the activity observation spine.
 *
 * Emits ActivityEvent.focusChanged into ActivityStream on every meaningful
 * focus transition — app switch or window/tab change within the same app.
 *
 * Signal sources, in priority order:
 *  1. NSWorkspace.didActivateApplicationNotification — fires on every app switch.
 *  2. A 1 Hz Task-based poll — catches window/tab changes inside one app that
 *     workspace notifications never see.
 *
 * Debounce: rapid switches within 150 ms (e.g. Cmd-Tab storms) are coalesced
 * to the latter change via DispatchWorkItem + cancel.
 *
 * Window titles are read via the Accessibility API. If AX is not trusted, the
 * sensor continues emitting with windowTitle = nil and logs once.
 *
 * Denylist: a hard-coded set of sensitive bundle IDs for which windowTitle is
 * forcibly set to nil even when AX is available. The bundle ID itself is
 * always emitted (it's useful signal on its own).
 */

import AppKit
import ApplicationServices
import Defaults
import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - Defaults key

extension Defaults.Keys {
    /// When false, AppFocusSensor.start() is a no-op and no focus events enter
    /// the activity spine. Default: true. Can be toggled live without restarting
    /// the app — the sensor checks this in its notification handler and poll loop.
    static let observeAppFocus = Key<Bool>(
        "metamorphia.sensor.appFocus.enabled",
        default: true
    )
}

// MARK: - AppFocusSensor

@MainActor
public final class AppFocusSensor {

    // MARK: - Private state

    private let stream: ActivityStream

    /// Last snapshot pushed to the stream. Nil until the first emit.
    private var lastEmitted: FocusSnapshot?

    /// Pending debounce work item. Cancelled on each new signal, replaced by a
    /// new item scheduled 150 ms out.
    private var pendingWork: DispatchWorkItem?

    /// Whether AX is trusted. Read once at start(); never re-checked — AX
    /// trust cannot be revoked at runtime without quitting the app.
    private var axTrusted = false

    /// True after start() has been called, false after stop().
    private var running = false

    /// Workspace notification observer token.
    private var workspaceObserver: Any?

    /// 1 Hz background poll task.
    private var pollTask: Task<Void, Never>?

    // MARK: - Init

    public init(stream: ActivityStream) {
        self.stream = stream
    }

    // MARK: - Lifecycle

    public func start() {
        guard Defaults[.observeAppFocus] else { return }
        guard !running else { return }
        running = true

        // Check AX permission once.
        axTrusted = AXIsProcessTrusted()
        if !axTrusted {
            print("[AppFocusSensor] AX not trusted — window titles unavailable")
        }

        // Register workspace notification observer.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.scheduleEmit()
            }
        }

        // Start the 1 Hz fallback poll for within-app window/tab changes.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.scheduleEmit()
                }
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }

        pollTask?.cancel()
        pollTask = nil

        pendingWork?.cancel()
        pendingWork = nil
    }

    // MARK: - Debounce + emit

    /// Cancel any pending work and schedule a new capture 150 ms from now.
    private func scheduleEmit() {
        pendingWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.captureAndEmit()
            }
        }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.150, execute: item)
    }

    /// Read the current frontmost app + window title, deduplicate, and emit.
    private func captureAndEmit() async {
        // Re-check the feature gate on every emit so a live toggle takes effect
        // without restarting the sensor (matches the pattern in ActivitySpineBridge).
        guard Defaults[.observeAppFocus], running else { return }

        guard let snapshot = captureSnapshot() else { return }

        // Suppress exact duplicate.
        if let last = lastEmitted, last == snapshot { return }
        lastEmitted = snapshot

        await stream.emit(.focusChanged(
            bundleID: snapshot.bundleID,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            pid: snapshot.pid,
            at: .now
        ))
    }

    // MARK: - Snapshot capture

    /// Read the current frontmost-app state from NSWorkspace and (if AX-trusted)
    /// the focused window title via the Accessibility API.
    private func captureSnapshot() -> FocusSnapshot? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        let bundleID = frontApp.bundleIdentifier ?? "unknown"
        let appName  = frontApp.localizedName ?? "Unknown"
        let pid      = frontApp.processIdentifier

        var windowTitle: String?

        if axTrusted && !Self.titleDenylist.contains(bundleID) && !AppFocusDenylistStore.shared.contains(bundleID: bundleID) {
            // Route the synchronous AX reads through the bounded-timeout queue
            // (the established safe pattern, see SelectionTracker.readSelectionLength).
            // A hung/poisoned frontmost app now throws — yielding a nil title —
            // instead of blocking the main actor until the ~6 s default AX timeout.
            windowTitle = try? AXTimeoutQueue.shared.run(pid: pid, timeout: 0.1) {
                let appElement = AXUIElementCreateApplication(pid)
                var focusedWindow: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    appElement,
                    kAXFocusedWindowAttribute as CFString,
                    &focusedWindow
                ) == .success, let window = focusedWindow else { return nil as String? }
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    (window as! AXUIElement),
                    kAXTitleAttribute as CFString,
                    &titleRef
                ) == .success else { return nil as String? }
                return titleRef as? String
            } ?? nil
        }
        // Denylist apps: bundleID is kept, title is redacted to nil.
        // axTrusted == false: title stays nil (set above by not entering the block).

        return FocusSnapshot(
            bundleID: bundleID,
            appName: appName,
            windowTitle: windowTitle,
            pid: pid
        )
    }

    // MARK: - Denylist

    /// Bundle IDs for which the window title is always redacted to nil.
    /// The bundle ID itself is still reported.
    static let titleDenylist: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.dashlane-mac",
        "org.keepassxc.keepassxc",
        "me.proton.pass",
        "com.sinew.Enpass-Desktop",
    ]
}

// MARK: - FocusSnapshot (value type for deduplication)

/// Lightweight value type capturing the last-emitted focus state so the sensor
/// can suppress duplicate events without storing an ActivityEvent.
private struct FocusSnapshot: Equatable {
    let bundleID: String
    let appName: String
    let windowTitle: String?
    let pid: Int32
}
