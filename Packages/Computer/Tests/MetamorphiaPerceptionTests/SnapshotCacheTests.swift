import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

/// Rank 2 — Per-session snapshot cache for delta encoding.
///
/// Covers:
/// - Round-trip store/fetch
/// - Reset drops entry
/// - Per-session sequence counters
/// - Session isolation
/// - Idle-timeout eviction
/// - LRU eviction when `maxSessions` exceeded
/// - Concurrent-store safety
final class SnapshotCacheTests: XCTestCase {

    // MARK: - 1. store + fetch round-trip

    func testStore_then_fetch_roundTrips() async {
        let cache = SnapshotCache(maxSessions: 4, idleTimeout: 60)
        let map = makeMap(label: "a")
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        await cache.store(sessionID: "s1", map: map, tiers: tiers)
        let hit = await cache.fetch(sessionID: "s1")
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.map.elements.first?.label, "a")
        XCTAssertEqual(hit?.tiers[ElementRef(index: 1)], .label)
    }

    // MARK: - 2. reset clears the entry

    func testReset_clearsEntry() async {
        let cache = SnapshotCache(maxSessions: 4, idleTimeout: 60)
        let map = makeMap(label: "a")
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        await cache.store(sessionID: "s1", map: map, tiers: tiers)
        await cache.reset(sessionID: "s1")
        let hit = await cache.fetch(sessionID: "s1")
        XCTAssertNil(hit)
    }

    // MARK: - 3. nextSequenceNumber increments per session

    func testSequenceNumber_incrementsPerSession() async {
        let cache = SnapshotCache(maxSessions: 4, idleTimeout: 60)
        let s0 = await cache.nextSequenceNumber(for: "alpha")
        let s1 = await cache.nextSequenceNumber(for: "alpha")
        let s2 = await cache.nextSequenceNumber(for: "alpha")
        XCTAssertEqual(s0, 0)
        XCTAssertEqual(s1, 1)
        XCTAssertEqual(s2, 2)
        // Distinct session starts at 0.
        let other = await cache.nextSequenceNumber(for: "beta")
        XCTAssertEqual(other, 0)
    }

    // MARK: - 4. Sessions are isolated

    func testSessions_isolated() async {
        let cache = SnapshotCache(maxSessions: 4, idleTimeout: 60)
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        await cache.store(sessionID: "s1", map: makeMap(label: "in-s1"), tiers: tiers)
        await cache.store(sessionID: "s2", map: makeMap(label: "in-s2"), tiers: tiers)
        let hit1 = await cache.fetch(sessionID: "s1")
        let hit2 = await cache.fetch(sessionID: "s2")
        XCTAssertEqual(hit1?.map.elements.first?.label, "in-s1")
        XCTAssertEqual(hit2?.map.elements.first?.label, "in-s2")
    }

    // MARK: - 5. Idle timeout evicts old entries

    func testIdleTimeout_evictsOldEntries() async {
        // Idle timeout of 1 second. Sleep 1.5s, then prune. Entry should
        // be gone.
        let cache = SnapshotCache(maxSessions: 16, idleTimeout: 1)
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        await cache.store(sessionID: "expiring", map: makeMap(label: "x"), tiers: tiers)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await cache.pruneIdleSessions()
        let hit = await cache.fetch(sessionID: "expiring")
        XCTAssertNil(hit, "entry should be evicted after idle timeout")
    }

    // MARK: - 6. maxSessions evicts LRU

    func testMaxSessions_evictsLRU() async {
        let cache = SnapshotCache(maxSessions: 2, idleTimeout: 60)
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        await cache.store(sessionID: "a", map: makeMap(label: "a"), tiers: tiers)
        await cache.store(sessionID: "b", map: makeMap(label: "b"), tiers: tiers)
        // Touch 'a' so it's more recent than 'b'.
        _ = await cache.fetch(sessionID: "a")
        // Now store 'c' — cap is 2, so the least-recent by storeOrder
        // (which is 'b') should be evicted.
        await cache.store(sessionID: "c", map: makeMap(label: "c"), tiers: tiers)
        let hitA = await cache.fetch(sessionID: "a")
        let hitB = await cache.fetch(sessionID: "b")
        let hitC = await cache.fetch(sessionID: "c")
        XCTAssertNotNil(hitA, "session a should survive")
        XCTAssertNil(hitB, "session b is LRU and should be evicted")
        XCTAssertNotNil(hitC, "session c is freshly stored")
    }

    // MARK: - 7. Concurrent stores for different sessions succeed

    func testConcurrency_parallelStoresSafely() async {
        let cache = SnapshotCache(maxSessions: 64, idleTimeout: 60)
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        // 32 concurrent stores across different session keys.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<32 {
                group.addTask {
                    await cache.store(
                        sessionID: "s\(i)",
                        map: self.makeMap(label: "m\(i)"),
                        tiers: tiers
                    )
                }
            }
        }
        for i in 0..<32 {
            let hit = await cache.fetch(sessionID: "s\(i)")
            XCTAssertNotNil(hit, "s\(i) should be stored")
            XCTAssertEqual(hit?.map.elements.first?.label, "m\(i)")
        }
    }

    // MARK: - Fixture

    func makeMap(label: String) -> ScreenMap {
        let element = ScreenElement(
            ref: ElementRef(index: 1),
            role: .button, subrole: "",
            label: label, value: "",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 30),
            clickPoint: CGPoint(x: 40, y: 15),
            state: .enabled, actions: [.press],
            parentRef: nil, depth: 0,
            source: .accessibility, confidence: 1.0,
            appBundleID: "com.test", windowIndex: 0, displayIndex: 0
        )
        return ScreenMap(
            timestamp: Date(),
            captureMs: 1,
            displays: [DisplayInfo(
                id: 1, index: 0, name: "Main", origin: .zero,
                width: 1920, height: 1080, scale: 2, isMain: true
            )],
            focusedApp: AppInfo(name: "Test", bundleID: "com.test", pid: 1),
            windows: [WindowInfo(
                index: 0, appName: "Test", appBundleID: "com.test",
                title: "Win", bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                isFocused: true, layer: 0, displayIndex: 0
            )],
            elements: [element],
            navigation: nil,
            safety: .empty,
            metadata: CaptureMetadata(
                axCoveragePercent: 1, ocrUsed: false,
                elementCount: 1, interactiveCount: 1,
                offScreenHint: nil
            )
        )
    }
}
