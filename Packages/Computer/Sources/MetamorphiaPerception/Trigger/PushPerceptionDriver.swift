import Foundation
import os.log

// MARK: - PerceptionCapturing

/// Minimal protocol for lane-partial capture, introduced for testability.
/// `PerceptionPipeline` conforms via a one-line extension below.
public protocol PerceptionCapturing: AnyObject, Sendable {
    func capture(lanes: LaneSet, base: ScreenMap?) async -> ScreenMap
}

// MARK: - SnapshotYielder

/// Minimal protocol for fan-out to subscriber continuations, introduced for testability.
/// `PerceptionLoop` conforms via an extension below.
public protocol SnapshotYielder: AnyObject, Sendable {
    /// Fan the snapshot out to all active subscribers.
    /// Implementations that are actors may perform the hop internally.
    func deliver(_ map: ScreenMap)
}

// MARK: - Conformances

extension PerceptionPipeline: PerceptionCapturing {}

extension PerceptionLoop: SnapshotYielder {
    /// `nonisolated` bridge: hops to the actor to call the `internal`
    /// `yieldSnapshot(_:)` method, satisfying `SnapshotYielder.deliver`.
    public nonisolated func deliver(_ map: ScreenMap) {
        Task { await self.yieldSnapshot(map) }
    }
}

// MARK: - PushPerceptionDriver

private let log = Logger(subsystem: "com.metamorphia.perception", category: "PushPerceptionDriver")

/// Subscribes to `TriggerBus`, invokes lane-partial `PerceptionPipeline.capture(lanes:base:)`,
/// and yields updated snapshots to `PerceptionLoop`'s continuations.
///
/// Lifecycle: call `start()` once to wire everything up and seed an initial snapshot.
/// Call `stop()` to unregister, restore the loop to pull mode, and drop retained state.
///
/// ## Thread model
/// The driver is `@MainActor`-isolated. Bus handlers run on MainActor (see `TriggerBus`).
/// All capture work hops to background executors inside `PerceptionPipeline`.
@MainActor
public final class PushPerceptionDriver {

    // MARK: - Singleton

    public static let shared = PushPerceptionDriver()

    // MARK: - Dependencies

    private let bus: TriggerBus
    private let pipeline: any PerceptionCapturing
    private let yielder: any SnapshotYielder
    /// Held separately so `stop()` can restore loop mode without polluting the `SnapshotYielder` protocol.
    private let loop: PerceptionLoop?

    // MARK: - State

    private var handlerID: TriggerBus.HandlerID?
    private var lastSnapshot: ScreenMap?
    private var started = false

    // MARK: - Init

    /// Designated initializer. Accepts a concrete `PerceptionLoop` for mode-switching.
    public init(
        bus: TriggerBus = .shared,
        pipeline: any PerceptionCapturing = PerceptionPipeline.shared,
        loop: PerceptionLoop = .shared
    ) {
        self.bus = bus
        self.pipeline = pipeline
        self.yielder = loop
        self.loop = loop
    }

    /// Test-seam initializer — injects a custom yielder that isn't a `PerceptionLoop`.
    /// Mode switching is skipped since test doubles typically don't need it.
    internal init(
        bus: TriggerBus,
        pipeline: any PerceptionCapturing,
        yielder: any SnapshotYielder
    ) {
        self.bus = bus
        self.pipeline = pipeline
        self.yielder = yielder
        self.loop = nil
    }

    // MARK: - Public API

    /// Wire up the driver. Idempotent — calling twice registers only one handler.
    public func start() {
        guard !started else { return }

        // Switch loop into push mode so the tick becomes a heartbeat only.
        if let loop {
            Task { await loop.setMode(.push) }
        }

        // Ensure the bus is running.
        bus.start()

        // Register for all lanes with a 25 ms debounce window.
        handlerID = bus.register(interested: .all, debounceMs: 25) { [weak self] batch in
            await self?.onBatch(batch)
        }

        // Seed an initial full snapshot so `lastSnapshot` is populated before
        // the first incremental trigger arrives. Uses the injected pipeline so
        // test doubles don't reach into the real PerceptionPipeline.
        Task { [weak self] in
            guard let self else { return }
            let map = await self.pipeline.capture(lanes: .all, base: nil)
            self.lastSnapshot = map
            self.yielder.deliver(map)
        }

        started = true
    }

    /// Unregister the bus handler and restore the loop to pull mode.
    public func stop() {
        if let id = handlerID {
            bus.unregister(id)
            handlerID = nil
        }
        if let loop {
            Task { await loop.setMode(.pull) }
        }
        lastSnapshot = nil
        started = false
    }

    // MARK: - Private

    private func onBatch(_ batch: TriggerBatch) async {
        await runCapture(lanes: batch.affectedLanes)
    }

    private func runCapture(lanes: LaneSet) async {
        // `capture(lanes:base:)` is non-throwing; any Task-cancellation propagation
        // is silently swallowed so it never surfaces through the bus handler.
        let map = await pipeline.capture(lanes: lanes, base: lastSnapshot)
        lastSnapshot = map
        yielder.deliver(map)
    }
}
