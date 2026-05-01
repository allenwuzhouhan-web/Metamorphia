/*
 * InputCadenceTrackerTests
 *
 * NOTE: This file requires a macOS XCTest target that includes Metamorphia's
 * application sources (or a framework slice of them). No such target exists yet
 * in Metamorphia.xcodeproj — wire it up when WS-7 (SessionSegmenter) adds a
 * test target, or add a standalone MetamorphiaTests target to the project.
 *
 * The tests here use the internal `record(_:)` hook on InputCadenceTracker to
 * simulate input bursts without injecting real HID events, which avoids the need
 * for Accessibility permission in CI.
 */

import XCTest
import Defaults
@testable import Metamorphia   // adjust module name once a test target exists

@MainActor
final class InputCadenceTrackerTests: XCTestCase {

    // Reset shared state between tests.
    override func setUp() async throws {
        await InputCadenceTracker.shared.stop()
        // Reset the feature gate to its default each run.
        Defaults[.observeInputCadence] = true
    }

    override func tearDown() async throws {
        await InputCadenceTracker.shared.stop()
        Defaults[.observeInputCadence] = true
    }

    // MARK: - testIdleTierWhenNoEvents

    /// Start the tracker, inject no events, wait for the smoothing window (15 s
    /// covers one full bucket tick at the 10 s boundary), and confirm the tier
    /// stays `.idle`.
    func testIdleTierWhenNoEvents() async throws {
        await InputCadenceTracker.shared.start()
        try await Task.sleep(for: .seconds(15))
        let t = await InputCadenceTracker.shared.tier
        XCTAssertEqual(t, .idle, "Expected .idle with zero events recorded")
    }

    // MARK: - testTiersTransitionOnInjectedBursts

    /// Inject enough events per bucket to push eventsPerMinute above the .heavy
    /// threshold (≥ 120), wait for at least one smoothing tick, then assert .heavy.
    ///
    /// We inject 25 events/second × 10 s = 250 events per bucket.
    /// Sum of 6 buckets after filling = 1 500 events/min → well above 120.
    func testTiersTransitionOnInjectedBursts() async throws {
        let tracker = InputCadenceTracker.shared
        await tracker.start()

        // Inject a burst synchronously into the counter before the first bucket drains.
        // We need to fill multiple buckets to see the rolling average climb.
        // Inject 200 events — after a single 10 s tick, that one bucket gives
        // eventsPerMinute = 200 (the other five are 0), which is ≥ 120.
        for _ in 0 ..< 200 {
            await tracker.record()
        }

        // Wait for the bucket timer to fire (10 s bucket + small margin).
        try await Task.sleep(for: .seconds(11))

        let epm = await tracker.eventsPerMinute
        let t   = await tracker.tier

        XCTAssertGreaterThanOrEqual(epm, 120, "Expected eventsPerMinute ≥ 120, got \(epm)")
        XCTAssertEqual(t, .heavy, "Expected .heavy tier with \(epm) events/min")
    }

    // MARK: - testGateOffIsNoOp

    /// When the feature gate is disabled, start() must be a no-op and
    /// eventsPerMinute must remain 0.
    func testGateOffIsNoOp() async throws {
        Defaults[.observeInputCadence] = false
        let tracker = InputCadenceTracker.shared
        await tracker.start()

        // Even if we call record(), the bucket timer was never started,
        // so the counter should never be drained into eventsPerMinute.
        await tracker.record(500)

        // A brief sleep is sufficient — no timer running means no drain happens.
        try await Task.sleep(for: .seconds(1))

        let epm = await tracker.eventsPerMinute
        XCTAssertEqual(epm, 0, "Expected eventsPerMinute == 0 when gate is off, got \(epm)")
    }
}
