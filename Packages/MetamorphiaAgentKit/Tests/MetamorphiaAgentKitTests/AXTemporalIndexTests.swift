import XCTest
import CoreGraphics
@testable import MetamorphiaAgentKit

final class AXTemporalIndexTests: XCTestCase {

    // MARK: - Helpers

    private let base = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func makeIndex(
        maxTotalBytes: Int = 50 * 1_024 * 1_024,
        maxAgeSeconds: TimeInterval = 300,
        snapshotInterval: TimeInterval = 60,
        maxSnapshotsPerPid: Int = 5,
        sensitiveFieldFilter: @escaping @Sendable (String, String?) -> Bool = { role, _ in
            role == "AXSecureTextField"
        }
    ) -> AXTemporalIndex {
        AXTemporalIndex(
            maxTotalBytes: maxTotalBytes,
            maxAgeSeconds: maxAgeSeconds,
            snapshotInterval: snapshotInterval,
            maxSnapshotsPerPid: maxSnapshotsPerPid,
            sensitiveFieldFilter: sensitiveFieldFilter
        )
    }

    /// Build a deterministic element. `seed` drives hash, role, and bounds.
    private func element(
        seed: UInt64,
        role: String = "AXButton",
        title: String? = "Button",
        x: CGFloat = 0
    ) -> AXTemporalIndex.RawElement {
        let bytes = AXTemporalIndex.RawElement.estimateBytes(role: role, title: title)
        return AXTemporalIndex.RawElement(
            identityHash: seed,
            role: role,
            title: title,
            bounds: CGRect(x: x, y: 0, width: 44, height: 44),
            bytesEstimate: bytes
        )
    }

    // MARK: - (a) Single-element ingest and point query

    func testSingleElementIngestAndQuery() async {
        let idx = makeIndex()
        let el = element(seed: 1)
        await idx.ingest(pid: 1, elements: [el], at: base)

        let result = await idx.query(pid: 1, at: base)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].identityHash, el.identityHash)
    }

    // MARK: - (b) Delta round-trip with clock advancement

    func testTreeAAtT30AndTreeBAtT90() async {
        let idx = makeIndex(snapshotInterval: 60)
        let treeA = [element(seed: 10), element(seed: 11)]
        let treeB = [element(seed: 20), element(seed: 21)]

        let t0 = base
        let t61 = base.addingTimeInterval(61)

        await idx.ingest(pid: 2, elements: treeA, at: t0)
        await idx.ingest(pid: 2, elements: treeB, at: t61)

        // Query at T+30 should return tree A.
        let atT30 = await idx.query(pid: 2, at: base.addingTimeInterval(30))
        let hashesAtT30 = Set(atT30.map(\.identityHash))
        XCTAssertEqual(hashesAtT30, Set(treeA.map(\.identityHash)),
                       "Query at T+30 must return tree A, not B")

        // Query at T+90 should return tree B.
        let atT90 = await idx.query(pid: 2, at: base.addingTimeInterval(90))
        let hashesAtT90 = Set(atT90.map(\.identityHash))
        XCTAssertEqual(hashesAtT90, Set(treeB.map(\.identityHash)),
                       "Query at T+90 must return tree B")
    }

    // MARK: - (c) Sensitive field filter redacts title

    func testSensitiveFieldFilterRedactsTitle() async {
        let idx = makeIndex()
        let secureEl = AXTemporalIndex.RawElement(
            identityHash: 999,
            role: "AXSecureTextField",
            title: "mypassword",
            bounds: .zero,
            bytesEstimate: 100
        )
        await idx.ingest(pid: 3, elements: [secureEl], at: base)

        let result = await idx.query(pid: 3, at: base)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].title, "Secure text field title must be redacted to nil")
        XCTAssertEqual(result[0].role, "AXSecureTextField")
    }

    // MARK: - (d) Memory cap: 100 pids × 5 snapshots × 100 elements

    func testMemoryCapEvictsLRUPid() async {
        // Use a tight cap so eviction fires during the test.
        // 100 elements × ~70 bytes each × 5 snapshots ≈ 35 000 bytes per pid.
        // Set the cap to 10 pids' worth so the index starts evicting before pid 100.
        let bytesPerElement = AXTemporalIndex.RawElement.estimateBytes(role: "AXButton", title: "B")
        let approxBytesPerPid = bytesPerElement * 100 * 5
        let cap = approxBytesPerPid * 10  // room for 10 pids; evicts beyond that

        let idx = makeIndex(
            maxTotalBytes: cap,
            snapshotInterval: 1   // 1-second interval so every 1s ingest creates a snapshot
        )

        // Ingest 5 snapshots × 100 elements for each of 100 pids.
        for pid in pid_t(1) ... pid_t(100) {
            for snap in 0 ..< 5 {
                let t = base.addingTimeInterval(Double(snap) * 2)  // 2s apart > snapshotInterval=1
                let elements = (UInt64(0) ..< 100).map { seed in
                    self.element(seed: seed + UInt64(pid) * 1000, role: "AXButton", title: "B")
                }
                await idx.ingest(pid: pid, elements: elements, at: t)
            }
        }

        let usage = await idx.memoryUsage()
        XCTAssertLessThanOrEqual(usage.totalBytes, cap,
                                 "Total bytes must stay under cap after eviction")
        XCTAssertLessThan(usage.pidCount, 100,
                          "Some pids must have been evicted to stay under cap")
    }

    // MARK: - (e) forget(pid:) drops all snapshots

    func testForgetDropsAllSnapshots() async {
        let idx = makeIndex()
        let els = [element(seed: 42), element(seed: 43)]
        await idx.ingest(pid: 7, elements: els, at: base)

        await idx.forget(pid: 7)

        let result = await idx.query(pid: 7, at: base)
        XCTAssertTrue(result.isEmpty, "Forgotten pid must return empty query")

        let usage = await idx.memoryUsage()
        XCTAssertEqual(usage.pidCount, 0)
        XCTAssertEqual(usage.totalBytes, 0)
    }

    // MARK: - (f) Delta round-trip: query at A's time returns A, not A+x

    func testDeltaRoundTrip() async {
        let idx = makeIndex(snapshotInterval: 60)
        let tA = [element(seed: 100), element(seed: 101)]
        let tAx = [element(seed: 100), element(seed: 101), element(seed: 102)]  // A + extra

        let t0 = base
        let t61 = base.addingTimeInterval(61)

        await idx.ingest(pid: 8, elements: tA, at: t0)
        await idx.ingest(pid: 8, elements: tAx, at: t61)

        // Query at t0 (A's time) must return exactly A.
        let resultAtT0 = await idx.query(pid: 8, at: t0)
        let hashesAtT0 = Set(resultAtT0.map(\.identityHash))
        XCTAssertEqual(hashesAtT0, Set(tA.map(\.identityHash)),
                       "Query at T0 must return tree A, not A+x")

        // Query at t61 must return A+x.
        let resultAtT61 = await idx.query(pid: 8, at: t61)
        let hashesAtT61 = Set(resultAtT61.map(\.identityHash))
        XCTAssertEqual(hashesAtT61, Set(tAx.map(\.identityHash)),
                       "Query at T61 must return tree A+x")
    }

    // MARK: - Extra: query before any snapshot returns empty

    func testQueryBeforeFirstSnapshotReturnsEmpty() async {
        let idx = makeIndex()
        await idx.ingest(pid: 9, elements: [element(seed: 1)], at: base)

        let result = await idx.query(pid: 9, at: base.addingTimeInterval(-1))
        XCTAssertTrue(result.isEmpty, "Query before first snapshot must return empty")
    }

    // MARK: - Extra: unknown pid returns empty

    func testUnknownPidReturnsEmpty() async {
        let idx = makeIndex()
        let result = await idx.query(pid: 999, at: base)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Extra: predicate filter is applied

    func testQueryPredicateFilters() async {
        let idx = makeIndex()
        let btn = element(seed: 1, role: "AXButton", title: "OK")
        let txt = element(seed: 2, role: "AXStaticText", title: "Hello")
        await idx.ingest(pid: 10, elements: [btn, txt], at: base)

        let buttons = await idx.query(pid: 10, at: base) { $0.role == "AXButton" }
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons[0].role, "AXButton")
    }

    // MARK: - Extra: within snapshotInterval no new snapshot is stored

    func testWithinIntervalNoExtraSnapshot() async {
        let idx = makeIndex(snapshotInterval: 60)
        await idx.ingest(pid: 11, elements: [element(seed: 1)], at: base)
        // Second ingest only 10s later — should be ignored.
        await idx.ingest(pid: 11, elements: [element(seed: 2)], at: base.addingTimeInterval(10))

        let usage = await idx.memoryUsage()
        XCTAssertEqual(usage.snapshotCount, 1, "Second ingest within interval must not create a snapshot")

        // Query should still see element 1, not element 2.
        let result = await idx.query(pid: 11, at: base.addingTimeInterval(10))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].identityHash, 1)
    }
}
