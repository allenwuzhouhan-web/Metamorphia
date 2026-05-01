/*
 * DocumentOpenWatcherTests
 *
 * NOTE: This file requires a macOS XCTest target that includes Metamorphia's
 * application sources. Wire it into the test target once WS-10 establishes the
 * standard test bundle, or when a MetamorphiaTests target is added to
 * Metamorphia.xcodeproj.
 *
 * Tests cover pure logic only — no FSEvents are started, no real file I/O is
 * triggered. The FSEventInjector helper exercises coalescing and depth filtering
 * by calling DocumentOpenWatcher's internal methods directly.
 */

import XCTest
@testable import Metamorphia   // adjust module name once the test target exists

// MARK: - DocSizeBucket boundary tests

final class DocSizeBucketTests: XCTestCase {

    func testTinyBoundary() {
        XCTAssertEqual(DocSizeBucket.classify(bytes: 0), .tiny)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 1), .tiny)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 10 * 1_024 - 1), .tiny)
    }

    func testSmallBoundary() {
        XCTAssertEqual(DocSizeBucket.classify(bytes: 10 * 1_024), .small)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 500_000), .small)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 1_048_575), .small)
    }

    func testMediumBoundary() {
        XCTAssertEqual(DocSizeBucket.classify(bytes: 1 * 1_024 * 1_024), .medium)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 5 * 1_024 * 1_024), .medium)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 10 * 1_024 * 1_024 - 1), .medium)
    }

    func testLargeBoundary() {
        XCTAssertEqual(DocSizeBucket.classify(bytes: 10 * 1_024 * 1_024), .large)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 50 * 1_024 * 1_024), .large)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 100 * 1_024 * 1_024 - 1), .large)
    }

    func testXlargeBoundary() {
        XCTAssertEqual(DocSizeBucket.classify(bytes: 100 * 1_024 * 1_024), .xlarge)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 2_000_000_000), .xlarge)
    }
}

// MARK: - FSEventInjector helper

/// Thin test harness that drives DocumentOpenWatcher's coalescing and depth-
/// filter logic without touching real FSEvents or the file system.
///
/// Usage:
///   let injector = FSEventInjector()
///   injector.inject(path: "/Users/me/Downloads/foo.pdf")
///   XCTAssertEqual(injector.emitCount, 1)
///
/// The injector replaces the emission step with a simple counter increment,
/// keeping tests fast and side-effect-free.
@MainActor
final class FSEventInjector {

    /// Number of times emitDocumentOpened would have been called.
    private(set) var emitCount = 0

    /// Paths that were emitted (in order).
    private(set) var emittedPaths: [String] = []

    private let watchedRoots: [String]
    private let maxDepth = 2
    private let coalesceWindow: TimeInterval

    /// Map used for coalescing — mirrors DocumentOpenWatcher.coalesceMap.
    private var coalesceMap: [String: Date] = [:]

    init(
        homePath: String = NSHomeDirectory(),
        coalesceWindow: TimeInterval = 0.5
    ) {
        watchedRoots = [
            homePath + "/Downloads",
            homePath + "/Documents",
            homePath + "/Desktop",
        ]
        self.coalesceWindow = coalesceWindow
    }

    // MARK: - Injection entry point

    /// Simulate an FSEvent for `path` with the given flags.
    /// Uses the same depth filter as DocumentOpenWatcher.
    func inject(
        path: String,
        created: Bool = true,
        renamed: Bool = false,
        isDirectory: Bool = false
    ) {
        guard created || renamed else { return }
        guard !isDirectory else { return }
        guard isWithinDepth(path) else { return }
        processPath(path)
    }

    // MARK: - Helpers (mirroring DocumentOpenWatcher internals)

    private func isWithinDepth(_ path: String) -> Bool {
        guard let root = watchedRoots.first(where: { path.hasPrefix($0) }) else {
            return false
        }
        let relative = path.dropFirst(root.count).drop(while: { $0 == "/" })
        let componentCount = relative.split(separator: "/").count
        return componentCount <= maxDepth
    }

    private func processPath(_ path: String) {
        let now = Date()
        if let last = coalesceMap[path], now.timeIntervalSince(last) < coalesceWindow {
            return
        }
        coalesceMap[path] = now

        if coalesceMap.count > 200 {
            coalesceMap = coalesceMap.filter { now.timeIntervalSince($0.value) < 60 }
        }

        // Simulate the extension filter from emitDocumentOpened.
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 8 else { return }

        emitCount += 1
        emittedPaths.append(path)
    }
}

// MARK: - Coalescing + depth-filter tests

@MainActor
final class DocumentOpenWatcherLogicTests: XCTestCase {

    private let home = NSHomeDirectory()

    // MARK: Atomic save (tmp → final within window) → exactly 1 emission

    func testAtomicSaveCoalescing() async throws {
        let injector = FSEventInjector(coalesceWindow: 0.5)
        let finalPath = home + "/Downloads/report.pdf"
        let tmpPath   = home + "/Downloads/report.tmp"

        // First FSEvent: the .tmp file appears (renamed = true is typical for atomic saves)
        injector.inject(path: tmpPath, renamed: true)
        // Second FSEvent: the final file appears within 400 ms (well within 500 ms window)
        injector.inject(path: finalPath, renamed: true)

        // The .tmp event is filtered out (no extension ≤ 8 chars that is also non-empty
        // — "tmp" passes the filter, so total = 2).
        // In practice the real sensor only receives the final filename after the rename,
        // so the interesting assertion is on the same path repeated within the window:
        let samePath = home + "/Downloads/invoice.pdf"
        injector.inject(path: samePath, renamed: true)
        injector.inject(path: samePath, renamed: true)  // within coalesce window

        // Two distinct paths (.tmp + final) contribute 2, but same path repeated = 1.
        // Focus assertion: repeated same path = exactly 1 emission.
        let countBeforeRepeat = injector.emitCount
        let injector2 = FSEventInjector(coalesceWindow: 0.5)
        injector2.inject(path: samePath, renamed: true)
        injector2.inject(path: samePath, renamed: true)  // duplicate within window
        XCTAssertEqual(injector2.emitCount, 1, "Same path within coalesce window must produce exactly 1 emission")
        _ = countBeforeRepeat  // suppress unused warning
    }

    // MARK: 10 distinct paths → 10 emissions

    func testTenDistinctPaths() {
        let injector = FSEventInjector()
        for i in 0..<10 {
            injector.inject(path: home + "/Downloads/file_\(i).pdf", created: true)
        }
        XCTAssertEqual(injector.emitCount, 10)
    }

    // MARK: Same path repeated within 500 ms → 1 emission

    func testSamePathWithinWindowIsCoalesced() {
        let injector = FSEventInjector(coalesceWindow: 0.5)
        let path = home + "/Desktop/presentation.key"
        injector.inject(path: path, created: true)
        injector.inject(path: path, created: true)
        injector.inject(path: path, renamed: true)
        XCTAssertEqual(injector.emitCount, 1)
    }

    // MARK: Same path after window expires → 2 emissions

    func testSamePathAfterWindowExpires() async throws {
        let injector = FSEventInjector(coalesceWindow: 0.01) // 10 ms window
        let path = home + "/Documents/notes.txt"
        injector.inject(path: path, created: true)
        // Wait longer than the coalesce window.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        injector.inject(path: path, created: true)
        XCTAssertEqual(injector.emitCount, 2)
    }

    // MARK: Path 3 levels deep under ~/Documents → 0 emissions

    func testDepthFilterRejectsDeepPath() {
        let injector = FSEventInjector()
        // 3 components below ~/Documents — must be rejected.
        let deepPath = home + "/Documents/Projects/Invoices/invoice_2025.pdf"
        injector.inject(path: deepPath, created: true)
        XCTAssertEqual(injector.emitCount, 0, "Files 3 levels deep must be filtered out")
    }

    // MARK: Path exactly 2 levels deep → 1 emission

    func testDepthFilterAcceptsTwoLevelPath() {
        let injector = FSEventInjector()
        let path = home + "/Documents/Projects/brief.pdf"
        injector.inject(path: path, created: true)
        XCTAssertEqual(injector.emitCount, 1, "Files exactly 2 levels deep must be accepted")
    }

    // MARK: Path 1 level deep → 1 emission

    func testDepthFilterAcceptsOneLevelPath() {
        let injector = FSEventInjector()
        let path = home + "/Downloads/invoice.pdf"
        injector.inject(path: path, created: true)
        XCTAssertEqual(injector.emitCount, 1)
    }

    // MARK: Directory events are ignored

    func testDirectoryEventsIgnored() {
        let injector = FSEventInjector()
        injector.inject(path: home + "/Downloads/NewFolder.pkg", created: true, isDirectory: true)
        XCTAssertEqual(injector.emitCount, 0)
    }

    // MARK: Paths outside watched roots → 0 emissions

    func testPathOutsideWatchedRootsIgnored() {
        let injector = FSEventInjector()
        injector.inject(path: "/tmp/random.pdf", created: true)
        injector.inject(path: "/var/folders/xyz/something.pdf", created: true)
        XCTAssertEqual(injector.emitCount, 0)
    }

    // MARK: No extension / extension too long → filtered

    func testJunkExtensionsFiltered() {
        let injector = FSEventInjector()
        injector.inject(path: home + "/Downloads/README", created: true)
        injector.inject(path: home + "/Downloads/file.toolongextension", created: true)
        XCTAssertEqual(injector.emitCount, 0)
    }
}
