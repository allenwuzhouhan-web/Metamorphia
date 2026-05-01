import XCTest
@testable import MetamorphiaAgentKit

final class ActivityEventTests: XCTestCase {

    // MARK: - Helpers

    private func roundTrip<E: Codable & Equatable>(_ value: E) throws -> E {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(E.self, from: data)
    }

    // MARK: - clipboardCopied (updated signature)

    func testClipboardCopiedRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let event = ActivityEvent.clipboardCopied(
            kind: .text,
            byteCount: 42,
            origin: .remote,
            at: date
        )
        let decoded = try roundTrip(event)
        XCTAssertEqual(event, decoded)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.source, .clipboard)
    }

    func testClipboardCopiedOriginVariants() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_001)
        for origin in [PasteOrigin.local, .remote, .concealed, .denylist] {
            let event = ActivityEvent.clipboardCopied(kind: .image, byteCount: 0, origin: origin, at: date)
            let decoded = try roundTrip(event)
            XCTAssertEqual(decoded, event, "Origin variant \(origin) failed round-trip")
        }
    }

    // MARK: - selectionChanged

    func testSelectionChangedRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_002)
        let event = ActivityEvent.selectionChanged(
            bundleID: "com.apple.TextEdit",
            role: "AXTextArea",
            selectionLength: 128,
            at: date
        )
        let decoded = try roundTrip(event)
        XCTAssertEqual(event, decoded)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.source, .selectionTracker)
    }

    // MARK: - documentOpened

    func testDocumentOpenedRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_003)
        let event = ActivityEvent.documentOpened(
            bundleID: "com.microsoft.Word",
            fileExtension: "docx",
            sizeBucket: .medium,
            at: date
        )
        let decoded = try roundTrip(event)
        XCTAssertEqual(event, decoded)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.source, .documentWatcher)
    }

    func testDocumentOpenedNilBundleIDRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_004)
        let event = ActivityEvent.documentOpened(
            bundleID: nil,
            fileExtension: "pdf",
            sizeBucket: .xlarge,
            at: date
        )
        let decoded = try roundTrip(event)
        XCTAssertEqual(event, decoded)
    }

    // MARK: - DocSizeBucket.classify boundaries

    func testDocSizeBucketBoundaries() {
        // Below 10 KB
        XCTAssertEqual(DocSizeBucket.classify(bytes: 0),          .tiny)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 10_239),      .tiny)
        // 10 KB boundary
        XCTAssertEqual(DocSizeBucket.classify(bytes: 10_240),      .small)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 1_048_575),   .small)
        // 1 MB boundary
        XCTAssertEqual(DocSizeBucket.classify(bytes: 1_048_576),   .medium)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 10_485_759),  .medium)
        // 10 MB boundary
        XCTAssertEqual(DocSizeBucket.classify(bytes: 10_485_760),  .large)
        XCTAssertEqual(DocSizeBucket.classify(bytes: 104_857_599), .large)
        // 100 MB boundary
        XCTAssertEqual(DocSizeBucket.classify(bytes: 104_857_600), .xlarge)
        XCTAssertEqual(DocSizeBucket.classify(bytes: Int64.max),   .xlarge)
    }

    // MARK: - PasteOrigin round-trip

    func testPasteOriginRoundTrip() throws {
        for origin in [PasteOrigin.local, .remote, .concealed, .denylist] {
            let decoded = try roundTrip(origin)
            XCTAssertEqual(decoded, origin)
        }
    }

    // MARK: - timestamp returns at: for all new cases

    func testTimestampAccuracy() {
        let sentinel = Date(timeIntervalSince1970: 9_999_999)

        let cases: [ActivityEvent] = [
            .clipboardCopied(kind: .file, byteCount: 0, origin: .local, at: sentinel),
            .selectionChanged(bundleID: "com.test", role: "AXTextField", selectionLength: 5, at: sentinel),
            .documentOpened(bundleID: nil, fileExtension: "txt", sizeBucket: .tiny, at: sentinel),
        ]

        for event in cases {
            XCTAssertEqual(
                event.timestamp.timeIntervalSince1970,
                sentinel.timeIntervalSince1970,
                accuracy: 0.001,
                "timestamp mismatch for \(event)"
            )
        }
    }
}
