import Foundation
import Combine

// MARK: - ActivityStreamGate

/// Controls whether ``ActivityStream`` accepts new events.
///
/// The default implementation (``AlwaysOnGate``) passes every event through.
/// Tests inject ``NeverOnGate`` to verify the kill-switch path. Production code
/// will wire a concrete gate backed by `Defaults[.activityStreamEnabled]` in the
/// host-app target without touching this file.
public protocol ActivityStreamGate: Sendable {
    var isEnabled: Bool { get }
}

/// Gate that always allows events through. Used as the production default until
/// the host app wires a real Defaults-backed gate.
public struct AlwaysOnGate: ActivityStreamGate, Sendable {
    public init() {}
    public var isEnabled: Bool { true }
}

/// Gate that always blocks events. Useful in tests.
public struct NeverOnGate: ActivityStreamGate, Sendable {
    public init() {}
    public var isEnabled: Bool { false }
}

// MARK: - ActivityStream

/// In-memory ring buffer and Combine publisher for ``ActivityEvent`` values.
///
/// ## Architecture
/// `ActivityStream` is a Swift actor; all state mutations are actor-isolated and
/// therefore thread-safe without any manual locking.
///
/// ## Back-pressure
/// The internal `PassthroughSubject` drops events on the floor for subscribers
/// that cannot keep up. This is intentional: the ring buffer provides the
/// authoritative ordered history; the publisher is a convenience for real-time
/// reactive updates. Slow subscribers should use ``snapshot()`` or
/// ``recent(since:)`` on a timer rather than relying on the publisher.
///
/// ## Writer hook
/// Only one writer at a time is supported via ``attachWriter(_:)``. A second call
/// replaces the first. The writer is called synchronously on the actor's executor
/// after every successful append, so it must not block.
///
/// ## Kill-switch
/// If the injected ``ActivityStreamGate`` returns `isEnabled == false`, ``emit(_:)``
/// is a complete no-op — the ring buffer is not modified and the publisher does
/// not fire.
public actor ActivityStream {

    // MARK: - Singleton

    /// Shared instance backed by ``AlwaysOnGate``. Feature flag wiring replaces
    /// the gate at startup in the host app.
    public static let shared = ActivityStream()

    // MARK: - Constants

    /// Maximum number of events kept in memory. When this limit is reached the
    /// oldest event is dropped on every new append (drop-oldest policy).
    public static let ringCapacity = 10_000

    // MARK: - State

    // Fixed-capacity circular buffer. `storage` is grown lazily up to
    // ``ringCapacity`` slots; once full, `head` advances and the slot it points
    // at is overwritten in place. This makes drop-oldest O(1) per append instead
    // of the O(n) element shift an `Array.removeFirst()` would incur on a full
    // 10k-element buffer. `snapshot()`/`recent(since:)` reconstruct the
    // oldest-first ordering from `head`, so external read behavior is unchanged.
    private var storage: [ActivityEvent] = []
    /// Index of the oldest event once `storage` has reached capacity.
    private var head = 0
    private var writer: (@Sendable (ActivityEvent) -> Void)?
    private let gate: any ActivityStreamGate

    // MARK: - Combine subject

    // The subject is a reference type stored as a constant so it can be exposed
    // via a `nonisolated` property without violating actor isolation rules.
    // `PassthroughSubject` is thread-safe; `nonisolated` on the property lets
    // the Swift 6 checker see that reads don't cross the actor boundary.
    nonisolated private let subject = PassthroughSubject<ActivityEvent, Never>()

    // MARK: - Init

    public init(gate: any ActivityStreamGate = AlwaysOnGate()) {
        self.gate = gate
    }

    // MARK: - Public API

    /// Append `event` to the ring buffer and forward it to all subscribers.
    ///
    /// No-op if the gate is disabled. Drop-oldest when the ring is at capacity.
    public func emit(_ event: ActivityEvent) {
        guard gate.isEnabled else { return }

        if storage.count < ActivityStream.ringCapacity {
            // Still filling: append in order, `head` stays at 0.
            storage.append(event)
        } else {
            // Full: overwrite the oldest slot in place and advance `head`.
            storage[head] = event
            head = (head + 1) % ActivityStream.ringCapacity
        }

        subject.send(event)
        writer?(event)
    }

    /// All events currently in the ring buffer, oldest first.
    ///
    /// Used by ``ActivityJournal`` for startup backfill.
    public func snapshot() -> [ActivityEvent] {
        orderedEvents()
    }

    /// Events whose timestamp is on or after `since`, oldest first.
    public func recent(since: Date) -> [ActivityEvent] {
        orderedEvents().filter { $0.timestamp >= since }
    }

    /// Attach a writer that is called synchronously after every successful
    /// ``emit(_:)``. Only one writer is active at a time — a second call replaces
    /// the first without error.
    ///
    /// Intended for use by `ActivityJournal` to persist events as they arrive.
    /// The closure must not block or call back into the actor.
    public nonisolated func attachWriter(_ writer: @Sendable @escaping (ActivityEvent) -> Void) {
        Task { await self._attachWriter(writer) }
    }

    // MARK: - Combine publisher

    /// Hot publisher of ``ActivityEvent`` values. Backed by a `PassthroughSubject`;
    /// no replay — late subscribers miss prior events. Use ``snapshot()`` or
    /// ``recent(since:)`` for historical access.
    ///
    /// `nonisolated` so Combine chains can be assembled from any context without
    /// an `await`.
    public nonisolated var events: AnyPublisher<ActivityEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    // MARK: - Internal helpers

    /// Events in oldest-first order, reconstructed from the circular `storage`.
    ///
    /// While the buffer is still filling, `head == 0` and this is just `storage`.
    /// Once full, the oldest event lives at `head`, so the logical order is the
    /// slice from `head` to the end followed by the slice from the start to
    /// `head`.
    private func orderedEvents() -> [ActivityEvent] {
        guard head != 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    /// Actor-isolated writer installation. Exposed `internal` so tests can
    /// `await` it directly to guarantee the writer is installed before emitting.
    func _attachWriter(_ writer: @Sendable @escaping (ActivityEvent) -> Void) {
        self.writer = writer
    }
}

// MARK: - ActivityStreamWritable conformance

extension ActivityStream: ActivityStreamWritable {}
