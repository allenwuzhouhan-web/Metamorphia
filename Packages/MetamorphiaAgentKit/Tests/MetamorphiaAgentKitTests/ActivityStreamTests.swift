import XCTest
import Combine
@testable import MetamorphiaAgentKit

final class ActivityStreamTests: XCTestCase {

    // MARK: - Helpers

    /// Convenience factory. Using unique stream instances per test avoids shared
    /// state from `ActivityStream.shared`.
    private func makeStream(gate: any ActivityStreamGate = AlwaysOnGate()) -> ActivityStream {
        ActivityStream(gate: gate)
    }

    /// A deterministic base date so tests are reproducible independent of wall clock.
    private let base = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func focusEvent(offset seconds: TimeInterval = 0, pid: Int32 = 1) -> ActivityEvent {
        .focusChanged(
            bundleID: "com.example.app",
            appName: "Example",
            windowTitle: nil,
            pid: pid,
            at: base.addingTimeInterval(seconds)
        )
    }

    // MARK: - testEmitAppendsToBuffer

    func testEmitAppendsToBuffer() async {
        let stream = makeStream()
        let e1 = focusEvent(offset: 0, pid: 1)
        let e2 = focusEvent(offset: 1, pid: 2)
        let e3 = focusEvent(offset: 2, pid: 3)

        await stream.emit(e1)
        await stream.emit(e2)
        await stream.emit(e3)

        let snap = await stream.snapshot()
        XCTAssertEqual(snap.count, 3)
        XCTAssertEqual(snap[0], e1)
        XCTAssertEqual(snap[1], e2)
        XCTAssertEqual(snap[2], e3)
    }

    // MARK: - testRingBufferDropsOldest

    func testRingBufferDropsOldest() async {
        let stream = makeStream()
        let total = ActivityStream.ringCapacity + 10

        for i in 0 ..< total {
            await stream.emit(focusEvent(offset: TimeInterval(i), pid: Int32(i)))
        }

        let snap = await stream.snapshot()
        XCTAssertEqual(snap.count, ActivityStream.ringCapacity, "Ring must be capped at capacity")

        // The first 10 (oldest) should have been dropped; the 11th survives.
        if case .focusChanged(_, _, _, let pid, _) = snap.first {
            XCTAssertEqual(pid, 10, "Oldest 10 must be dropped; first survivor is pid 10")
        } else {
            XCTFail("Unexpected event kind at index 0")
        }
    }

    // MARK: - testRecentSinceFiltersCorrectly

    func testRecentSinceFiltersCorrectly() async {
        let stream = makeStream()
        // Emit 5 events separated by 60 seconds each.
        for i in 0 ..< 5 {
            await stream.emit(focusEvent(offset: TimeInterval(i) * 60, pid: Int32(i)))
        }

        // Ask for events from the 3rd event (offset 120 s) onwards → should return events 2,3,4.
        let cutoff = base.addingTimeInterval(120)
        let result = await stream.recent(since: cutoff)

        XCTAssertEqual(result.count, 3)
        for event in result {
            XCTAssertGreaterThanOrEqual(event.timestamp, cutoff)
        }
        // Oldest-first ordering.
        for i in 1 ..< result.count {
            XCTAssertLessThanOrEqual(result[i - 1].timestamp, result[i].timestamp)
        }
    }

    // MARK: - testPublisherReceivesEvents

    func testPublisherReceivesEvents() async {
        let stream = makeStream()
        var received: [ActivityEvent] = []
        var cancellables = Set<AnyCancellable>()
        let expectation = expectation(description: "Publisher delivers 2 events")
        expectation.expectedFulfillmentCount = 2

        stream.events
            .sink { event in
                received.append(event)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let e1 = focusEvent(offset: 0, pid: 1)
        let e2 = focusEvent(offset: 1, pid: 2)
        await stream.emit(e1)
        await stream.emit(e2)

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0], e1)
        XCTAssertEqual(received[1], e2)
    }

    // MARK: - testDisabledGateIsNoOp

    func testDisabledGateIsNoOp() async {
        let stream = makeStream(gate: NeverOnGate())
        await stream.emit(focusEvent())
        await stream.emit(focusEvent(offset: 1))

        let snap = await stream.snapshot()
        XCTAssertTrue(snap.isEmpty, "Disabled gate must prevent all appends")
    }

    // MARK: - testWriterHookFires

    func testWriterHookFires() async {
        let stream = makeStream()

        // Use a lock-protected box so the @Sendable writer closure can mutate
        // `observed` safely from the actor's executor while we read it below.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _events: [ActivityEvent] = []
            func append(_ e: ActivityEvent) { lock.withLock { _events.append(e) } }
            var events: [ActivityEvent] { lock.withLock { _events } }
        }
        let box = Box()

        // Call the actor-isolated _attachWriter directly so the writer is
        // guaranteed to be installed before the first emit (no unstructured
        // Task ordering ambiguity).
        await stream._attachWriter { event in
            box.append(event)
        }

        let e1 = focusEvent(offset: 0, pid: 1)
        let e2 = focusEvent(offset: 1, pid: 2)
        let e3 = focusEvent(offset: 2, pid: 3)
        await stream.emit(e1)
        await stream.emit(e2)
        await stream.emit(e3)

        let observed = box.events
        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed[0], e1)
        XCTAssertEqual(observed[1], e2)
        XCTAssertEqual(observed[2], e3)
    }

    // MARK: - testExhaustiveSourceMapping

    /// Smoke test: every concrete ``ActivityEvent`` case must return a non-crashing
    /// `source`. The real correctness guarantee is the exhaustive switch in
    /// `ActivityEvent.source` — the compiler enforces it; this test documents intent.
    func testExhaustiveSourceMapping() {
        let sampleEvents: [ActivityEvent] = [
            .focusChanged(bundleID: "a", appName: "A", windowTitle: nil, pid: 1, at: base),
            .inputIdle(idleSeconds: 30, at: base),
            .inputResumed(afterIdleSeconds: 30, at: base),
            .urlVisited(urlHash: "abc", host: "example.com", title: nil, browserBundleID: "com.apple.safari", at: base),
            .meetingStarted(app: "Zoom", at: base),
            .meetingEnded(durationSeconds: 3600, at: base),
            .placeChanged(placeHash: "xyz", label: "Home", at: base),
            .cameraToggled(isActive: true, at: base),
            .microphoneToggled(isActive: false, at: base),
            .focusModeChanged(mode: "Work", at: base),
            .clipboardCopied(kind: .text, byteCount: 42, origin: .local, at: base),
            .querySubmitted(queryID: UUID(), entityCount: 3, at: base),
            .surfaceEngaged(surface: "notch", action: .engaged, durationMs: 500, at: base),
            .sessionClosed(bundleID: "com.example.app", docHint: nil, durationSeconds: 120, cadenceTier: .light, at: base),
        ]

        for event in sampleEvents {
            // Simply accessing `.source` must not crash; the value is non-nil by type.
            let source = event.source
            XCTAssertTrue(ActivitySource.allCases.contains(source),
                          "source \(source) must be a known ActivitySource case")
        }
    }
}
