import XCTest
@testable import MetamorphiaAgentKit

/// Tests for `FileMemoryStore` — disk round-trip, LTP on recall, eviction by
/// strength, and decay-on-load. Mirrors the tempfile pattern used by
/// `Phase2cMiddlewareTests.swift`.
final class FileMemoryStoreTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FileMemoryStoreTests")
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Round-trip

    func testAddAndRecallReturnsRecord() {
        let url = tempURL()
        defer { cleanup(url) }
        let store = FileMemoryStore(storageURL: url, writeDebounce: 0.01)
        store.add(MemoryInput(
            content: "User prefers Safari as their browser",
            category: .preference,
            keywords: ["safari", "browser"]
        ))

        let hits = store.recall(query: "safari", category: .preference, limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.content, "User prefers Safari as their browser")
    }

    func testRecallIsEmptyWhenCategoryMismatch() {
        let url = tempURL()
        defer { cleanup(url) }
        let store = FileMemoryStore(storageURL: url, writeDebounce: 0.01)
        store.add(MemoryInput(content: "x", category: .fact, keywords: ["x"]))

        let hits = store.recall(query: "x", category: .preference, limit: 5)
        XCTAssertTrue(hits.isEmpty)
    }

    func testEmptyQueryReturnsAllInCategoryUpToLimit() {
        let url = tempURL()
        defer { cleanup(url) }
        let store = FileMemoryStore(storageURL: url, writeDebounce: 0.01)
        for i in 0..<5 {
            store.add(MemoryInput(content: "n\(i)", category: .note, keywords: []))
        }
        let hits = store.recall(query: "", category: .note, limit: 3)
        XCTAssertEqual(hits.count, 3)
    }

    // MARK: - LTP on recall

    func testRecallReinforcesStrength() {
        let url = tempURL()
        defer { cleanup(url) }
        let store = FileMemoryStore(storageURL: url, writeDebounce: 0.01)
        store.add(MemoryInput(content: "anchor", category: .fact, keywords: ["anchor"]))

        let initialId = store.recall(query: "anchor", category: .fact, limit: 1).first?.id
        XCTAssertNotNil(initialId)
        let baseline = store.strengthForTesting(id: initialId!) ?? 0
        // Reinforce a few more times.
        for _ in 0..<5 {
            _ = store.recall(query: "anchor", category: .fact, limit: 1)
        }
        let after = store.strengthForTesting(id: initialId!) ?? 0
        XCTAssertGreaterThan(after, baseline,
                             "repeated recall should increase synaptic strength")
    }

    // MARK: - Persistence

    func testReopenLoadsRecordsFromDisk() {
        let url = tempURL()
        defer { cleanup(url) }
        let firstStore = FileMemoryStore(storageURL: url, writeDebounce: 0.01)
        firstStore.add(MemoryInput(content: "persisted", category: .skill, keywords: ["persisted"]))
        firstStore.flushForTesting()

        let secondStore = FileMemoryStore(storageURL: url, writeDebounce: 0.01)
        let hits = secondStore.recall(query: "persisted", category: .skill, limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.content, "persisted")
    }

    func testDebouncedWriteFlushesWithinWindow() {
        let url = tempURL()
        defer { cleanup(url) }
        let store = FileMemoryStore(storageURL: url, writeDebounce: 0.05)
        for i in 0..<10 {
            store.add(MemoryInput(content: "r\(i)", category: .note, keywords: ["r\(i)"]))
        }
        // Wait past debounce window for the timer to fire.
        let exp = expectation(description: "debounced write fires")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        let reloaded = FileMemoryStore(storageURL: url, writeDebounce: 0.05)
        XCTAssertEqual(reloaded.count, 10)
    }

    // MARK: - Eviction

    func testEvictionDropsWeakestWhenOverCapacity() {
        let url = tempURL()
        defer { cleanup(url) }
        let store = FileMemoryStore(storageURL: url, maxRecords: 5, writeDebounce: 0.01)
        // Add 5 distinct records; reinforce one of them several times.
        for i in 0..<5 {
            store.add(MemoryInput(content: "m\(i)", category: .fact, keywords: ["m\(i)"]))
        }
        for _ in 0..<10 {
            _ = store.recall(query: "m0", category: .fact, limit: 1)
        }
        // Now overflow capacity by adding a 6th. The reinforced m0 should
        // survive; the weakest of the others should be dropped.
        store.add(MemoryInput(content: "m_new", category: .fact, keywords: ["m_new"]))

        XCTAssertEqual(store.count, 5)
        let surviving = store.recall(query: "m0", category: .fact, limit: 5)
        XCTAssertEqual(surviving.first?.content, "m0",
                       "the reinforced record must survive strength-based eviction")
    }

    // MARK: - Decay on load

    func testDecayAppliedOnLoad() throws {
        let url = tempURL()
        defer { cleanup(url) }

        // Hand-craft a JSON file with a 30-day-old record at strength 0.5.
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86_400)
        let json = """
        [{
          "id": "00000000-0000-0000-0000-000000000001",
          "content": "old",
          "category": "fact",
          "keywords": ["old"],
          "timestamp": \(thirtyDaysAgo.timeIntervalSinceReferenceDate),
          "strength": 0.5,
          "lastAccessed": \(thirtyDaysAgo.timeIntervalSinceReferenceDate),
          "accessCount": 0,
          "createdAt": \(thirtyDaysAgo.timeIntervalSinceReferenceDate)
        }]
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.data(using: .utf8)!.write(to: url)

        let store = FileMemoryStore(storageURL: url, writeDebounce: 0.01)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let strength = store.strengthForTesting(id: id) ?? 0
        // tau_semantic = 14d, so 30d decay → 0.5 * exp(-30/14) ≈ 0.058.
        XCTAssertEqual(strength, 0.5 * exp(-30.0 / 14.0), accuracy: 0.01)
    }
}
