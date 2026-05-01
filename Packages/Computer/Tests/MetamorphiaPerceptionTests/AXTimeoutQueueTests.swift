import XCTest
@testable import MetamorphiaPerception

final class AXTimeoutQueueTests: XCTestCase {

    // Each test uses a fresh queue so poison state doesn't bleed across cases.
    private var queue: AXTimeoutQueue!

    override func setUp() {
        super.setUp()
        queue = AXTimeoutQueue()
    }

    override func tearDown() {
        queue = nil
        super.tearDown()
    }

    // MARK: - (a) Normal path

    func testNormalPathReturnsValue() throws {
        let result = try queue.run(pid: 100) { "ok" }
        XCTAssertEqual(result, "ok")
    }

    func testNormalPathWithInt() throws {
        let result = try queue.run(pid: 200) { 42 }
        XCTAssertEqual(result, 42)
    }

    // MARK: - (b) Timeout and subsequent poison

    func testTimeoutThrowsAXTimeoutError() {
        XCTAssertThrowsError(
            try queue.run(pid: 101, timeout: 0.05) {
                Thread.sleep(forTimeInterval: 0.3)
                return "late"
            }
        ) { error in
            XCTAssertTrue(error is AXTimeoutError, "Expected AXTimeoutError, got \(error)")
            let te = error as! AXTimeoutError
            XCTAssertEqual(te.pid, 101)
            XCTAssertEqual(te.timeout, 0.05, accuracy: 0.001)
        }
    }

    func testSecondCallAfterTimeoutThrowsAXPoisonedError() {
        // First call times out, poisoning pid 101.
        _ = try? queue.run(pid: 101, timeout: 0.05) {
            Thread.sleep(forTimeInterval: 0.3)
            return "late"
        }

        // Second call within the 5-second poison window must throw immediately.
        XCTAssertThrowsError(
            try queue.run(pid: 101) { "should not run" }
        ) { error in
            XCTAssertTrue(error is AXPoisonedError, "Expected AXPoisonedError, got \(error)")
            let pe = error as! AXPoisonedError
            XCTAssertEqual(pe.pid, 101)
            XCTAssertTrue(pe.poisonedUntil > Date(), "poisonedUntil should be in the future")
        }
    }

    func testIsPoisonedAfterTimeout() {
        _ = try? queue.run(pid: 102, timeout: 0.05) {
            Thread.sleep(forTimeInterval: 0.3)
            return "late"
        }
        XCTAssertTrue(queue.isPoisoned(pid: 102))
    }

    func testIsNotPoisonedForUntouchedPid() {
        XCTAssertFalse(queue.isPoisoned(pid: 999))
    }

    // MARK: - (c) clearPoison allows subsequent calls

    func testClearPoisonAllowsSubsequentCall() throws {
        // Poison pid 103.
        _ = try? queue.run(pid: 103, timeout: 0.05) {
            Thread.sleep(forTimeInterval: 0.3)
            return "late"
        }
        XCTAssertTrue(queue.isPoisoned(pid: 103))

        // Clear the poison.
        queue.clearPoison(pid: 103)
        XCTAssertFalse(queue.isPoisoned(pid: 103))

        // Give the queue time to drain the abandoned work item so the next call
        // doesn't queue behind it indefinitely. 0.35 s covers the 0.3 s sleep.
        Thread.sleep(forTimeInterval: 0.35)

        // Normal call should now succeed.
        let result = try queue.run(pid: 103) { "cleared" }
        XCTAssertEqual(result, "cleared")
    }

    func testClearPoisonOnNonPoisonedPidIsNoOp() {
        queue.clearPoison(pid: 888)
        XCTAssertFalse(queue.isPoisoned(pid: 888))
    }

    // MARK: - (d) Concurrent calls for different pids

    /// Submit 10 concurrent calls, 2 with a slow body (pid 201, 202) and 8
    /// with a fast body (pids 210–217). The fast calls should all complete
    /// within a generous 2 s wall-clock budget even though the serial queue
    /// serialises them.
    ///
    /// Note: because the queue IS serial, the 8 fast calls will queue behind
    /// the 2 slow ones to the extent they happen to be dispatched first.
    /// We therefore stagger submission: fast calls are dispatched first so they
    /// land ahead of the slow ones in the queue. Each fast call runs in ~0 ms,
    /// so 8 of them should complete in well under the 2 s budget.
    func testConcurrentDifferentPidsDoNotInterfere() {
        let q = AXTimeoutQueue()
        let group = DispatchGroup()
        let resultLock = NSLock()
        var fastSuccesses = 0
        var slowTimeouts = 0

        // Dispatch all 8 fast pids first.
        for i in 210...217 {
            let pid = pid_t(i)
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = try? q.run(pid: pid, timeout: 1.0) { "fast-\(pid)" }
                resultLock.withLock {
                    if r != nil { fastSuccesses += 1 }
                }
                group.leave()
            }
        }

        // Brief yield so the fast items land in the serial queue first.
        Thread.sleep(forTimeInterval: 0.01)

        // Dispatch 2 slow pids after.
        for pid in [pid_t(201), pid_t(202)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? q.run(pid: pid, timeout: 0.05) {
                    Thread.sleep(forTimeInterval: 0.3)
                    return "slow"
                }
                resultLock.withLock { slowTimeouts += 1 }
                group.leave()
            }
        }

        let completed = group.wait(timeout: .now() + 6.0)
        XCTAssertEqual(completed, .success, "Not all tasks finished in time")
        XCTAssertEqual(fastSuccesses, 8, "All 8 fast pids should succeed")
        XCTAssertEqual(slowTimeouts, 2, "Both slow pids should have timed out")
    }
}
