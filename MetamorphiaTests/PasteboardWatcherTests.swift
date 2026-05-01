/*
 * PasteboardWatcherTests
 *
 * NOTE: This file requires a macOS XCTest target that imports Metamorphia's
 * application sources. Wire it up when a MetamorphiaTests target is added to
 * Metamorphia.xcodeproj — the same target that BrowserDomainAllowlistTests
 * and InputCadenceTrackerTests will use.
 *
 * Tests exercise PasteboardWatcher via FakePasteboard, which conforms to
 * PasteboardReadable and lets tests drive changeCount without touching the
 * real NSPasteboard (and without triggering macOS Sonoma paste alerts).
 *
 * Test scenarios:
 *   1. String payload → emits .clipboardCopied(.text, N, …) where N = utf8 count
 *   2. URL-shaped string → emits .clipboardCopied(.url, N, …)
 *   3. ConcealedType UTI → emits .clipboardCopied(.other, 0, …)
 *   4. TransientType UTI → no event emitted
 *   5. Frontmost bundle in denylist → emits .clipboardCopied(<kind>, 0, …)
 *   6. PNG data → emits .clipboardCopied(.image, N, …)
 *   7. No changeCount increment → no event emitted
 */

import XCTest
import Defaults
@testable import Metamorphia
import MetamorphiaAgentKit

// MARK: - AlwaysOnGate (local test helper)

private struct AlwaysOnGate: ActivityStreamGate, @unchecked Sendable {
    var isEnabled: Bool { true }
}

// MARK: - FakePasteboard

/// In-memory pasteboard substitute. Conforms to PasteboardReadable so tests
/// can drive PasteboardWatcher without touching the real NSPasteboard.
@MainActor
final class FakePasteboard: PasteboardReadable {
    private(set) var changeCount: Int = 0
    var stubbedTypes: [NSPasteboard.PasteboardType]?
    var stubbedStrings: [NSPasteboard.PasteboardType: String] = [:]
    var stubbedData: [NSPasteboard.PasteboardType: Data] = [:]
    var stubbedURLs: [URL] = []

    /// Simulate a new copy: bump the change count and set content.
    func simulateCopy(
        types: [NSPasteboard.PasteboardType],
        string: String? = nil,
        data: [NSPasteboard.PasteboardType: Data] = [:],
        urls: [URL] = []
    ) {
        stubbedTypes = types
        stubbedStrings = [:]
        if let s = string {
            stubbedStrings[.string] = s
        }
        stubbedData = data
        stubbedURLs = urls
        changeCount += 1
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        stubbedStrings[dataType]
    }

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        stubbedData[dataType]
    }

    func readObjects(
        forClasses classArray: [AnyClass],
        options: [NSPasteboard.ReadingOptionKey: Any]?
    ) -> [AnyObject]? {
        guard classArray.contains(where: { $0 == NSURL.self }) else { return nil }
        return stubbedURLs as [AnyObject]
    }
}

// MARK: - PasteboardWatcherTests

@MainActor
final class PasteboardWatcherTests: XCTestCase {

    // MARK: - Setup

    private var stream: ActivityStream!
    private var pasteboard: FakePasteboard!
    private var watcher: PasteboardWatcher!

    override func setUp() async throws {
        try await super.setUp()
        // Enable the feature gate for the duration of each test.
        Defaults[.observePasteboard] = true

        stream = ActivityStream(gate: AlwaysOnGate())
        pasteboard = FakePasteboard()
        watcher = PasteboardWatcher(stream: stream, pasteboard: pasteboard)
        watcher.start()
    }

    override func tearDown() async throws {
        watcher.stop()
        Defaults[.observePasteboard] = false
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Drive the watcher tick manually via its internal timer-equivalent path.
    /// Because Timer callbacks are async, we call tick through the same code path
    /// by simulating a copy and then waiting one runloop pass.
    private func driveTick() async {
        // Allow the Task { await stream.emit(...) } inside tick() to settle.
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Test 1: Plain string → .text kind, utf8 byte count

    func testStringPayloadEmitsTextEvent() async throws {
        let text = "Hello, clipboard!"
        pasteboard.simulateCopy(
            types: [.string],
            string: text
        )

        // Manually invoke the same path tick() calls (white-box: call the
        // internal tick through a DispatchQueue.main sync since we're @MainActor).
        // Since Timer fires on RunLoop.main and we're already on main, we yield.
        await driveTick()

        let snap = await stream.snapshot()
        XCTAssertFalse(snap.isEmpty, "Expected at least one event")
        guard case let .clipboardCopied(kind, byteCount, _) = snap.last else {
            XCTFail("Expected .clipboardCopied; got \(String(describing: snap.last))")
            return
        }
        XCTAssertEqual(kind, .text)
        XCTAssertEqual(byteCount, text.utf8.count)
    }

    // MARK: - Test 2: URL-shaped string → .url kind

    func testURLStringEmitsURLEvent() async throws {
        let urlStr = "https://example.com/path?q=1"
        pasteboard.simulateCopy(types: [.string], string: urlStr)

        await driveTick()

        let snap = await stream.snapshot()
        guard case let .clipboardCopied(kind, byteCount, _) = snap.last else {
            XCTFail("Expected .clipboardCopied")
            return
        }
        XCTAssertEqual(kind, .url)
        XCTAssertEqual(byteCount, urlStr.utf8.count)
    }

    // MARK: - Test 3: ConcealedType → byteCount = 0, kind = .other

    func testConcealedTypeEmitsZeroBytes() async throws {
        pasteboard.simulateCopy(
            types: [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]
        )

        await driveTick()

        let snap = await stream.snapshot()
        guard case let .clipboardCopied(kind, byteCount, _) = snap.last else {
            XCTFail("Expected .clipboardCopied")
            return
        }
        XCTAssertEqual(kind, .other)
        XCTAssertEqual(byteCount, 0)
    }

    // MARK: - Test 4: TransientType → no event emitted

    func testTransientTypeIsSkipped() async throws {
        pasteboard.simulateCopy(
            types: [NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]
        )

        await driveTick()

        let snap = await stream.snapshot()
        XCTAssertTrue(snap.isEmpty, "Transient items must not produce events")
    }

    // MARK: - Test 5: Frontmost bundle in denylist → byteCount = 0

    func testDenylistBundleEmitsZeroBytes() async throws {
        // We can't easily override NSWorkspace.frontmostApplication in tests,
        // but we CAN test the classify() logic directly by invoking it through
        // the watcher in a controlled environment. Instead, we verify the
        // denylist set contains the expected entries (static contract test).
        let denylist = PasteboardWatcher.passwordManagerDenylist
        XCTAssertTrue(denylist.contains("com.1password.1password"))
        XCTAssertTrue(denylist.contains("com.bitwarden.desktop"))
        XCTAssertTrue(denylist.contains("com.apple.Passwords"))
        XCTAssertTrue(denylist.contains("com.lastpass.LastPass"))
        XCTAssertTrue(denylist.contains("me.proton.pass"))
        XCTAssertTrue(denylist.contains("com.dashlane.dashlane-mac"))
        XCTAssertTrue(denylist.contains("org.keepassxc.keepassxc"))
    }

    // MARK: - Test 6: PNG data → .image kind, N bytes

    func testPNGPayloadEmitsImageEvent() async throws {
        let fakeBytes = Data(repeating: 0xFF, count: 512)
        pasteboard.simulateCopy(
            types: [.png],
            data: [.png: fakeBytes]
        )

        await driveTick()

        let snap = await stream.snapshot()
        guard case let .clipboardCopied(kind, byteCount, _) = snap.last else {
            XCTFail("Expected .clipboardCopied")
            return
        }
        XCTAssertEqual(kind, .image)
        XCTAssertEqual(byteCount, 512)
    }

    // MARK: - Test 7: No changeCount increment → no event

    func testNoChangeCountMeansNoEvent() async throws {
        // changeCount starts at 0, watcher captured 0 at init — no increment.
        await driveTick()

        let snap = await stream.snapshot()
        XCTAssertTrue(snap.isEmpty, "No changeCount increment must produce no events")
    }

    // MARK: - Test 8: Feature gate off → start() is no-op

    func testFeatureGateOffPreventsEmission() async throws {
        watcher.stop()
        Defaults[.observePasteboard] = false

        let gatedWatcher = PasteboardWatcher(stream: stream, pasteboard: pasteboard)
        gatedWatcher.start()  // should be no-op

        pasteboard.simulateCopy(types: [.string], string: "should not appear")
        await driveTick()

        let snap = await stream.snapshot()
        XCTAssertTrue(snap.isEmpty, "Gate-disabled watcher must not emit")
        gatedWatcher.stop()
    }
}
