import XCTest
@testable import MetamorphiaPerception

/// Tests for ``TriggerBus``.
///
/// All tests that exercise coalescing use a fresh `TriggerBus` instance (not
/// `.shared`) so they are fully isolated from each other.
///
/// Real debounce timings are used (≤ 25 ms) so every test completes well
/// within the 100 ms window mandated by the spec.
@MainActor
final class TriggerBusTests: XCTestCase {

    // MARK: - Single post fires handler once

    func testSinglePostFiresHandlerOnce() async throws {
        let bus = TriggerBus()
        let expectation = expectation(description: "handler fires")
        expectation.expectedFulfillmentCount = 1

        var batches: [TriggerBatch] = []
        bus.register(interested: .all, debounceMs: 10) { batch in
            batches.append(batch)
            expectation.fulfill()
        }

        bus.post(.pasteboardChanged(changeCount: 1))

        await fulfillment(of: [expectation], timeout: 0.1)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].reasons.count, 1)
    }

    // MARK: - 10 posts in < debounce window coalesce into a single batch

    func testTenPostsCoalesceIntoOneBatch() async throws {
        let bus = TriggerBus()
        let expectation = expectation(description: "handler fires once")
        expectation.expectedFulfillmentCount = 1
        // We only want it to fire once; fail fast if it fires more.
        expectation.assertForOverFulfill = true

        var batches: [TriggerBatch] = []
        bus.register(interested: .all, debounceMs: 25) { batch in
            batches.append(batch)
            expectation.fulfill()
        }

        // Post 10 reasons synchronously (all within the same run-loop turn —
        // well under the 25 ms debounce window).
        for i in 0..<10 {
            bus._postForTest(.pasteboardChanged(changeCount: i))
        }

        await fulfillment(of: [expectation], timeout: 0.1)
        XCTAssertEqual(batches.count, 1, "Expected exactly one batch")
        XCTAssertEqual(batches[0].reasons.count, 10, "All 10 reasons should be coalesced")
    }

    // MARK: - Lane filtering: two subscribers with disjoint lanes

    func testDisjointSubscribersReceiveOnlyTheirLanes() async throws {
        let bus = TriggerBus()

        let pasteboardExp = expectation(description: "pasteboard handler fires")
        let focusExp = expectation(description: "focus handler fires")

        var pasteboardBatches: [TriggerBatch] = []
        var focusBatches: [TriggerBatch] = []

        // Subscriber A: only pasteboard lane
        bus.register(interested: [.pasteboard], debounceMs: 10) { batch in
            pasteboardBatches.append(batch)
            pasteboardExp.fulfill()
        }

        // Subscriber B: only focus lane
        bus.register(interested: [.focus], debounceMs: 10) { batch in
            focusBatches.append(batch)
            focusExp.fulfill()
        }

        // This reason touches .pasteboard only → only subscriber A should fire.
        bus._postForTest(.pasteboardChanged(changeCount: 5))
        // This reason touches .focus + .windows → only subscriber B should fire.
        bus._postForTest(.appActivated(pid: 1, bundleID: nil))

        await fulfillment(of: [pasteboardExp, focusExp], timeout: 0.1)

        XCTAssertEqual(pasteboardBatches.count, 1)
        XCTAssertTrue(
            pasteboardBatches[0].reasons.allSatisfy {
                if case .pasteboardChanged = $0 { return true }
                return false
            },
            "Pasteboard subscriber should only receive pasteboardChanged reasons"
        )

        XCTAssertEqual(focusBatches.count, 1)
        XCTAssertTrue(
            focusBatches[0].reasons.allSatisfy {
                if case .appActivated = $0 { return true }
                return false
            },
            "Focus subscriber should only receive appActivated reasons"
        )
    }

    // MARK: - Unregister before fire suppresses the handler

    func testUnregisterBeforeFireSuppressesHandler() async throws {
        let bus = TriggerBus()

        var handlerCalled = false
        let id = bus.register(interested: .all, debounceMs: 30) { _ in
            handlerCalled = true
        }

        bus._postForTest(.pasteboardChanged(changeCount: 1))
        // Unregister immediately, before the 30 ms window closes.
        bus.unregister(id)

        // Wait longer than the debounce window; handler must not have fired.
        try await Task.sleep(nanoseconds: 80_000_000)  // 80 ms
        XCTAssertFalse(handlerCalled, "Unregistered handler must not be called")
    }

    // MARK: - affectedLanes in batch equals union of reasons' affectedLanes

    func testAffectedLanesIsUnionOfReasons() async throws {
        let bus = TriggerBus()
        let exp = expectation(description: "handler fires")

        var receivedBatch: TriggerBatch?
        bus.register(interested: .all, debounceMs: 20) { batch in
            receivedBatch = batch
            exp.fulfill()
        }

        // .pasteboardChanged → [.pasteboard]
        // .appTerminated    → [.focus, .windows]
        // expected union    → [.pasteboard, .focus, .windows]
        bus._postForTest(.pasteboardChanged(changeCount: 1))
        bus._postForTest(.appTerminated(pid: 99))

        await fulfillment(of: [exp], timeout: 0.1)

        guard let batch = receivedBatch else {
            return XCTFail("No batch received")
        }
        XCTAssertTrue(batch.affectedLanes.contains(.pasteboard))
        XCTAssertTrue(batch.affectedLanes.contains(.focus))
        XCTAssertTrue(batch.affectedLanes.contains(.windows))
        XCTAssertFalse(batch.affectedLanes.contains(.ocr))
    }

    // MARK: - urgency equals max across reasons

    func testUrgencyIsMaxAcrossReasons() async throws {
        let bus = TriggerBus()
        let exp = expectation(description: "handler fires")

        var receivedBatch: TriggerBatch?
        bus.register(interested: .all, debounceMs: 20) { batch in
            receivedBatch = batch
            exp.fulfill()
        }

        // heartbeat urgency = 10, appActivated urgency = 250
        bus._postForTest(.heartbeat(sinceLast: 1.0))
        bus._postForTest(.appActivated(pid: 1, bundleID: nil))

        await fulfillment(of: [exp], timeout: 0.1)

        XCTAssertEqual(receivedBatch?.urgency, 250)
    }

    // MARK: - Heartbeat fires after quiet period

    func testHeartbeatFiredAfterQuietPeriod() async throws {
        let bus = TriggerBus()
        bus.start()

        let exp = expectation(description: "heartbeat received")

        var receivedHeartbeat = false
        bus.register(interested: .all, debounceMs: 10) { batch in
            if batch.reasons.contains(where: { if case .heartbeat = $0 { return true }; return false }) {
                if !receivedHeartbeat {
                    receivedHeartbeat = true
                    exp.fulfill()
                }
            }
        }

        // Set a very short quiet window so the test is fast.
        bus.setHeartbeat(quietSeconds: 0.1)

        // No posts at all — heartbeat should arrive within 300 ms.
        await fulfillment(of: [exp], timeout: 0.3)
        XCTAssertTrue(receivedHeartbeat)
        bus.stop()
    }

    // MARK: - After a real post, heartbeat is suppressed until quiet again

    func testHeartbeatSuppressedAfterRecentPost() async throws {
        let bus = TriggerBus()
        bus.start()

        let heartbeatExp = expectation(description: "heartbeat fired after quiet")
        heartbeatExp.isInverted = false  // we DO expect it eventually, just not too early

        var heartbeatCount = 0
        var firstHeartbeatAt: Date?

        bus.register(interested: .all, debounceMs: 10) { batch in
            for r in batch.reasons {
                if case .heartbeat = r {
                    heartbeatCount += 1
                    if firstHeartbeatAt == nil {
                        firstHeartbeatAt = Date()
                        heartbeatExp.fulfill()
                    }
                }
            }
        }

        let quietWindow: TimeInterval = 0.1
        bus.setHeartbeat(quietSeconds: quietWindow)

        // Post a real reason now — this resets lastNonHeartbeatPost.
        let postTime = Date()
        bus._postForTest(.pasteboardChanged(changeCount: 1))

        // Heartbeat must NOT arrive before (postTime + quietWindow - some slack).
        // We wait the full window + 50 ms buffer.
        await fulfillment(of: [heartbeatExp], timeout: 0.5)

        if let t = firstHeartbeatAt {
            let elapsed = t.timeIntervalSince(postTime)
            XCTAssertGreaterThanOrEqual(
                elapsed, quietWindow - 0.05,
                "Heartbeat arrived \(elapsed * 1000, precision: 1) ms after post; expected ≥ \(quietWindow * 1000) ms"
            )
        }

        bus.stop()
    }
}

// MARK: - Formatting helper

private extension Double {
    func formatted(precision: Int) -> String {
        String(format: "%.\(precision)f", self)
    }
}

private func format(_ value: Double, precision: Int) -> String {
    value.formatted(precision: precision)
}

// Allow `\(value, precision: N)` in string interpolation.
extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: Double, precision: Int) {
        appendLiteral(value.formatted(precision: precision))
    }
}
