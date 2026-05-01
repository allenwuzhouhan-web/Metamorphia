import XCTest
import ApplicationServices
@testable import MetamorphiaPerception

// Integration tests require a fixture app — deferred to Wave 10.

final class AXObserverPoolTests: XCTestCase {

    // MARK: - Lifecycle idempotency

    func testStartStopIsIdempotent() {
        let pool = AXObserverPool()
        // Multiple start/stop cycles must not crash or deadlock.
        pool.start()
        pool.start()
        pool.stop()
        pool.stop()
        pool.start()
        pool.stop()
    }

    func testStartThenDetachAllYieldsEmptyPids() {
        let pool = AXObserverPool()
        pool.start()
        pool.detachAll()
        XCTAssertTrue(pool.attachedPids().isEmpty)
        pool.stop()
    }

    // MARK: - Detach non-existent pid

    func testDetachNonExistentPidIsNoOp() {
        let pool = AXObserverPool()
        // pid 99999 virtually never exists in practice.
        pool.detach(pid: 99999)
        XCTAssertTrue(pool.attachedPids().isEmpty)
    }

    // MARK: - attachedPids reflects state

    func testAttachedPidsReflectsDetach() {
        // Without AX permission (common on CI) attach returns nil,
        // so the pool stays empty. We verify that the bookkeeping is
        // consistent in both the trusted and untrusted cases.
        let pool = AXObserverPool()

        let handle = pool.attach(pid: 99999, bundleID: nil)

        if AXIsProcessTrusted() {
            // On a developer machine with AX permission the handle is returned
            // and the pid enters the in-flight set — but because attach is
            // async (hops to AXObserverThread), the attachment record may or
            // may not be present yet. We only assert the detach path is clean.
            pool.detach(pid: 99999)
            // Brief spin to let the observer thread finish (test only).
            let deadline = Date().addingTimeInterval(0.5)
            while !pool.attachedPids().isEmpty && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            XCTAssertFalse(pool.attachedPids().contains(99999))
        } else {
            // No AX permission — attach returns nil immediately and no record
            // is ever stored.
            XCTAssertNil(handle)
            XCTAssertFalse(pool.attachedPids().contains(99999))
        }
    }

    // MARK: - mapNotificationToReason (pure function)

    func testMapActivatedNotification() {
        let pool = AXObserverPool()
        let element = AXUIElementCreateApplication(getpid())
        let reason = pool.mapNotificationToReason(
            kAXApplicationActivatedNotification as String,
            pid: 42,
            element: element
        )
        XCTAssertEqual(reason, .appActivated(pid: 42, bundleID: nil))
    }

    func testMapFocusedElementChangedNotification() {
        let pool = AXObserverPool()
        let element = AXUIElementCreateApplication(getpid())
        let reason = pool.mapNotificationToReason(
            kAXFocusedUIElementChangedNotification as String,
            pid: 42,
            element: element
        )
        XCTAssertEqual(reason, .axFocusedElementChanged(pid: 42))
    }

    func testMapValueChangedNotification() {
        let pool = AXObserverPool()
        let element = AXUIElementCreateApplication(getpid())
        let reason = pool.mapNotificationToReason(
            kAXValueChangedNotification as String,
            pid: 42,
            element: element
        )
        XCTAssertEqual(reason, .axValueChanged(pid: 42, roleHint: nil))
    }

    func testMapSelectedTextChangedNotification() {
        let pool = AXObserverPool()
        let element = AXUIElementCreateApplication(getpid())
        let reason = pool.mapNotificationToReason(
            kAXSelectedTextChangedNotification as String,
            pid: 42,
            element: element
        )
        XCTAssertEqual(reason, .axSelectedTextChanged(pid: 42))
    }

    func testMapWindowCreatedNotification() {
        let pool = AXObserverPool()
        let element = AXUIElementCreateApplication(getpid())
        let reason = pool.mapNotificationToReason(
            kAXWindowCreatedNotification as String,
            pid: 42,
            element: element
        )
        XCTAssertEqual(reason, .axWindowCreated(pid: 42))
    }

    func testMapTitleChangedNotification() {
        let pool = AXObserverPool()
        let element = AXUIElementCreateApplication(getpid())
        let reason = pool.mapNotificationToReason(
            kAXTitleChangedNotification as String,
            pid: 42,
            element: element
        )
        XCTAssertEqual(reason, .axTitleChanged(pid: 42))
    }

    func testMapWindowMovedNotification() {
        let pool = AXObserverPool()
        let element = AXUIElementCreateApplication(getpid())
        let reason = pool.mapNotificationToReason(
            kAXWindowMovedNotification as String,
            pid: 42,
            element: element
        )
        XCTAssertEqual(reason, .axWindowMoved(pid: 42))
    }

    func testMapUnknownNotificationReturnsNil() {
        let pool = AXObserverPool()
        let element = AXUIElementCreateApplication(getpid())
        let reason = pool.mapNotificationToReason(
            "AXSomeFutureNotificationThatDoesNotExist",
            pid: 42,
            element: element
        )
        XCTAssertNil(reason)
    }

    // MARK: - detachAll on empty pool

    func testDetachAllOnEmptyPoolIsNoOp() {
        let pool = AXObserverPool()
        pool.detachAll()
        XCTAssertTrue(pool.attachedPids().isEmpty)
    }

    // MARK: - Shared singleton sanity

    func testSharedSingletonIsSameInstance() {
        XCTAssertTrue(AXObserverPool.shared === AXObserverPool.shared)
    }

    // MARK: - watchedNotifications coverage

    func testWatchedNotificationsContainsExpectedSet() {
        let watched = Set(AXObserverPool.watchedNotifications)
        XCTAssertTrue(watched.contains(kAXApplicationActivatedNotification as String))
        XCTAssertTrue(watched.contains(kAXFocusedUIElementChangedNotification as String))
        XCTAssertTrue(watched.contains(kAXValueChangedNotification as String))
        XCTAssertTrue(watched.contains(kAXSelectedTextChangedNotification as String))
        XCTAssertTrue(watched.contains(kAXWindowCreatedNotification as String))
        XCTAssertTrue(watched.contains(kAXTitleChangedNotification as String))
        XCTAssertTrue(watched.contains(kAXWindowMovedNotification as String))
        XCTAssertEqual(watched.count, 7)
    }
}
