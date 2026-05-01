import XCTest
@testable import MetamorphiaPerception

final class TriggerReasonTests: XCTestCase {

    // MARK: - Urgency

    func testUrgencyAppActivated() {
        XCTAssertEqual(TriggerReason.appActivated(pid: 100, bundleID: "com.apple.safari").urgency, 250)
    }

    func testUrgencyAppTerminated() {
        XCTAssertEqual(TriggerReason.appTerminated(pid: 100).urgency, 240)
    }

    func testUrgencyAxFocusedElementChanged() {
        XCTAssertEqual(TriggerReason.axFocusedElementChanged(pid: 100).urgency, 200)
    }

    func testUrgencyAxSelectedTextChanged() {
        XCTAssertEqual(TriggerReason.axSelectedTextChanged(pid: 100).urgency, 180)
    }

    func testUrgencySystemWake() {
        XCTAssertEqual(TriggerReason.systemWake.urgency, 170)
    }

    func testUrgencyForcedRefresh() {
        XCTAssertEqual(TriggerReason.forcedRefresh(origin: "test").urgency, 160)
    }

    func testUrgencyAxWindowCreated() {
        XCTAssertEqual(TriggerReason.axWindowCreated(pid: 100).urgency, 140)
    }

    func testUrgencyAxValueChanged() {
        XCTAssertEqual(TriggerReason.axValueChanged(pid: 100, roleHint: nil).urgency, 120)
    }

    func testUrgencyAxWindowMoved() {
        XCTAssertEqual(TriggerReason.axWindowMoved(pid: 100).urgency, 100)
    }

    func testUrgencyDisplayConfigurationChanged() {
        XCTAssertEqual(TriggerReason.displayConfigurationChanged.urgency, 90)
    }

    func testUrgencyAxTitleChanged() {
        XCTAssertEqual(TriggerReason.axTitleChanged(pid: 100).urgency, 80)
    }

    func testUrgencyPasteboardChanged() {
        XCTAssertEqual(TriggerReason.pasteboardChanged(changeCount: 5).urgency, 60)
    }

    func testUrgencyFsEvent() {
        XCTAssertEqual(TriggerReason.fsEvent(path: "/tmp/test").urgency, 50)
    }

    func testUrgencySystemSleep() {
        XCTAssertEqual(TriggerReason.systemSleep.urgency, 30)
    }

    func testUrgencyHeartbeat() {
        XCTAssertEqual(TriggerReason.heartbeat(sinceLast: 1.0).urgency, 10)
    }

    // MARK: - Affected lanes

    func testAppActivatedLanes() {
        let lanes = TriggerReason.appActivated(pid: 1, bundleID: nil).affectedLanes
        XCTAssertTrue(lanes.contains(.focus))
        XCTAssertTrue(lanes.contains(.windows))
        XCTAssertTrue(lanes.contains(.axTree))
        XCTAssertTrue(lanes.contains(.menus))
        XCTAssertTrue(lanes.contains(.dHash))
        XCTAssertFalse(lanes.contains(.pasteboard))
    }

    func testAppTerminatedLanes() {
        let lanes = TriggerReason.appTerminated(pid: 1).affectedLanes
        XCTAssertTrue(lanes.contains(.focus))
        XCTAssertTrue(lanes.contains(.windows))
        XCTAssertFalse(lanes.contains(.axTree))
    }

    func testAxFocusedElementChangedLanes() {
        let lanes = TriggerReason.axFocusedElementChanged(pid: 1).affectedLanes
        XCTAssertTrue(lanes.contains(.axTree))
        XCTAssertTrue(lanes.contains(.selection))
        XCTAssertFalse(lanes.contains(.windows))
    }

    func testAxValueChangedLanes() {
        let lanes = TriggerReason.axValueChanged(pid: 1, roleHint: "AXTextField").affectedLanes
        XCTAssertTrue(lanes.contains(.axTree))
        XCTAssertFalse(lanes.contains(.selection))
    }

    func testAxSelectedTextChangedLanes() {
        let lanes = TriggerReason.axSelectedTextChanged(pid: 1).affectedLanes
        XCTAssertTrue(lanes.contains(.selection))
        XCTAssertFalse(lanes.contains(.axTree))
    }

    func testAxWindowCreatedLanes() {
        let lanes = TriggerReason.axWindowCreated(pid: 1).affectedLanes
        XCTAssertTrue(lanes.contains(.windows))
        XCTAssertTrue(lanes.contains(.axTree))
    }

    func testAxWindowMovedLanes() {
        let lanes = TriggerReason.axWindowMoved(pid: 1).affectedLanes
        XCTAssertTrue(lanes.contains(.windows))
        XCTAssertFalse(lanes.contains(.axTree))
    }

    func testAxTitleChangedLanes() {
        let lanes = TriggerReason.axTitleChanged(pid: 1).affectedLanes
        XCTAssertTrue(lanes.contains(.axTree))
        XCTAssertTrue(lanes.contains(.windows))
    }

    func testSystemWakeLanes() {
        XCTAssertEqual(TriggerReason.systemWake.affectedLanes, .all)
    }

    func testSystemSleepLanes() {
        XCTAssertTrue(TriggerReason.systemSleep.affectedLanes.isEmpty)
    }

    func testDisplayConfigurationChangedLanes() {
        let lanes = TriggerReason.displayConfigurationChanged.affectedLanes
        XCTAssertTrue(lanes.contains(.displays))
        XCTAssertTrue(lanes.contains(.windows))
        XCTAssertFalse(lanes.contains(.axTree))
    }

    func testPasteboardChangedLanes() {
        let lanes = TriggerReason.pasteboardChanged(changeCount: 1).affectedLanes
        XCTAssertTrue(lanes.contains(.pasteboard))
        XCTAssertFalse(lanes.contains(.focus))
    }

    func testFsEventLanes() {
        let lanes = TriggerReason.fsEvent(path: "/Users/test/file.txt").affectedLanes
        XCTAssertTrue(lanes.contains(.documents))
        XCTAssertFalse(lanes.contains(.pasteboard))
    }

    func testHeartbeatLanes() {
        XCTAssertEqual(TriggerReason.heartbeat(sinceLast: 5.0).affectedLanes, .all)
    }

    func testForcedRefreshLanes() {
        XCTAssertEqual(TriggerReason.forcedRefresh(origin: "manual").affectedLanes, .all)
    }

    // MARK: - Hashable round-trip

    func testHashableEqualityAppActivated() {
        let a = TriggerReason.appActivated(pid: 42, bundleID: "com.apple.finder")
        let b = TriggerReason.appActivated(pid: 42, bundleID: "com.apple.finder")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testHashableInequalityAppActivatedDifferentPid() {
        let a = TriggerReason.appActivated(pid: 42, bundleID: "com.apple.finder")
        let b = TriggerReason.appActivated(pid: 99, bundleID: "com.apple.finder")
        XCTAssertNotEqual(a, b)
    }

    func testHashableEqualityFsEvent() {
        let a = TriggerReason.fsEvent(path: "/tmp/foo")
        let b = TriggerReason.fsEvent(path: "/tmp/foo")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testHashableInequalityFsEventDifferentPath() {
        let a = TriggerReason.fsEvent(path: "/tmp/foo")
        let b = TriggerReason.fsEvent(path: "/tmp/bar")
        XCTAssertNotEqual(a, b)
    }

    func testHashableEqualityHeartbeat() {
        let a = TriggerReason.heartbeat(sinceLast: 2.5)
        let b = TriggerReason.heartbeat(sinceLast: 2.5)
        XCTAssertEqual(a, b)
    }

    func testHashableEqualityAxValueChangedNilRoleHint() {
        let a = TriggerReason.axValueChanged(pid: 10, roleHint: nil)
        let b = TriggerReason.axValueChanged(pid: 10, roleHint: nil)
        XCTAssertEqual(a, b)
    }

    func testHashableInequalityAxValueChangedDifferentRoleHint() {
        let a = TriggerReason.axValueChanged(pid: 10, roleHint: nil)
        let b = TriggerReason.axValueChanged(pid: 10, roleHint: "AXTextField")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - LaneSet

    func testLaneSetAllContainsEveryLane() {
        let all = LaneSet.all
        XCTAssertTrue(all.contains(.focus))
        XCTAssertTrue(all.contains(.windows))
        XCTAssertTrue(all.contains(.displays))
        XCTAssertTrue(all.contains(.axTree))
        XCTAssertTrue(all.contains(.menus))
        XCTAssertTrue(all.contains(.dHash))
        XCTAssertTrue(all.contains(.ocr))
        XCTAssertTrue(all.contains(.browserDOM))
        XCTAssertTrue(all.contains(.pasteboard))
        XCTAssertTrue(all.contains(.documents))
        XCTAssertTrue(all.contains(.selection))
    }

    func testLaneSetUnion() {
        let combined: LaneSet = [.focus, .windows]
        XCTAssertTrue(combined.contains(.focus))
        XCTAssertTrue(combined.contains(.windows))
        XCTAssertFalse(combined.contains(.ocr))
    }

    func testLaneSetIntersection() {
        let a: LaneSet = [.focus, .windows, .axTree]
        let b: LaneSet = [.windows, .axTree, .menus]
        let intersection = a.intersection(b)
        XCTAssertTrue(intersection.contains(.windows))
        XCTAssertTrue(intersection.contains(.axTree))
        XCTAssertFalse(intersection.contains(.focus))
        XCTAssertFalse(intersection.contains(.menus))
    }
}
