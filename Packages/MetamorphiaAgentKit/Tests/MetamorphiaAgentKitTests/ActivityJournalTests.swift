import XCTest
@testable import MetamorphiaAgentKit

// MARK: - Mock stream

/// Minimal ``ActivityStreamWritable`` for tests — no Combine, no actor overhead.
final class MockActivityStream: ActivityStreamWritable {
    private var writers: [(@Sendable (ActivityEvent) -> Void)] = []

    nonisolated func attachWriter(_ writer: @Sendable @escaping (ActivityEvent) -> Void) {
        writers.append(writer)
    }

    func emit(_ event: ActivityEvent) {
        for w in writers { w(event) }
    }
}

// MARK: - ActivityJournalTests

final class ActivityJournalTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeJournal(persistence: SecurePersistence? = nil) -> ActivityJournal {
        ActivityJournal(directoryOverride: tempDir)
    }

    private func sampleEvent(at date: Date = .now) -> ActivityEvent {
        .focusChanged(bundleID: "com.test.App", appName: "TestApp", windowTitle: nil, pid: 1234, at: date)
    }

    /// Block until the debounce window clears plus a safety margin.
    private func waitForDebounce(extra: TimeInterval = 1.0) {
        Thread.sleep(forTimeInterval: 4.0 + extra)
    }

    // MARK: - testRecordAndRetrieve

    func testRecordAndRetrieve() throws {
        let journal = makeJournal()
        let stream = MockActivityStream()
        journal.startInsecure(stream: stream)

        let now = Date()
        for i in 0..<5 {
            journal.record(.focusChanged(
                bundleID: "com.test.App\(i)",
                appName: "App\(i)",
                windowTitle: nil,
                pid: Int32(1000 + i),
                at: now.addingTimeInterval(Double(i))
            ))
        }

        journal.forceFlushSync()

        let retrieved = journal.events(on: now)
        XCTAssertEqual(retrieved.count, 5, "Should retrieve exactly 5 events after force flush")

        // Verify order is preserved by checking bundle IDs.
        for (idx, event) in retrieved.enumerated() {
            if case .focusChanged(let bundleID, _, _, _, _) = event {
                XCTAssertEqual(bundleID, "com.test.App\(idx)")
            } else {
                XCTFail("Unexpected event type at index \(idx)")
            }
        }
    }

    // MARK: - testDebouncedWrite

    func testDebouncedWrite() throws {
        let journal = makeJournal()
        let stream = MockActivityStream()
        journal.startInsecure(stream: stream)

        let now = Date()

        // Record 10 events quickly.
        for i in 0..<10 {
            journal.record(.inputIdle(idleSeconds: i, at: now.addingTimeInterval(Double(i) * 0.01)))
        }

        // Immediately after — no flush should have occurred yet.
        let flushBeforeWait = journal.flushCount
        XCTAssertEqual(flushBeforeWait, 0, "No flush should have occurred within the debounce window")

        // Wait for debounce to fire.
        waitForDebounce()

        let flushAfterWait = journal.flushCount
        XCTAssertEqual(flushAfterWait, 1, "Exactly one flush should have occurred after the debounce window")
    }

    // MARK: - testDailyRotation

    func testDailyRotation() throws {
        let journal = makeJournal()
        journal.dailySizeCap = 100 * 1_024 * 1_024  // ensure cap doesn't interfere
        let stream = MockActivityStream()
        journal.startInsecure(stream: stream)

        // Use recent dates (yesterday and today) so the retention pruner does
        // not delete them during the rotation flush.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        journal.record(.meetingStarted(app: "Zoom",  at: yesterday.addingTimeInterval(3600)))
        journal.record(.meetingStarted(app: "Teams", at: today.addingTimeInterval(3600)))

        journal.forceFlushSync()

        let todayKey     = isoKey(today)
        let yesterdayKey = isoKey(yesterday)

        let fileYesterday = tempDir.appendingPathComponent("activity-\(yesterdayKey).json")
        let fileToday     = tempDir.appendingPathComponent("activity-\(todayKey).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileYesterday.path),
                      "Expected file for \(yesterdayKey)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileToday.path),
                      "Expected file for \(todayKey)")
    }

    // MARK: - testRetentionPrune

    func testRetentionPrune() throws {
        let fm = FileManager.default

        // Seed 10 fake files dated 1..10 days ago.
        for daysAgo in 1...10 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            let key = isoKey(date)
            let url = tempDir.appendingPathComponent("activity-\(key).json")
            try "[]".data(using: .utf8)!.write(to: url)
        }

        // Start journal — pruning runs on startup.
        let journal = ActivityJournal(directoryOverride: tempDir)
        let stream = MockActivityStream()
        journal.retentionDays = 7
        journal.startInsecure(stream: stream)

        // Give pruning a moment (it's synchronous on startup but inside queue.sync).
        Thread.sleep(forTimeInterval: 0.2)

        let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let remaining = contents.filter { $0.pathExtension == "json" }

        for url in remaining {
            let name = url.deletingPathExtension().lastPathComponent
            let key = String(name.dropFirst("activity-".count))
            // Keys for days 8, 9, 10 ago should be gone.
            let daysAgo = daysAgoFromKey(key)
            XCTAssertLessThanOrEqual(daysAgo, 7,
                "File \(url.lastPathComponent) is older than retention cap and should have been pruned")
        }
    }

    // MARK: - testMidWriteKillTolerance

    func testMidWriteKillTolerance() throws {
        // Write a garbage .tmp file with the correct naming convention.
        let tmpURL = tempDir.appendingPathComponent("activity-\(isoKey(Date())).json.tmp")
        try "GARBAGE DATA".data(using: .utf8)!.write(to: tmpURL)

        // Write a real .enc file to ensure it's untouched.
        let realURL = tempDir.appendingPathComponent("activity-\(isoKey(Date())).json")
        try "[]".data(using: .utf8)!.write(to: realURL)
        let modBefore = try FileManager.default
            .attributesOfItem(atPath: realURL.path)[.modificationDate] as? Date

        // Start journal — discardOrphanedTmps should remove the .tmp.
        let journal = ActivityJournal(directoryOverride: tempDir)
        let stream = MockActivityStream()
        journal.startInsecure(stream: stream)
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path),
                       ".tmp file should have been discarded on startup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: realURL.path),
                      "Real .json file should be untouched")

        let modAfter = try FileManager.default
            .attributesOfItem(atPath: realURL.path)[.modificationDate] as? Date
        XCTAssertEqual(modBefore, modAfter, "Real file modification date should not change")
    }

    // MARK: - testSizeCapHalts

    func testSizeCapHalts() throws {
        let journal = makeJournal()
        // Tiny cap — 1 KB.
        journal.dailySizeCap = 1_024
        let stream = MockActivityStream()
        journal.startInsecure(stream: stream)

        let now = Date()
        // Build an event with a long title to inflate payload size.
        let longTitle = String(repeating: "x", count: 100)

        // Record enough events to exceed 1 KB when JSON-encoded.
        for i in 0..<30 {
            journal.record(.focusChanged(
                bundleID: "com.test.App",
                appName: longTitle,
                windowTitle: longTitle,
                pid: Int32(i),
                at: now.addingTimeInterval(Double(i))
            ))
        }

        journal.forceFlushSync()

        // Verify subsequent records are silently dropped.
        let countAfterCap = journal.events(on: now).count
        // The cap triggers once the flush finds the JSON exceeds 1 KB.  A
        // second burst of records should be dropped completely.
        let preSecondBurst = countAfterCap
        for i in 100..<130 {
            journal.record(.focusChanged(
                bundleID: "com.test.Drop",
                appName: "Dropped",
                windowTitle: nil,
                pid: Int32(i),
                at: now.addingTimeInterval(Double(i))
            ))
        }
        journal.forceFlushSync()
        let countAfterSecondBurst = journal.events(on: now).count
        XCTAssertEqual(preSecondBurst, countAfterSecondBurst,
                       "Records after the size cap should be silently dropped")
    }

    // MARK: - testPlainJSONFallback

    func testPlainJSONFallback() throws {
        let journal = makeJournal(persistence: nil)
        let stream = MockActivityStream()
        journal.startInsecure(stream: stream)

        journal.record(sampleEvent())
        journal.forceFlushSync()

        let contents = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        )
        let jsonFiles = contents.filter { $0.pathExtension == "json" }
        let encFiles  = contents.filter { $0.pathExtension == "enc" }

        XCTAssertFalse(jsonFiles.isEmpty, "Should have written a .json file when persistence is nil")
        XCTAssertTrue(encFiles.isEmpty,  "Should not have written any .enc files without encryption")
    }

    // MARK: - testStartupReplay

    func testStartupReplay() throws {
        // Seed a .json file with 3 events.
        let events: [ActivityEvent] = [
            .cameraToggled(isActive: true,  at: Date().addingTimeInterval(-300)),
            .cameraToggled(isActive: false, at: Date().addingTimeInterval(-200)),
            .microphoneToggled(isActive: true, at: Date().addingTimeInterval(-100)),
        ]
        let data = try JSONEncoder().encode(events)
        let fileURL = tempDir.appendingPathComponent("activity-\(isoKey(Date())).json")
        try data.write(to: fileURL)

        // Start a fresh journal pointing at the temp dir.
        let journal = ActivityJournal(directoryOverride: tempDir)
        let stream = MockActivityStream()
        journal.startInsecure(stream: stream)
        Thread.sleep(forTimeInterval: 0.2)

        let replayed = journal.replayedEvents()
        XCTAssertEqual(replayed.count, 3,
                       "Should have replayed all 3 events from the seeded file on startup")
    }

    // MARK: - testDisabledGateIsNoOp

    func testDisabledGateIsNoOp() throws {
        let journal = makeJournal()
        let stream = MockActivityStream()
        journal.startInsecure(stream: stream, gate: NeverOnGate())

        for _ in 0..<5 {
            journal.record(sampleEvent())
        }
        journal.forceFlushSync()

        let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        )
        // No events should have been recorded, so no files should have been written.
        let dataFiles = (contents ?? []).filter {
            $0.pathExtension == "json" || $0.pathExtension == "enc"
        }
        XCTAssertTrue(dataFiles.isEmpty,
                      "No data files should exist when the gate is disabled")
    }

    // MARK: - testPayloadsAreRedacted

    func testPayloadsAreRedacted() throws {
        // Strings that must never appear in any serialised output.
        let forbiddenStrings = [
            "https://",
            "clipboard-text-content-here",
        ]

        // Helper that asserts none of the forbidden strings appear in `data`.
        func assertNoLeaks(in data: Data, label: String) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for forbidden in forbiddenStrings {
                XCTAssertFalse(
                    text.contains(forbidden),
                    "\(label) must not contain \"\(forbidden)\""
                )
            }
        }

        // Attempt encrypted path; fall back to insecure if Keychain is unavailable.
        let serviceTag = "testPayloadsAreRedacted-\(UUID().uuidString)"
        let persistence = try? SecurePersistence(serviceTag: serviceTag)

        let journal = ActivityJournal(directoryOverride: tempDir)
        let stream = MockActivityStream()

        if let sp = persistence {
            journal.start(stream: stream, persistence: sp)
        } else {
            journal.startInsecure(stream: stream)
        }

        let now = Date()
        journal.record(.clipboardCopied(kind: .text, byteCount: 42, origin: .local, at: now))
        journal.record(.urlVisited(
            urlHash: "sha256-abc",
            host: "example.com",
            title: "Example Tab",
            browserBundleID: "com.apple.Safari",
            at: now.addingTimeInterval(1)
        ))
        journal.record(.querySubmitted(queryID: UUID(), entityCount: 3, at: now.addingTimeInterval(2)))

        journal.forceFlushSync()

        // Locate the written file.
        let contents = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        )
        let dataFiles = contents.filter {
            $0.pathExtension == "enc" || $0.pathExtension == "json"
        }
        XCTAssertFalse(dataFiles.isEmpty, "At least one data file should have been written")

        for fileURL in dataFiles {
            let raw = try Data(contentsOf: fileURL)

            // Raw bytes must not leak forbidden strings.
            assertNoLeaks(in: raw, label: "raw file \(fileURL.lastPathComponent)")

            // For encrypted files, also verify the decrypted schema is clean.
            if fileURL.pathExtension == "enc", let sp = persistence {
                guard raw.count >= 4 else { continue }
                let length = Int(raw[0]) | (Int(raw[1]) << 8) | (Int(raw[2]) << 16) | (Int(raw[3]) << 24)
                guard raw.count >= 4 + length else { continue }
                let sealedSlice = raw[4..<(4 + length)]
                let decrypted = try sp.decrypt(sealedSlice)
                assertNoLeaks(in: decrypted, label: "decrypted \(fileURL.lastPathComponent)")

                // Sanity: decrypted JSON must still decode as valid events.
                let decoded = try JSONDecoder().decode([ActivityEvent].self, from: decrypted)
                XCTAssertEqual(decoded.count, 3, "Should decode exactly 3 events from encrypted file")
            }
        }
    }

    // MARK: - Private ISO helpers

    private func isoKey(_ date: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.year,  from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day,   from: date)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private func daysAgoFromKey(_ key: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: key) else { return 0 }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
    }
}
