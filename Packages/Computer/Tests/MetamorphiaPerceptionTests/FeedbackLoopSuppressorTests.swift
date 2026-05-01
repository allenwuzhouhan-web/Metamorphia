import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

final class FeedbackLoopSuppressorTests: XCTestCase {

    // MARK: - (a) click then AX event within 400 ms → .agent

    func testClick_withinWindow_classifiesAsAgent() async {
        let suppressor = FeedbackLoopSuppressor()
        let point = CGPoint(x: 100, y: 200)
        let handle = await suppressor.beginAction(kind: .click(point, .left))

        // Simulate an AX event arriving 300 ms later.
        let observedAt = Date().addingTimeInterval(0.3)
        let fp = EventFingerprint(kind: .click(point, .left), at: observedAt)
        let result = suppressor.classify(fingerprint: fp, at: observedAt)

        XCTAssertEqual(result, .agent(handle.id))
    }

    // MARK: - (b) click then AX event after 900 ms → .user

    func testClick_afterExpiry_classifiesAsUser() async {
        let suppressor = FeedbackLoopSuppressor()
        let point = CGPoint(x: 100, y: 200)
        _ = await suppressor.beginAction(kind: .click(point, .left))

        let observedAt = Date().addingTimeInterval(0.9)
        let fp = EventFingerprint(kind: .click(point, .left), at: observedAt)
        let result = suppressor.classify(fingerprint: fp, at: observedAt)

        XCTAssertEqual(result, .user)
    }

    // MARK: - (c) nested paste-inside-click → both handles resolve .agent

    func testNestedPasteAndClick_bothResolveAsAgent() async {
        let suppressor = FeedbackLoopSuppressor()
        let point = CGPoint(x: 50, y: 50)
        let clickHandle = await suppressor.beginAction(kind: .click(point, .left))
        let pasteHandle = await suppressor.beginAction(kind: .paste)

        let now = Date()
        let observedAt = now.addingTimeInterval(0.3)

        let clickFP = EventFingerprint(kind: .click(point, .left), at: observedAt)
        let pasteFP = EventFingerprint(kind: .paste, at: observedAt)

        let clickResult = suppressor.classify(fingerprint: clickFP, at: observedAt)
        let pasteResult = suppressor.classify(fingerprint: pasteFP, at: observedAt)

        XCTAssertEqual(clickResult, .agent(clickHandle.id))
        XCTAssertEqual(pasteResult, .agent(pasteHandle.id))
    }

    // MARK: - (d) user click elsewhere while agent-click outstanding → .user

    func testUserClickElsewhere_doesNotMatch() async {
        let suppressor = FeedbackLoopSuppressor()
        let agentPoint = CGPoint(x: 100, y: 200)
        _ = await suppressor.beginAction(kind: .click(agentPoint, .left))

        // User clicks 50 pts away — outside 24-pt radius.
        let userPoint = CGPoint(x: 150, y: 250)
        let observedAt = Date().addingTimeInterval(0.3)
        let fp = EventFingerprint(kind: .click(userPoint, .left), at: observedAt)
        let result = suppressor.classify(fingerprint: fp, at: observedAt)

        XCTAssertEqual(result, .user)
    }

    // MARK: - (e) canceled action does not suppress user event

    func testCanceledAction_doesNotSuppress() async {
        let suppressor = FeedbackLoopSuppressor()
        let point = CGPoint(x: 100, y: 100)
        let handle = await suppressor.beginAction(kind: .click(point, .left))
        await suppressor.cancel(handle)

        let observedAt = Date().addingTimeInterval(0.3)
        let fp = EventFingerprint(kind: .click(point, .left), at: observedAt)
        let result = suppressor.classify(fingerprint: fp, at: observedAt)

        XCTAssertEqual(result, .user)
    }

    // MARK: - (f) 10k classify() calls complete in <100 ms

    func testClassify_10kCalls_completesUnder100ms() async {
        let suppressor = FeedbackLoopSuppressor()
        let point = CGPoint(x: 100, y: 100)
        // Register a few outstanding handles to make the inner loop non-trivial.
        for _ in 0..<10 {
            _ = await suppressor.beginAction(kind: .click(point, .left))
            _ = await suppressor.beginAction(kind: .paste)
            _ = await suppressor.beginAction(kind: .key(0x00))
        }

        let fp = EventFingerprint(kind: .click(CGPoint(x: 999, y: 999), .left))
        let now = Date()

        let start = Date()
        for _ in 0..<10_000 {
            _ = suppressor.classify(fingerprint: fp, at: now)
        }
        let elapsed = Date().timeIntervalSince(start) * 1000 // ms

        XCTAssertLessThan(elapsed, 100, "10k classify() calls took \(elapsed) ms; expected <100 ms")
    }

    // MARK: - Consumed handle: second identical event → .user

    func testConsumedHandle_secondEventIsUser() async {
        let suppressor = FeedbackLoopSuppressor()
        let point = CGPoint(x: 100, y: 200)
        let handle = await suppressor.beginAction(kind: .click(point, .left))

        let observedAt = Date().addingTimeInterval(0.3)
        let fp = EventFingerprint(kind: .click(point, .left), at: observedAt)

        let first = suppressor.classify(fingerprint: fp, at: observedAt)
        XCTAssertEqual(first, .agent(handle.id))

        // Let the consume Task propagate.
        try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms

        let second = suppressor.classify(fingerprint: fp, at: observedAt)
        XCTAssertEqual(second, .user)
    }

    // MARK: - Key match within window

    func testKey_withinWindow_classifiesAsAgent() async {
        let suppressor = FeedbackLoopSuppressor()
        let handle = await suppressor.beginAction(kind: .key(0x00))

        let observedAt = Date().addingTimeInterval(0.2)
        let fp = EventFingerprint(kind: .key(0x00), at: observedAt)
        let result = suppressor.classify(fingerprint: fp, at: observedAt)

        XCTAssertEqual(result, .agent(handle.id))
    }

    // MARK: - Key match after 400 ms window → .user

    func testKey_afterWindow_classifiesAsUser() async {
        let suppressor = FeedbackLoopSuppressor()
        _ = await suppressor.beginAction(kind: .key(0x00))

        let observedAt = Date().addingTimeInterval(0.5)
        let fp = EventFingerprint(kind: .key(0x00), at: observedAt)
        let result = suppressor.classify(fingerprint: fp, at: observedAt)

        XCTAssertEqual(result, .user)
    }

    // MARK: - Phase B: .batch(UUID) span API

    func testBeginBatch_returnsHandleWithBatchKind() async {
        let suppressor = FeedbackLoopSuppressor()
        let id = UUID()
        let handle = await suppressor.beginBatch(id: id)
        if case let .batch(observedID) = handle.kind {
            XCTAssertEqual(observedID, id)
        } else {
            XCTFail("beginBatch must return an .batch kind — got \(handle.kind)")
        }
    }

    func testBatchKind_neverMatchesUserClickFingerprint() async {
        // A batch span is a correlation marker. It must not be consumable
        // by the classifier's click/key/paste fingerprints — otherwise a
        // real user event at an unrelated point would be silenced for the
        // entire batch span.
        let suppressor = FeedbackLoopSuppressor()
        _ = await suppressor.beginBatch()
        let point = CGPoint(x: 10, y: 20)
        let fp = EventFingerprint(kind: .click(point, .left), at: Date().addingTimeInterval(0.1))
        let result = suppressor.classify(fingerprint: fp, at: Date().addingTimeInterval(0.1))
        XCTAssertEqual(result, .user)
    }

    func testBatchAndClick_coexist_clickClassifiesAsAgent() async {
        // Opening a batch shouldn't interfere with per-action classification
        // inside its span — the individual click handle still resolves its
        // own fingerprint to .agent, with the batch handle inert in parallel.
        let suppressor = FeedbackLoopSuppressor()
        _ = await suppressor.beginBatch()
        let point = CGPoint(x: 200, y: 120)
        let clickHandle = await suppressor.beginAction(kind: .click(point, .left))
        let observedAt = Date().addingTimeInterval(0.2)
        let fp = EventFingerprint(kind: .click(point, .left), at: observedAt)
        XCTAssertEqual(suppressor.classify(fingerprint: fp, at: observedAt),
                       .agent(clickHandle.id))
    }
}
