import Foundation

// MARK: - TriggerBatch

/// A coalesced group of ``TriggerReason``s dispatched to a registered handler.
///
/// Multiple reasons that arrive within a subscription's debounce window are
/// merged into a single batch. The batch captures the earliest `firstSeen`
/// timestamp and the maximum `urgency` across all constituent reasons.
public struct TriggerBatch: Sendable {
    /// All reasons coalesced into this batch, in arrival order.
    public let reasons: [TriggerReason]
    /// Union of every reason's `affectedLanes`.
    public let affectedLanes: LaneSet
    /// Timestamp of the first reason in this batch.
    public let firstSeen: Date
    /// Timestamp when the debounce window closed and the batch was dispatched.
    public let coalescedAt: Date
    /// Maximum `urgency` across all reasons in this batch.
    public let urgency: UInt8
}

// MARK: - TriggerBus

/// A @MainActor coalescing inbox that receives ``TriggerReason``s from any
/// thread and dispatches merged ``TriggerBatch``es to registered handlers.
///
/// ## Threading
/// `post(_:)` is `nonisolated` and safe to call from any thread or queue.
/// All internal state mutations run on the main actor.
///
/// ## Coalescing
/// Each handler subscription has an independent debounce window (`debounceMs`).
/// The first reason opens a window; subsequent reasons within the window are
/// appended without rescheduling. When the window closes, a single
/// ``TriggerBatch`` is delivered.
///
/// ## Lane filtering
/// Handlers declare interest via a ``LaneSet``. A reason is only forwarded
/// to subscriptions whose interested lanes intersect the reason's
/// `affectedLanes`.
///
/// ## Heartbeat
/// Call ``setHeartbeat(quietSeconds:)`` to enable automatic `.heartbeat`
/// injection when no non-heartbeat reason has been posted for the configured
/// quiet interval.
@MainActor
public final class TriggerBus {

    // MARK: - Singleton

    public static let shared = TriggerBus()

    // MARK: - Types

    public typealias HandlerID = UUID
    public typealias Handler = @MainActor (TriggerBatch) async -> Void

    // MARK: - Private types

    private struct Subscription {
        let id: HandlerID
        let interestedLanes: LaneSet
        let debounceMs: Int
        let handler: Handler
        var pending: PendingBatch?
    }

    private struct PendingBatch {
        var reasons: [TriggerReason]
        var affectedLanes: LaneSet
        var firstSeen: Date
        var scheduledWorkItem: DispatchWorkItem?
    }

    // MARK: - State

    private var subscriptions: [HandlerID: Subscription] = [:]
    private var heartbeatQuietSeconds: TimeInterval = 2.0
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastNonHeartbeatPost: Date = Date()
    private var started = false

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Thread-safe: can be called from any queue or thread; hops to MainActor.
    public nonisolated func post(_ reason: TriggerReason) {
        Task { @MainActor in self.receive(reason) }
    }

    /// Internal test seam: callers already running on MainActor can inject a
    /// reason synchronously without a Task hop.
    ///
    /// Tests must themselves run on `@MainActor` (or call from
    /// `MainActor.assumeIsolated`). After calling this, issue
    /// `await Task.yield()` once (or use `XCTestExpectation` with a real
    /// debounce delay) to let the pending `DispatchWorkItem` fire.
    @_disfavoredOverload
    internal func _postForTest(_ reason: TriggerReason) {
        receive(reason)
    }

    /// Register a handler interested in a subset of lanes.
    ///
    /// - Parameters:
    ///   - lanes: The ``LaneSet`` this handler cares about. Reasons whose
    ///     `affectedLanes` are disjoint with `lanes` are silently dropped.
    ///   - debounceMs: Window in milliseconds during which arriving reasons
    ///     are merged into one batch. Defaults to 25 ms.
    ///   - handler: Called on MainActor with a coalesced ``TriggerBatch``.
    /// - Returns: An opaque ID that can be passed to ``unregister(_:)``.
    @discardableResult
    public func register(
        interested lanes: LaneSet,
        debounceMs: Int = 25,
        handler: @escaping Handler
    ) -> HandlerID {
        let id = HandlerID()
        subscriptions[id] = Subscription(
            id: id,
            interestedLanes: lanes,
            debounceMs: debounceMs,
            handler: handler
        )
        return id
    }

    /// Remove a previously registered handler.
    ///
    /// If a pending batch exists for this subscription it is discarded and the
    /// scheduled work item is cancelled — the handler will not be called.
    public func unregister(_ id: HandlerID) {
        if let sub = subscriptions[id] {
            sub.pending?.scheduledWorkItem?.cancel()
        }
        subscriptions.removeValue(forKey: id)
    }

    /// Configure the heartbeat quiet interval.
    ///
    /// If `started == true` the existing timer is replaced immediately. The new
    /// timer fires every `quietSeconds` and posts `.heartbeat(sinceLast:)` when
    /// no non-heartbeat reason has arrived in that window.
    ///
    /// Pass `0` or a negative value to disable the heartbeat.
    public func setHeartbeat(quietSeconds: TimeInterval) {
        heartbeatQuietSeconds = quietSeconds
        if started {
            installHeartbeatTimer()
        }
    }

    /// Start the bus.
    ///
    /// Idempotent: calling `start()` multiple times is safe. Installs the
    /// heartbeat timer if `heartbeatQuietSeconds > 0`.
    public func start() {
        guard !started else { return }
        started = true
        installHeartbeatTimer()
    }

    /// Stop the bus.
    ///
    /// Cancels the heartbeat timer and cancels + removes all subscriptions.
    public func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        for id in subscriptions.keys {
            subscriptions[id]?.pending?.scheduledWorkItem?.cancel()
        }
        subscriptions.removeAll()
        started = false
    }

    // MARK: - Internal

    private func receive(_ reason: TriggerReason) {
        if case .heartbeat = reason {
            // heartbeat does not reset the quiet clock
        } else {
            lastNonHeartbeatPost = Date()
        }

        for id in subscriptions.keys {
            guard let sub = subscriptions[id] else { continue }
            guard !sub.interestedLanes.isDisjoint(with: reason.affectedLanes) else { continue }

            if subscriptions[id]!.pending == nil {
                // Open a new window.
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    // hop back to MainActor — the DispatchWorkItem runs on
                    // main queue, but we need the actor isolation guarantee.
                    Task { @MainActor in self.fire(subscriptionID: id) }
                }
                let delayNs = UInt64(max(0, sub.debounceMs)) * 1_000_000
                subscriptions[id]!.pending = PendingBatch(
                    reasons: [reason],
                    affectedLanes: reason.affectedLanes,
                    firstSeen: Date(),
                    scheduledWorkItem: item
                )
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(sub.debounceMs),
                    execute: item
                )
                _ = delayNs  // suppress unused-variable warning
            } else {
                // Coalesce into the existing window — do NOT reschedule.
                subscriptions[id]!.pending!.reasons.append(reason)
                subscriptions[id]!.pending!.affectedLanes.formUnion(reason.affectedLanes)
            }
        }
    }

    private func scheduleDispatch(for subscriptionID: HandlerID) {
        // Kept for API consistency; logic is inlined in receive(_:).
    }

    private func fire(subscriptionID: HandlerID) {
        guard var sub = subscriptions[subscriptionID],
              let pending = sub.pending else { return }

        sub.pending = nil
        subscriptions[subscriptionID] = sub

        let urgency = pending.reasons.map(\.urgency).max() ?? 0
        let batch = TriggerBatch(
            reasons: pending.reasons,
            affectedLanes: pending.affectedLanes,
            firstSeen: pending.firstSeen,
            coalescedAt: Date(),
            urgency: urgency
        )

        let handler = sub.handler
        Task { @MainActor in
            await handler(batch)
        }
    }

    // MARK: - Heartbeat timer

    private func installHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        guard heartbeatQuietSeconds > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = heartbeatQuietSeconds
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let quietSeconds = self.heartbeatQuietSeconds
                let sincePost = Date().timeIntervalSince(self.lastNonHeartbeatPost)
                if sincePost >= quietSeconds {
                    self.receive(.heartbeat(sinceLast: sincePost))
                }
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }
}
