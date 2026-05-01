import XCTest
import Combine
@testable import MetamorphiaAgentKit

// MARK: - SessionCollector

/// Thread-safe collector of `.sessionClosed` events emitted into a stream.
private final class SessionCollector: @unchecked Sendable {
    private var _sessions: [ActivityEvent] = []
    private let lock = NSLock()
    private var subscription: AnyCancellable?

    var sessions: [ActivityEvent] {
        lock.withLock { _sessions }
    }

    func attach(to stream: ActivityStream) {
        subscription = stream.events.sink { [weak self] event in
            guard let self, case .sessionClosed = event else { return }
            self.lock.withLock { self._sessions.append(event) }
        }
    }
}

// MARK: - Helpers

/// Polls `condition` every `interval` until it returns true or `timeout` elapses.
private func waitUntil(
    timeout: TimeInterval = 3,
    interval: TimeInterval = 0.05,
    condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

// MARK: - SessionSegmenterTests

final class SessionSegmenterTests: XCTestCase {

    // A very short flicker window so tests run in milliseconds rather than 30 s.
    private let testFlicker: TimeInterval = 0.1

    private func makeStream() -> ActivityStream {
        ActivityStream(gate: AlwaysOnGate())
    }

    /// Emit `.focusChanged` and wait briefly so the segmenter's actor can process it.
    private func focus(
        _ bundleID: String,
        appName: String = "App",
        title: String? = nil,
        at: Date,
        into stream: ActivityStream
    ) async {
        await stream.emit(.focusChanged(
            bundleID: bundleID,
            appName: appName,
            windowTitle: title,
            pid: 1,
            at: at
        ))
        // Sleep long enough for the segmenter's internal Task to be scheduled
        // and complete on the actor's executor.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
    }

    private func makeSeg(stream: ActivityStream, cadence: @escaping SessionSegmenter.CadenceProvider) -> SessionSegmenter {
        SessionSegmenter(stream: stream, cadenceProvider: cadence, flickerWindowSeconds: testFlicker)
    }

    // MARK: - 1. Short session discarded

    func testShortSessionDiscarded() async throws {
        let stream = makeStream()
        let collector = SessionCollector()
        collector.attach(to: stream)

        let seg = makeSeg(stream: stream, cadence: { .light })
        await seg.start()
        defer { Task { await seg.stop() } }

        let t0 = Date()
        await focus("com.app.A", at: t0, into: stream)
        // 10 s of simulated time — below the 120 s minimum.
        await focus("com.app.B", at: t0.addingTimeInterval(10), into: stream)

        // Wait past the flicker window so any pending close fires.
        try await Task.sleep(nanoseconds: UInt64((testFlicker + 0.3) * 1_000_000_000))
        await waitUntil { collector.sessions.count >= 1 }

        XCTAssertTrue(collector.sessions.isEmpty,
                      "Short session must be discarded; got \(collector.sessions.count) event(s)")
    }

    // MARK: - 2. Long session emits

    func testLongSessionEmits() async throws {
        let stream = makeStream()
        let collector = SessionCollector()
        collector.attach(to: stream)

        let seg = makeSeg(stream: stream, cadence: { .light })
        await seg.start()
        defer { Task { await seg.stop() } }

        let t0 = Date()
        await focus("com.app.A", at: t0, into: stream)
        // Simulated 150 s of work in app A.
        await focus("com.app.B", at: t0.addingTimeInterval(150), into: stream)

        // Wait past the flicker window.
        try await Task.sleep(nanoseconds: UInt64((testFlicker + 0.3) * 1_000_000_000))
        await waitUntil { collector.sessions.count >= 1 }

        XCTAssertEqual(collector.sessions.count, 1,
                       "Expected exactly one sessionClosed event; got \(collector.sessions.count)")
        guard case let .sessionClosed(bundleID, _, durationSeconds, _, _) = collector.sessions.first else {
            return XCTFail("Expected .sessionClosed")
        }
        XCTAssertEqual(bundleID, "com.app.A")
        XCTAssertEqual(durationSeconds, 150, accuracy: 2)
    }

    // MARK: - 3. URL window title redacted

    func testDocHintRedactsURLLooking() async throws {
        let stream = makeStream()
        let collector = SessionCollector()
        collector.attach(to: stream)

        let seg = makeSeg(stream: stream, cadence: { .light })
        await seg.start()
        defer { Task { await seg.stop() } }

        let t0 = Date()
        await focus("com.app.A", title: "https://example.com/page", at: t0, into: stream)
        await focus("com.app.B", at: t0.addingTimeInterval(200), into: stream)

        try await Task.sleep(nanoseconds: UInt64((testFlicker + 0.3) * 1_000_000_000))
        await waitUntil { collector.sessions.count >= 1 }

        XCTAssertEqual(collector.sessions.count, 1)
        guard case let .sessionClosed(_, docHint, _, _, _) = collector.sessions.first else {
            return XCTFail("Expected .sessionClosed")
        }
        XCTAssertNil(docHint, "URL titles must produce nil docHint")
    }

    // MARK: - 4. Password title redacted

    func testPasswordTitleRedacted() async throws {
        let stream = makeStream()
        let collector = SessionCollector()
        collector.attach(to: stream)

        let seg = makeSeg(stream: stream, cadence: { .light })
        await seg.start()
        defer { Task { await seg.stop() } }

        let t0 = Date()
        await focus("com.app.A", title: "Enter Password — MyApp", at: t0, into: stream)
        await focus("com.app.B", at: t0.addingTimeInterval(200), into: stream)

        try await Task.sleep(nanoseconds: UInt64((testFlicker + 0.3) * 1_000_000_000))
        await waitUntil { collector.sessions.count >= 1 }

        XCTAssertEqual(collector.sessions.count, 1)
        guard case let .sessionClosed(_, docHint, _, _, _) = collector.sessions.first else {
            return XCTFail("Expected .sessionClosed")
        }
        XCTAssertNil(docHint, "Password titles must produce nil docHint")
    }

    // MARK: - 5. Cmd-tab flicker stays in session

    func testCmdTabFlickerStaysInSession() async throws {
        let stream = makeStream()
        let collector = SessionCollector()
        collector.attach(to: stream)

        // Use a slightly longer flicker window (0.5 s) so we can reliably
        // return to A within it before the Task fires.
        let flickerWindow: TimeInterval = 0.5
        let seg = SessionSegmenter(stream: stream, cadenceProvider: { .light }, flickerWindowSeconds: flickerWindow)
        await seg.start()
        defer { Task { await seg.stop() } }

        let t0 = Date()

        // Focus A for 150 s (simulated).
        await focus("com.app.A", at: t0, into: stream)

        // Flip to B — starts the flicker-window countdown.
        let tFlipToB = t0.addingTimeInterval(150)
        await focus("com.app.B", at: tFlipToB, into: stream)

        // Return to A within the flicker window (real-time: < 0.5 s).
        let tReturnToA = tFlipToB.addingTimeInterval(15)   // simulated +15 s
        await focus("com.app.A", at: tReturnToA, into: stream)

        // Stay in A for 60 more simulated seconds, then go to C.
        let tFlipToC = tReturnToA.addingTimeInterval(60)
        await focus("com.app.C", at: tFlipToC, into: stream)

        // Wait past the flicker window so A's staged close fires.
        try await Task.sleep(nanoseconds: UInt64((flickerWindow + 0.3) * 1_000_000_000))
        await waitUntil { collector.sessions.count >= 1 }

        XCTAssertEqual(collector.sessions.count, 1,
                       "Expected exactly one sessionClosed (for A); got \(collector.sessions.count)")
        guard case let .sessionClosed(bundleID, _, durationSeconds, _, _) = collector.sessions.first else {
            return XCTFail("Expected .sessionClosed")
        }
        XCTAssertEqual(bundleID, "com.app.A", "Only A's session should be closed")
        // A: startedAt=t0, lastActiveAt set to tReturnToA=t0+165 on return.
        // Duration = 165 s.
        XCTAssertGreaterThanOrEqual(durationSeconds, 120)
        XCTAssertLessThan(durationSeconds, 300)
    }

    // MARK: - 6. Idle closes session at pre-idle time

    func testIdleClosesSession() async throws {
        let stream = makeStream()
        let collector = SessionCollector()
        collector.attach(to: stream)

        let seg = makeSeg(stream: stream, cadence: { .light })
        await seg.start()
        defer { Task { await seg.stop() } }

        let t0 = Date()

        // Focus A; advance lastActiveAt to t0+150 via same-bundle focus update.
        await focus("com.app.A", at: t0, into: stream)
        await focus("com.app.A", title: "Document", at: t0.addingTimeInterval(150), into: stream)

        // User goes idle (simulated 5 s after last activity).
        await stream.emit(.inputIdle(idleSeconds: 0, at: t0.addingTimeInterval(155)))
        try? await Task.sleep(nanoseconds: 50_000_000)

        // User resumes 600 s later.
        await stream.emit(.inputResumed(afterIdleSeconds: 600, at: t0.addingTimeInterval(755)))
        try? await Task.sleep(nanoseconds: 50_000_000)

        await waitUntil { collector.sessions.count >= 1 }

        XCTAssertEqual(collector.sessions.count, 1,
                       "Expected exactly one sessionClosed for A; got \(collector.sessions.count)")
        guard case let .sessionClosed(bundleID, _, durationSeconds, _, _) = collector.sessions.first else {
            return XCTFail("Expected .sessionClosed")
        }
        XCTAssertEqual(bundleID, "com.app.A")
        // Duration must be ~150 s — the 600 s idle window must not inflate it.
        XCTAssertEqual(durationSeconds, 150, accuracy: 5,
                       "Duration must reflect pre-idle activity (~150 s), not resume time")
    }

    // MARK: - 7. Idle cadence discards session

    func testCadenceIdleDiscards() async throws {
        let stream = makeStream()
        let collector = SessionCollector()
        collector.attach(to: stream)

        // Cadence always returns .idle — user was passive.
        let seg = makeSeg(stream: stream, cadence: { .idle })
        await seg.start()
        defer { Task { await seg.stop() } }

        let t0 = Date()
        await focus("com.app.A", at: t0, into: stream)
        await focus("com.app.B", at: t0.addingTimeInterval(300), into: stream)

        try await Task.sleep(nanoseconds: UInt64((testFlicker + 0.3) * 1_000_000_000))
        // Give extra time to confirm no event arrives.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(collector.sessions.isEmpty,
                      "Idle-cadence session must be discarded; got \(collector.sessions.count) event(s)")
    }
}
