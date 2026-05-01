import XCTest
@testable import MetamorphiaPerception

// MARK: - FakePasteboard

/// Test double for `PasteboardChangeCountSource`.
/// Bump `changeCount` directly to simulate a clipboard write.
final class FakePasteboard: PasteboardChangeCountSource, @unchecked Sendable {
    var changeCount: Int = 0
}

// MARK: - WorkspaceTriggerSourceTests

@MainActor
final class WorkspaceTriggerSourceTests: XCTestCase {

    // MARK: - appActivated posted on NSWorkspace notification

    func testAppActivatedNotificationPostsTobus() async throws {
        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus)
        source.start()

        let exp = expectation(description: "appActivated received")
        var received: TriggerReason?

        bus.register(interested: [.focus], debounceMs: 10) { batch in
            if let r = batch.reasons.first(where: {
                if case .appActivated = $0 { return true }
                return false
            }) {
                received = r
                exp.fulfill()
            }
        }

        // Post the workspace notification directly — we don't need a real running app.
        // Use a mock userInfo dict with a real NSRunningApplication from the test host.
        let testApp = NSRunningApplication.current
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: testApp]
        )

        await fulfillment(of: [exp], timeout: 0.2)

        guard case let .appActivated(pid, bundleID) = received else {
            return XCTFail("Expected .appActivated, got \(String(describing: received))")
        }
        XCTAssertEqual(pid, testApp.processIdentifier)
        XCTAssertEqual(bundleID, testApp.bundleIdentifier)

        source.stop()
    }

    // MARK: - appTerminated posted on NSWorkspace notification

    func testAppTerminatedNotificationPostsToBus() async throws {
        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus)
        source.start()

        let exp = expectation(description: "appTerminated received")
        var received: TriggerReason?

        bus.register(interested: [.focus], debounceMs: 10) { batch in
            if let r = batch.reasons.first(where: {
                if case .appTerminated = $0 { return true }
                return false
            }) {
                received = r
                exp.fulfill()
            }
        }

        let testApp = NSRunningApplication.current
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: testApp]
        )

        await fulfillment(of: [exp], timeout: 0.2)

        guard case let .appTerminated(pid) = received else {
            return XCTFail("Expected .appTerminated, got \(String(describing: received))")
        }
        XCTAssertEqual(pid, testApp.processIdentifier)

        source.stop()
    }

    // MARK: - systemSleep observer registration
    //
    // macOS blocks test processes from synthesizing `NSWorkspace.willSleepNotification`
    // on `NSWorkspace.shared.notificationCenter` (privileged system notification).
    // Additionally, `.systemSleep` carries `affectedLanes: []` by design, so it is
    // intentionally invisible to all lane-filtered subscribers — the bus ignores it.
    // This test simply verifies that `start()` + `stop()` with the sleep observer
    // in place does not crash, and that the observer token is properly cleaned up.

    func testSystemSleepObserverRegistrationDoesNotCrash() {
        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus)
        source.start()
        // If willSleep observer registration or deregistration causes a crash, this fails.
        source.stop()
    }

    // MARK: - systemWake posted on didWake notification

    func testSystemWakeNotificationPostsToBus() async throws {
        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus)
        source.start()

        let exp = expectation(description: "systemWake received")

        bus.register(interested: .all, debounceMs: 10) { batch in
            if batch.reasons.contains(.systemWake) {
                exp.fulfill()
            }
        }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        await fulfillment(of: [exp], timeout: 0.2)
        source.stop()
    }

    // MARK: - Pasteboard polling detects a changeCount bump

    func testPasteboardPollingFiresOnChangeCountBump() async throws {
        let fakePasteboard = FakePasteboard()
        fakePasteboard.changeCount = 0

        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus, pasteboard: fakePasteboard)
        source.start()

        let exp = expectation(description: "pasteboardChanged received")
        var receivedCount: Int?

        bus.register(interested: [.pasteboard], debounceMs: 10) { batch in
            if let r = batch.reasons.first(where: {
                if case .pasteboardChanged = $0 { return true }
                return false
            }) {
                if case let .pasteboardChanged(cc) = r {
                    receivedCount = cc
                }
                exp.fulfill()
            }
        }

        // Bump the fake changeCount; polling at 2 Hz will detect it within ~600 ms.
        fakePasteboard.changeCount = 1

        await fulfillment(of: [exp], timeout: 0.8)
        XCTAssertEqual(receivedCount, 1)

        source.stop()
    }

    // MARK: - No false positive when changeCount is stable

    func testPasteboardPollingDoesNotFireWhenStable() async throws {
        let fakePasteboard = FakePasteboard()
        fakePasteboard.changeCount = 42

        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus, pasteboard: fakePasteboard)
        source.start()

        let noFireExp = expectation(description: "pasteboardChanged must NOT fire")
        noFireExp.isInverted = true

        bus.register(interested: [.pasteboard], debounceMs: 10) { _ in
            noFireExp.fulfill()
        }

        // Wait for two poll cycles without bumping the count.
        await fulfillment(of: [noFireExp], timeout: 1.2)

        source.stop()
    }

    // MARK: - start/stop idempotency

    func testStartIsIdempotent() async throws {
        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus)

        // Calling start() twice must not crash or double-register.
        // If registration were doubled, we'd receive two batches from one notification.
        source.start()
        source.start()

        let exp = expectation(description: "single systemWake received")
        // assertForOverFulfill catches double-registration (two observers firing).
        exp.assertForOverFulfill = true

        bus.register(interested: .all, debounceMs: 10) { batch in
            if batch.reasons.contains(.systemWake) {
                exp.fulfill()
            }
        }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        await fulfillment(of: [exp], timeout: 0.2)
        source.stop()
    }

    func testStopIsIdempotent() {
        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus)
        source.start()
        source.stop()
        source.stop()  // must not crash
    }

    func testRestartAfterStop() async throws {
        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus)

        source.start()
        source.stop()
        source.start()  // restart

        let exp = expectation(description: "systemWake after restart")
        bus.register(interested: .all, debounceMs: 10) { batch in
            if batch.reasons.contains(.systemWake) { exp.fulfill() }
        }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        await fulfillment(of: [exp], timeout: 0.2)
        source.stop()
    }

    // MARK: - Display callback compilation check

    /// This test only verifies that `start()` does not crash when registering
    /// the CG display reconfig callback. The callback itself cannot be triggered
    /// in unit tests without real display hardware changes.
    func testDisplayCallbackRegistrationDoesNotCrash() {
        let bus = TriggerBus()
        let source = WorkspaceTriggerSource(bus: bus)
        source.start()
        // If we get here, CGDisplayRegisterReconfigurationCallback accepted the call.
        source.stop()
    }
}
