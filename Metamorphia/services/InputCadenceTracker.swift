/*
 * InputCadenceTracker
 *
 * PRIVACY INVARIANTS — read before modifying:
 *
 * This file installs a listen-only CGEventTap that observes keyDown, leftMouseDown,
 * and rightMouseDown events system-wide. It reads NOTHING from any event — not the
 * keycode, not the character, not the target process. The sole action taken in the
 * callback is incrementing an Int counter stored in a stack-local UnsafeMutablePointer.
 *
 * Only the running count is kept, in RAM, as six 10-second buckets. Nothing is
 * written to disk. Nothing enters ActivityStream or any other observable channel.
 * The published `tier` and `eventsPerMinute` properties are the entire public
 * surface — they convey intensity, never content.
 *
 * The testPayloadsAreRedacted invariant in ActivityJournalTests.swift is unaffected:
 * this tracker is orthogonal to the activity journal and never touches it.
 */

import CoreGraphics
import Defaults
import Foundation

// MARK: - Defaults key

extension Defaults.Keys {
    /// When false, InputCadenceTracker.start() is a no-op. Default: true.
    /// Toggling to false while running tears down the tap immediately.
    static let observeInputCadence = Key<Bool>(
        "metamorphia.sensor.inputCadence.enabled",
        default: true
    )
}

// MARK: - Tier

/// Coarse classification of how actively the user is typing or clicking.
///
/// Thresholds (tunable, currently hardcoded):
///   - `.idle`:  < 20 events/min  — user is largely inactive
///   - `.light`: 20–119 events/min — moderate interaction
///   - `.heavy`: ≥ 120 events/min  — sustained typing / rapid interaction
///
/// For reference, a 60 WPM typist produces roughly 300 events/min when counting
/// keystrokes together with modifier keys.
public enum InputCadenceTier: String, Sendable {
    case idle
    case light
    case heavy
}

// MARK: - InputCadenceTracker

/// Observes raw input event counts and derives a smoothed `InputCadenceTier`.
///
/// Counting is done inside a passive (listenOnly) CGEventTap — it reads no event
/// fields and never modifies or swallows events. The count is smoothed over six
/// 10-second buckets (a 60-second rolling window) and published every 10 seconds.
@MainActor
public final class InputCadenceTracker: ObservableObject {

    // MARK: - Public API

    public static let shared = InputCadenceTracker()

    /// Current smoothed cadence tier. Updated every 10 seconds.
    @Published public private(set) var tier: InputCadenceTier = .idle

    /// Smoothed events per minute — useful for debugging or a Settings surface.
    /// Updated every 10 seconds alongside `tier`.
    @Published public private(set) var eventsPerMinute: Int = 0

    // MARK: - Tap state (not actor-isolated — touched only in start/stop on MainActor)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var running = false

    /// Set to true the first time CGEventTapCreate returns nil (AX permission denied).
    /// Once latched, all future start() calls short-circuit — no further tap attempts
    /// are made until the app is relaunched after the user grants Accessibility access.
    private var permissionDenied = false

    // MARK: - Counter (shared between callback thread and MainActor drain)

    /// Atomic counter incremented by the CGEventTap callback (any thread).
    /// Drained on the main actor every bucket tick.
    private let counter = AtomicCounter()

    // MARK: - Circular bucket buffer

    /// Six 10-second buckets; newest is `buckets[head]`, oldest wraps around.
    private var buckets: [Int] = Array(repeating: 0, count: 6)
    private var head: Int = 0

    // MARK: - Timer

    private var bucketTimer: Timer?

    // MARK: - Init

    private init() {}

    // MARK: - Lifecycle

    public func start() {
        guard !permissionDenied else { return }
        guard Defaults[.observeInputCadence] else { return }
        guard !running else { return }

        installTap()
        startBucketTimer()
        running = true
    }

    public func stop() {
        guard running else { return }
        running = false
        tearDownTap()
        bucketTimer?.invalidate()
        bucketTimer = nil
    }

    // MARK: - Internal hook for tests

    /// Directly records `count` events into the current bucket.
    /// Exposed `internal` so unit tests can simulate input bursts without
    /// injecting real HID events.
    func record(_ count: Int = 1) {
        counter.add(count)
    }

    // MARK: - Tap installation

    private func installTap() {
        // Mask: keyDown + leftMouseDown + rightMouseDown
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        // The callback is a plain C function; it captures `self` via userInfo.
        let callback: CGEventTapCallBack = { _, _, event, userInfo in
            // Read nothing from the event — increment only.
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<InputCadenceTracker>.fromOpaque(userInfo)
                .takeUnretainedValue()
            tracker.counter.increment()
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(
                Unmanaged.passUnretained(self).toOpaque()
            )
        ) else {
            // Nil tap — AX permission absent. Latch the denied state so no future
            // start() call re-attempts tapCreate or re-logs the warning. The user
            // must grant Accessibility access and relaunch the app.
            print("[InputCadenceTracker] CGEventTapCreate returned nil — Accessibility permission required. Cadence will remain .idle.")
            permissionDenied = true
            tier = .idle
            eventsPerMinute = 0
            running = true   // satisfies guard !running so stop()/start() cycles don't retry
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    private func tearDownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Bucket timer

    private func startBucketTimer() {
        bucketTimer = Timer.scheduledTimer(
            withTimeInterval: 10,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainBucket()
            }
        }
    }

    /// Drain the atomic counter into the current bucket, advance the ring, and
    /// recompute `eventsPerMinute` + `tier`.
    private func drainBucket() {
        // Feature-gate check on each tick so a live toggle takes effect promptly.
        guard Defaults[.observeInputCadence] else {
            buckets = Array(repeating: 0, count: 6)
            eventsPerMinute = 0
            tier = .idle
            return
        }

        // Swap counter → bucket
        let count = counter.swapToZero()
        buckets[head] = count
        head = (head + 1) % 6

        // Sum all six buckets (60 s) — that IS the events-per-minute value.
        let total = buckets.reduce(0, +)
        eventsPerMinute = total
        tier = InputCadenceTier(eventsPerMinute: total)
    }
}

// MARK: - Tier derivation

private extension InputCadenceTier {
    init(eventsPerMinute: Int) {
        switch eventsPerMinute {
        case ..<20:       self = .idle
        case 20..<120:    self = .light
        default:          self = .heavy
        }
    }
}

// MARK: - AtomicCounter

/// Minimal thread-safe counter backed by a lock + Int.
/// Using a simple `os_unfair_lock` wrapper keeps the dependency surface minimal
/// and avoids importing Atomics or Swift Concurrency overhead in a hot path.
private final class AtomicCounter: @unchecked Sendable {
    private var value: Int = 0
    private var lock = os_unfair_lock()

    func increment() {
        os_unfair_lock_lock(&lock)
        value &+= 1
        os_unfair_lock_unlock(&lock)
    }

    func add(_ n: Int) {
        os_unfair_lock_lock(&lock)
        value &+= n
        os_unfair_lock_unlock(&lock)
    }

    /// Atomically read and reset to zero.
    func swapToZero() -> Int {
        os_unfair_lock_lock(&lock)
        let v = value
        value = 0
        os_unfair_lock_unlock(&lock)
        return v
    }
}
