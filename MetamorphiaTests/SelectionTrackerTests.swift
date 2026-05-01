/*
 * SelectionTrackerTests
 *
 * NOTE: This file requires a macOS XCTest target that imports Metamorphia's
 * application sources (e.g. a MetamorphiaTests target in Metamorphia.xcodeproj).
 * No such target exists yet — wire it up alongside MetamorphiaPerception when
 * Wave 10 adds AXFixtureApp support.
 *
 * Tests that exercise readSelectionLength directly require a live AX target
 * process and are flagged below as "requires AXFixtureApp from Wave 10".
 * The tests here focus on lifecycle behaviour that is fully verifiable without
 * real AX infrastructure.
 */

import XCTest
import Defaults
@testable import Metamorphia   // adjust module name once a test target is wired

@MainActor
final class SelectionTrackerTests: XCTestCase {

    // MARK: - Setup / teardown

    private var stream: ActivityStream!
    private var bus: TriggerBus!
    private var pool: AXObserverPool!
    private var tracker: SelectionTracker!

    override func setUp() async throws {
        stream  = ActivityStream()
        bus     = TriggerBus()
        pool    = AXObserverPool()
        Defaults[.observeSelection] = true
        tracker = SelectionTracker(stream: stream, bus: bus, observerPool: pool)
    }

    override func tearDown() async throws {
        tracker.stop()
        Defaults[.observeSelection] = false
    }

    // MARK: - testStartRegistersHandler

    /// start() must register a handler on the bus (handlerID becomes non-nil).
    func testStartRegistersHandler() throws {
        // Verify via the test seam on SelectionTracker that the handlerID is set.
        tracker.start()
        XCTAssertNotNil(tracker._handlerIDForTest,
                        "start() must register a handler and store its ID")
    }

    // MARK: - testStartIsIdempotent

    /// Calling start() twice must not register a second handler — the same
    /// handlerID is retained after the second call.
    func testStartIsIdempotent() throws {
        tracker.start()
        let firstID = tracker._handlerIDForTest
        XCTAssertNotNil(firstID)

        tracker.start()
        let secondID = tracker._handlerIDForTest
        XCTAssertEqual(firstID, secondID,
                       "Second start() must not replace the existing handler registration")
    }

    // MARK: - testStopClearsHandler

    /// After stop(), handlerID is nil (handler unregistered from bus).
    func testStopClearsHandler() throws {
        tracker.start()
        XCTAssertNotNil(tracker._handlerIDForTest)

        tracker.stop()
        XCTAssertNil(tracker._handlerIDForTest,
                     "stop() must unregister the handler and nil the stored ID")
    }

    // MARK: - testStopIsIdempotent

    /// Calling stop() on a never-started or already-stopped tracker must not crash.
    func testStopIsIdempotent() throws {
        // Never started.
        XCTAssertNoThrow(tracker.stop())

        // Start → stop → stop again.
        tracker.start()
        tracker.stop()
        XCTAssertNoThrow(tracker.stop())
    }

    // MARK: - testFeatureGateBlocksEmission

    /// When observeSelection is false, onTrigger must not emit any events.
    func testFeatureGateBlocksEmission() async throws {
        Defaults[.observeSelection] = false

        var received: [ActivityEvent] = []
        let sub = stream.publisher.sink { received.append($0) }
        defer { sub.cancel() }

        tracker.start()

        // Post an axSelectedTextChanged reason. Pid 0 will produce no AX result,
        // but the feature-gate check fires before any AX read.
        bus._postForTest(.axSelectedTextChanged(pid: 0))

        // Allow the 300 ms debounce window + async task hops to settle.
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(received.isEmpty,
                      "No events should be emitted when observeSelection is false")
    }

    // MARK: - testEmitNotCalledWhenNotRunning

    /// Events posted after stop() are silently ignored.
    func testEmitNotCalledWhenNotRunning() async throws {
        var received: [ActivityEvent] = []
        let sub = stream.publisher.sink { received.append($0) }
        defer { sub.cancel() }

        tracker.start()
        tracker.stop()

        bus._postForTest(.axSelectedTextChanged(pid: 0))
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(received.isEmpty,
                      "No events should be emitted after stop()")
    }

    // MARK: - Stubs for AXFixtureApp tests (Wave 10)
    //
    // The following tests require an AXFixtureApp process that posts
    // kAXSelectedTextChangedNotification with known selection lengths.
    // Enable them in Wave 10.
    //
    // func testReadSelectionLength_returnsLengthOnly() { /* Wave 10 */ }
    // func testReadSelectionLength_doesNotReadContent() { /* Wave 10 */ }
    // func testReadSelectionLength_handlesWedgedPid() { /* Wave 10 */ }
    // func testEmitSkipsZeroLengthSelection() { /* Wave 10 */ }
    // func testEmitSkipsSuspiciouslyLargeLength() { /* Wave 10 */ }
}
