import ApplicationServices
import AppKit
import Foundation
import CoreFoundation

// MARK: - Callback context

/// Small heap object passed as refcon to the C-style AX observer callback.
/// Holds a weak back-reference to the pool so we never extend its lifetime,
/// plus the pid that lets us look up the attachment.
private final class AXObserverCallbackContext {
    weak var pool: AXObserverPool?
    let pid: pid_t

    init(pool: AXObserverPool, pid: pid_t) {
        self.pool = pool
        self.pid = pid
    }
}

// MARK: - C-style callback

/// Top-level C function required by AXObserverCreate.
/// Called on the AXObserverThread's CFRunLoop; do nothing expensive here.
private func axNotificationCallback(
    observer: AXObserver,
    element: AXUIElement,
    notifName: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    // The pointer was retained via passRetained at attach time.
    // We do NOT release here; that happens at detach time.
    let ctx = Unmanaged<AXObserverCallbackContext>.fromOpaque(refcon).takeUnretainedValue()
    ctx.pool?.handleAXNotification(
        observer: observer,
        element: element,
        name: notifName as String,
        pid: ctx.pid
    )
}

// MARK: - Sendable wrapper for raw callback context pointer
//
// UnsafeMutableRawPointer does not conform to Sendable. We own the refcount
// of this pointer (passRetained / release pair) so crossing concurrency
// domains is intentional and safe by construction.
private struct ContextPointer: @unchecked Sendable {
    let rawValue: UnsafeMutableRawPointer
}

// MARK: - TriggerBus nonisolated accessor
//
// TriggerBus.shared is @MainActor-isolated, but TriggerBus.post(_:) is
// nonisolated. We cache the reference here with nonisolated(unsafe) so the
// AX callback thread can call post without a Swift 6 isolation error.
// The value is written exactly once at startup before any callbacks fire.
private nonisolated(unsafe) let _triggerBusRef: TriggerBus = TriggerBus.shared

// MARK: - AXObserverPool

/// Per-pid push-based AX observer lifecycle manager.
///
/// Attaches to running applications, subscribes to a curated set of AX
/// notifications, and forwards each event to ``TriggerBus`` as a
/// ``TriggerReason``. All AX observer operations run on the shared
/// ``AXObserverThread`` CFRunLoop so the main thread is never blocked.
///
/// **Lifecycle**
/// Call ``start()`` once — it subscribes to `NSWorkspace` activation /
/// termination notifications and seeds the current frontmost app. Each
/// attach is idempotent; detach cleans up the CFRunLoop source and the
/// retained callback context.
///
/// **Permissions**
/// If `AXIsProcessTrusted()` returns `false` at attach time the call
/// silently returns `nil`. Prompt via PermissionVault (Wave 7) before
/// calling ``start()``.
public final class AXObserverPool: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = AXObserverPool()

    // MARK: - Handle

    /// Lightweight value returned by a successful ``attach(pid:bundleID:)``.
    public struct Handle: Sendable {
        public let pid: pid_t
        public let bundleID: String?
        public let attachedAt: Date
    }

    // MARK: - Watched notifications

    /// The AX notification names the pool registers for on every attached app.
    public static let watchedNotifications: [String] = [
        kAXApplicationActivatedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
        kAXValueChangedNotification as String,
        kAXSelectedTextChangedNotification as String,
        kAXWindowCreatedNotification as String,
        kAXTitleChangedNotification as String,
        kAXWindowMovedNotification as String,
    ]

    // MARK: - Private attachment record

    private struct Attachment {
        let pid: pid_t
        let bundleID: String?
        let observer: AXObserver
        let appElement: AXUIElement
        let attachedAt: Date
        /// Retained pointer to the callback context; released on detach.
        let contextPtr: UnsafeMutableRawPointer
    }

    // MARK: - State

    private let lock = NSLock()
    private var attachments: [pid_t: Attachment] = [:]
    /// pids for which a `detach` arrived while an `attach` was still in flight
    /// (between `attach()` returning and `performAttach` storing the record).
    /// `performAttach` consults this set so the freshly-created observer is torn
    /// down instead of leaked when the caller already asked to detach.
    private var pendingDetach: Set<pid_t> = []
    private var workspaceObserver: NSObjectProtocol?
    private var workspaceTerminateObserver: NSObjectProtocol?
    private var started = false

    // MARK: - Init

    public init() {}

    // MARK: - Lifecycle

    /// Start the pool. Idempotent — safe to call multiple times.
    ///
    /// Ensures the AXObserverThread is running, registers for workspace
    /// activation/termination events, and seeds an attachment to the current
    /// frontmost application.
    public func start() {
        lock.withLock {
            guard !started else { return }
            started = true

            AXObserverThread.shared.start()

            let nc = NSWorkspace.shared.notificationCenter

            workspaceObserver = nc.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self = self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                self.attach(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
            }

            workspaceTerminateObserver = nc.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self = self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                self.detach(pid: app.processIdentifier)
            }
        }

        // Seed frontmost app outside the lock (attach acquires the lock).
        if let app = NSWorkspace.shared.frontmostApplication {
            attach(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        }
    }

    /// Stop the pool. Detaches all observers and unregisters workspace listeners.
    public func stop() {
        var activateToken: NSObjectProtocol?
        var terminateToken: NSObjectProtocol?

        lock.withLock {
            guard started else { return }
            started = false
            activateToken = workspaceObserver
            terminateToken = workspaceTerminateObserver
            workspaceObserver = nil
            workspaceTerminateObserver = nil
        }

        let nc = NSWorkspace.shared.notificationCenter
        if let t = activateToken  { nc.removeObserver(t) }
        if let t = terminateToken { nc.removeObserver(t) }

        detachAll()
    }

    // MARK: - Attach / Detach

    /// Attach an AX observer to the process identified by `pid`.
    ///
    /// The operation runs asynchronously on the AXObserverThread. The returned
    /// ``Handle`` reflects the *intent* to attach; the underlying observer
    /// registration completes shortly after on the observer thread.
    ///
    /// Returns nil when:
    /// - Accessibility permission is not granted.
    /// - `AXObserverCreate` fails.
    /// - `pid` is already attached (returns a Handle from the existing record).
    @discardableResult
    public func attach(pid: pid_t, bundleID: String?) -> Handle? {
        guard AXIsProcessTrusted() else { return nil }

        // Idempotency: return existing Handle if already attached. Also clear any
        // stale pending-detach for this pid — a fresh attach intent supersedes a
        // detach that arrived before the previous attach landed, so performAttach
        // must not tear this new observer down.
        if let existing = lock.withLock({ () -> Attachment? in
            pendingDetach.remove(pid)
            return attachments[pid]
        }) {
            return Handle(pid: existing.pid, bundleID: existing.bundleID, attachedAt: existing.attachedAt)
        }

        let attachedAt = Date()
        let ctx = AXObserverCallbackContext(pool: self, pid: pid)
        // passRetained bumps the refcount; the raw pointer is stored in the
        // Attachment and released exactly once when detach runs.
        let ctxBox = ContextPointer(rawValue: Unmanaged.passRetained(ctx).toOpaque())

        AXObserverThread.shared.perform { [weak self] in
            guard let self = self else {
                Unmanaged<AXObserverCallbackContext>.fromOpaque(ctxBox.rawValue).release()
                return
            }
            self.performAttach(
                pid: pid,
                bundleID: bundleID,
                attachedAt: attachedAt,
                ctxPtr: ctxBox.rawValue
            )
        }

        return Handle(pid: pid, bundleID: bundleID, attachedAt: attachedAt)
    }

    /// Detach the observer for `pid`. No-op if `pid` is not attached.
    ///
    /// If an `attach` for the same pid is still in flight on the observer thread
    /// (the record isn't stored yet), we mark the pid pending-detach so
    /// `performAttach` tears the new observer down instead of leaking it.
    public func detach(pid: pid_t) {
        let attachment = lock.withLock { () -> Attachment? in
            if let existing = attachments.removeValue(forKey: pid) {
                return existing
            }
            // No record yet — an attach may be in flight. Record the intent so
            // performAttach cleans up when it lands.
            pendingDetach.insert(pid)
            return nil
        }
        guard let attachment = attachment else { return }
        scheduleDetachCleanup(attachment)
    }

    /// Detach all currently attached observers.
    public func detachAll() {
        let all = lock.withLock { () -> [Attachment] in
            let values = Array(attachments.values)
            attachments.removeAll()
            return values
        }
        for attachment in all {
            scheduleDetachCleanup(attachment)
        }
    }

    /// Returns the set of pids that have active (or in-flight) attachments.
    public func attachedPids() -> Set<pid_t> {
        lock.withLock { Set(attachments.keys) }
    }

    // MARK: - Internal: observer-thread attach

    private func performAttach(
        pid: pid_t,
        bundleID: String?,
        attachedAt: Date,
        ctxPtr: UnsafeMutableRawPointer
    ) {
        let appElement = AXUIElementCreateApplication(pid)

        var observerRef: AXObserver?
        let createResult = AXObserverCreate(pid, axNotificationCallback, &observerRef)
        guard createResult == .success, let observer = observerRef else {
            // Release the context we retained during attach().
            Unmanaged<AXObserverCallbackContext>.fromOpaque(ctxPtr).release()
            return
        }

        guard let runLoop = AXObserverThread.shared.runLoopRef() else {
            Unmanaged<AXObserverCallbackContext>.fromOpaque(ctxPtr).release()
            return
        }

        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)

        for notifName in AXObserverPool.watchedNotifications {
            let result = AXObserverAddNotification(observer, appElement, notifName as CFString, ctxPtr)
            // .cannotComplete and .notImplemented mean the app doesn't support
            // this notification; skip silently rather than failing the whole attach.
            if result != .success && result != .cannotComplete && result != .notImplemented {
                // Unexpected error — log and continue; partial subscription is
                // better than no subscription.
                _ = result
            }
        }

        let record = Attachment(
            pid: pid,
            bundleID: bundleID,
            observer: observer,
            appElement: appElement,
            attachedAt: attachedAt,
            contextPtr: ctxPtr
        )

        let shouldTearDown: Bool = lock.withLock {
            // A detach arrived while we were attaching on the observer thread —
            // honor it: do NOT store, tear the just-created observer down so it
            // isn't leaked.
            if pendingDetach.remove(pid) != nil {
                return true
            }
            // Guard against a concurrent attach that already filled the slot.
            guard attachments[pid] == nil else {
                // Already replaced (edge case) — release context and bail.
                Unmanaged<AXObserverCallbackContext>.fromOpaque(ctxPtr).release()
                return false
            }
            attachments[pid] = record
            return false
        }

        if shouldTearDown {
            // We're already on the observer thread, so clean up inline rather
            // than re-scheduling. Mirrors scheduleDetachCleanup's teardown.
            Self.teardownObserver(record)
        }
    }

    /// Synchronously tear down an observer's run-loop source, notifications, and
    /// retained callback context. Safe to call only on the AXObserverThread.
    /// `static` so the detach block needn't capture (and risk outliving / dropping)
    /// `self` — the teardown only needs the attachment and shared statics.
    private static func teardownObserver(_ attachment: Attachment) {
        if let runLoop = AXObserverThread.shared.runLoopRef() {
            for notifName in AXObserverPool.watchedNotifications {
                AXObserverRemoveNotification(
                    attachment.observer,
                    attachment.appElement,
                    notifName as CFString
                )
            }
            CFRunLoopRemoveSource(
                runLoop,
                AXObserverGetRunLoopSource(attachment.observer),
                .defaultMode
            )
        }
        // Balance the passRetained from attach().
        Unmanaged<AXObserverCallbackContext>.fromOpaque(attachment.contextPtr).release()
    }

    // MARK: - Internal: observer-thread detach

    private func scheduleDetachCleanup(_ attachment: Attachment) {
        AXObserverThread.shared.perform {
            // Always release the retained context, even if the run loop is gone —
            // teardownObserver releases unconditionally so the context can't leak.
            AXObserverPool.teardownObserver(attachment)
        }
    }

    // MARK: - Notification handling (hot path)

    /// Called from the AX observer callback on the AXObserverThread.
    /// Must not do any AX IPC. Only maps the notification to a TriggerReason
    /// and forwards to TriggerBus.
    func handleAXNotification(
        observer: AXObserver,
        element: AXUIElement,
        name: String,
        pid: pid_t
    ) {
        guard let reason = mapNotificationToReason(name, pid: pid, element: element) else { return }
        _triggerBusRef.post(reason)
    }

    /// Pure mapping from AX notification name to TriggerReason.
    /// Marked internal for unit testing.
    func mapNotificationToReason(
        _ name: String,
        pid: pid_t,
        element: AXUIElement
    ) -> TriggerReason? {
        // The kAX* constants are imported as String literals; no `as String` cast needed.
        switch name {
        case kAXApplicationActivatedNotification:
            // bundleID resolution is deferred — we're on the observer thread
            // and AX IPC is forbidden here. The pipeline resolves it later.
            return .appActivated(pid: pid, bundleID: nil)

        case kAXFocusedUIElementChangedNotification:
            return .axFocusedElementChanged(pid: pid)

        case kAXValueChangedNotification:
            return .axValueChanged(pid: pid, roleHint: nil)

        case kAXSelectedTextChangedNotification:
            return .axSelectedTextChanged(pid: pid)

        case kAXWindowCreatedNotification:
            return .axWindowCreated(pid: pid)

        case kAXTitleChangedNotification:
            return .axTitleChanged(pid: pid)

        case kAXWindowMovedNotification:
            return .axWindowMoved(pid: pid)

        default:
            return nil
        }
    }
}
