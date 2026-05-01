import XCTest
@testable import MetamorphiaPerception

// MARK: - MockCapture

/// Records `capture(lanes:base:)` calls and returns a canned `ScreenMap`.
final class MockCapture: PerceptionCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var _lanes: [LaneSet] = []

    var capturedLanes: [LaneSet] {
        lock.withLock { _lanes }
    }

    private let stub: ScreenMap

    init(stub: ScreenMap) {
        self.stub = stub
    }

    func capture(lanes: LaneSet, base: ScreenMap?) async -> ScreenMap {
        lock.withLock { _lanes.append(lanes) }
        return stub
    }
}

// MARK: - MockYielder

/// Records `deliver(_:)` calls.
final class MockYielder: SnapshotYielder, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [ScreenMap] = []

    var delivered: [ScreenMap] {
        lock.withLock { _delivered }
    }

    func deliver(_ map: ScreenMap) {
        lock.withLock { _delivered.append(map) }
    }
}

// MARK: - Helpers

private func makeTestDisplay() -> DisplayInfo {
    DisplayInfo(
        id: 1,
        index: 0,
        name: "Main",
        origin: .zero,
        width: 1512,
        height: 982,
        scale: 2,
        isMain: true
    )
}

private func makeScreenMap() -> ScreenMap {
    ScreenMap(
        timestamp: Date(),
        captureMs: 5,
        displays: [makeTestDisplay()],
        focusedApp: AppInfo(name: "Test", bundleID: "com.test", pid: 1),
        windows: [],
        elements: [],
        navigation: nil,
        safety: .empty,
        metadata: CaptureMetadata(
            axCoveragePercent: 1.0,
            ocrUsed: false,
            elementCount: 0,
            interactiveCount: 0,
            offScreenHint: nil
        ),
        menus: []
    )
}

// MARK: - Tests

@MainActor
final class PushPerceptionDriverTests: XCTestCase {

    // MARK: Idempotent start

    func testStartTwiceRegistersOneHandler() async throws {
        let bus = TriggerBus()
        let pipeline = MockCapture(stub: makeScreenMap())
        let yielder = MockYielder()

        let driver = PushPerceptionDriver(bus: bus, pipeline: pipeline, yielder: yielder)
        driver.start()
        driver.start()   // second call must be a no-op

        await Task.yield()

        // Post a reason and wait for debounce + handler dispatch.
        bus._postForTest(.appActivated(pid: 100, bundleID: "com.apple.finder"))
        try await Task.sleep(nanoseconds: 100_000_000)

        // One handler → exactly one capture from the trigger + one from the seed = 2 total.
        // If start() were called twice and registered two handlers, the trigger would
        // produce 2 calls from handlers alone — total would be 3 or more. So ≤ 2 is correct.
        let count = pipeline.capturedLanes.count
        XCTAssertLessThanOrEqual(count, 2, "Double-start must not double-register the handler (seed=1, trigger=1, total must be ≤ 2)")
    }

    // MARK: Stop restores pull mode

    func testStopRestoresPullMode() async throws {
        let loop = PerceptionLoop()
        let bus = TriggerBus()
        let pipeline = MockCapture(stub: makeScreenMap())

        let driver = PushPerceptionDriver(bus: bus, pipeline: pipeline, loop: loop)
        driver.start()

        // Allow the async setMode(.push) Task to execute.
        try await Task.sleep(nanoseconds: 30_000_000)
        let modeAfterStart = await loop.mode
        XCTAssertEqual(modeAfterStart, .push)

        driver.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        let modeAfterStop = await loop.mode
        XCTAssertEqual(modeAfterStop, .pull)
    }

    // MARK: appActivated posts to correct lanes

    func testAppActivatedTriggerCapturesCorrectLanes() async throws {
        let bus = TriggerBus()
        let stub = makeScreenMap()
        let pipeline = MockCapture(stub: stub)
        let yielder = MockYielder()

        let driver = PushPerceptionDriver(bus: bus, pipeline: pipeline, yielder: yielder)
        driver.start()
        await Task.yield()

        // Post an appActivated reason; affectedLanes = [.focus, .windows, .axTree, .menus, .dHash].
        bus._postForTest(.appActivated(pid: 200, bundleID: "com.apple.safari"))

        // Wait for debounce (25 ms) + handler dispatch margin.
        try await Task.sleep(nanoseconds: 100_000_000)

        let lanes = pipeline.capturedLanes
        XCTAssertFalse(lanes.isEmpty, "At least one capture should have been triggered")

        let expectedLanes = TriggerReason.appActivated(pid: 200, bundleID: "com.apple.safari").affectedLanes
        XCTAssertTrue(
            lanes.contains(expectedLanes),
            "Captured lanes should include the appActivated lanes: expected \(expectedLanes), got \(lanes)"
        )
    }

    // MARK: yieldSnapshot is reached

    func testRunCaptureYieldsSnapshot() async throws {
        let bus = TriggerBus()
        let stub = makeScreenMap()
        let pipeline = MockCapture(stub: stub)
        let yielder = MockYielder()

        let driver = PushPerceptionDriver(bus: bus, pipeline: pipeline, yielder: yielder)
        driver.start()
        await Task.yield()

        bus._postForTest(.axFocusedElementChanged(pid: 1))
        try await Task.sleep(nanoseconds: 100_000_000)

        let snaps = yielder.delivered
        XCTAssertFalse(snaps.isEmpty, "At least one snapshot should have been delivered to the yielder")
        XCTAssertEqual(snaps.last?.captureMs, stub.captureMs)
    }
}
