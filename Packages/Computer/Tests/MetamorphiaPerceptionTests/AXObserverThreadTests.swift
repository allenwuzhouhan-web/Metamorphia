import XCTest
@testable import MetamorphiaPerception

final class AXObserverThreadTests: XCTestCase {

    private var observerThread: AXObserverThread!

    override func setUp() {
        super.setUp()
        observerThread = AXObserverThread()
    }

    override func tearDown() {
        observerThread.stop()
        observerThread = nil
        super.tearDown()
    }

    // MARK: - (a) perform executes on the observer thread

    func testPerformExecutesOnObserverThread() {
        observerThread.start()

        final class NameBox: @unchecked Sendable { var value: String? }
        let box = NameBox()
        let expectation = expectation(description: "block runs")

        observerThread.perform {
            box.value = Thread.current.name
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(box.value, "com.metamorphia.ax.observer")
    }

    // MARK: - (b) stop then perform is a no-op (no crash)

    func testPerformAfterStopIsNoOp() {
        observerThread.start()
        observerThread.stop()

        // After stop, runLoopRef() should return nil.
        XCTAssertNil(observerThread.runLoopRef())

        // Calling perform must not crash.
        observerThread.perform {
            XCTFail("Block should never execute after stop")
        }

        // Give a moment to confirm nothing fires.
        Thread.sleep(forTimeInterval: 0.1)
    }

    func testRunLoopRefIsNilBeforeStart() {
        XCTAssertNil(observerThread.runLoopRef())
    }

    func testRunLoopRefIsNonNilAfterStart() {
        observerThread.start()
        XCTAssertNotNil(observerThread.runLoopRef())
    }

    func testRunLoopRefIsNilAfterStop() {
        observerThread.start()
        observerThread.stop()
        XCTAssertNil(observerThread.runLoopRef())
    }

    // MARK: - (c) two perform blocks execute in submission order

    func testPerformBlocksExecuteInOrder() {
        observerThread.start()

        // Use a class box so the closure captures a reference type (avoids
        // Swift 6 SendableClosureCaptures warning on the mutable var).
        final class OrderBox: @unchecked Sendable {
            let lock = NSLock()
            var order: [Int] = []
        }
        let box = OrderBox()
        let exp1 = expectation(description: "block 1")
        let exp2 = expectation(description: "block 2")

        observerThread.perform {
            box.lock.withLock { box.order.append(1) }
            exp1.fulfill()
        }
        observerThread.perform {
            box.lock.withLock { box.order.append(2) }
            exp2.fulfill()
        }

        wait(for: [exp1, exp2], timeout: 2.0, enforceOrder: true)

        let captured = box.lock.withLock { box.order }
        XCTAssertEqual(captured, [1, 2], "Blocks must execute in submission order")
    }

    // MARK: - (d) double start is safe (second call is a no-op)

    func testDoubleStartIsNoOp() {
        observerThread.start()
        let rl1 = observerThread.runLoopRef()

        // Second start should not spawn a new thread or replace the run loop.
        observerThread.start()
        let rl2 = observerThread.runLoopRef()

        XCTAssertNotNil(rl1)
        XCTAssertNotNil(rl2)
        // Both refs must point to the same CFRunLoop object.
        XCTAssertTrue(
            rl1.flatMap { r1 in rl2.map { r2 in CFEqual(r1, r2) } } == true,
            "Second start must not replace the run loop"
        )
    }
}
