import CoreGraphics
import Foundation
import AppKit

// MARK: - PasteboardChangeCountSource

/// Protocol for abstracting `NSPasteboard` change-count polling so tests can
/// inject a fake pasteboard without a real NSPasteboard instance.
public protocol PasteboardChangeCountSource: AnyObject {
    var changeCount: Int { get }
}

extension NSPasteboard: PasteboardChangeCountSource {}

// MARK: - CG reconfig C callback

/// File-private C-compatible callback for CGDisplayRegisterReconfigurationCallback.
/// Hops to the main queue and posts .displayConfigurationChanged to the bus,
/// filtering out the begin-configuration event (which fires before the change
/// completes and carries no useful layout information).
private func cgReconfigCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    // .beginConfigurationFlag fires before the reconfiguration — skip it.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    let me = Unmanaged<WorkspaceTriggerSource>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { me.bus.post(.displayConfigurationChanged) }
}

// MARK: - WorkspaceTriggerSource

/// Posts `TriggerReason`s to a `TriggerBus` based on NSWorkspace notifications
/// (app activation/termination, sleep/wake), display configuration changes, and
/// pasteboard change-count polling.
@MainActor
public final class WorkspaceTriggerSource {

    // MARK: - Dependencies

    fileprivate let bus: TriggerBus
    private let pasteboard: PasteboardChangeCountSource

    // MARK: - State

    private var observers: [NSObjectProtocol] = []
    private var started = false

    // MARK: - Pasteboard polling

    private var pasteboardPollTask: Task<Void, Never>?
    private var lastPasteboardChangeCount: Int = 0

    // MARK: - CG callback registration guard

    /// True while the CG reconfig callback is registered. The callback passes
    /// `Unmanaged.passUnretained(self)` as its context, so it MUST be removed
    /// (via `CGDisplayRemoveReconfigurationCallback`, which requires the exact
    /// same C-function pointer + context) before this object deallocates —
    /// otherwise the C callback dereferences freed memory on the next display
    /// reconfiguration. We balance register in `start()` with remove in `stop()`
    /// / `deinit`. Re-registering with the same callback and self pointer on a
    /// later `start()` is valid because the remove matches on that exact pair.
    private var didRegisterCGCallback = false

    // MARK: - Init

    public init(
        bus: TriggerBus = .shared,
        pasteboard: PasteboardChangeCountSource = NSPasteboard.general
    ) {
        self.bus = bus
        self.pasteboard = pasteboard
        self.lastPasteboardChangeCount = pasteboard.changeCount
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter

        // App activation.
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                let reason = TriggerReason.appActivated(
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier
                )
                self?.bus.post(reason)
            }
        )

        // App termination.
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                self?.bus.post(.appTerminated(pid: app.processIdentifier))
            }
        )

        // System sleep.
        observers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.bus.post(.systemSleep) }
        )

        // System wake.
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.bus.post(.systemWake) }
        )

        // Display reconfiguration — register the C callback. Balanced by the
        // matching CGDisplayRemoveReconfigurationCallback in stop()/deinit so the
        // callback can never fire after self deallocates.
        if !didRegisterCGCallback {
            didRegisterCGCallback = true
            CGDisplayRegisterReconfigurationCallback(
                cgReconfigCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        // Pasteboard polling at 500 ms.
        lastPasteboardChangeCount = pasteboard.changeCount
        pasteboardPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let current = self.pasteboard.changeCount
                    if current != self.lastPasteboardChangeCount {
                        self.lastPasteboardChangeCount = current
                        self.bus.post(.pasteboardChanged(changeCount: current))
                    }
                }
            }
        }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()

        pasteboardPollTask?.cancel()
        pasteboardPollTask = nil

        // Remove the process-global reconfiguration callback so no stale
        // .displayConfigurationChanged events post after stop() and the callback
        // no longer holds this instance's self pointer once it is deallocated.
        removeCGReconfigCallback()

        started = false
    }

    // MARK: - Deinit

    deinit {
        // The CG reconfig callback captures an unretained pointer to self, so it
        // must be removed before deallocation or it will deref freed memory on
        // the next display reconfiguration. CGDisplayRemoveReconfigurationCallback
        // matches on the exact (function pointer, userInfo) pair, so passing the
        // same callback and self pointer removes precisely this instance's
        // registration. The function pointer and context are both fixed values,
        // so this is safe to call from deinit.
        if didRegisterCGCallback {
            CGDisplayRemoveReconfigurationCallback(
                cgReconfigCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    // MARK: - CG callback teardown

    /// Remove the CG reconfiguration callback registered in `start()`, using the
    /// exact same function pointer + context the API requires for a match.
    private func removeCGReconfigCallback() {
        guard didRegisterCGCallback else { return }
        didRegisterCGCallback = false
        CGDisplayRemoveReconfigurationCallback(
            cgReconfigCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
