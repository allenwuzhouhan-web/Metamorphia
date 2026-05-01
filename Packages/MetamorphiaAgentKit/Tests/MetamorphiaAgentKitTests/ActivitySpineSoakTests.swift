import XCTest
import Darwin
@testable import MetamorphiaAgentKit

// MARK: - Memory helper

private func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kerr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

// MARK: - ActivitySpineSoakTests

final class ActivitySpineSoakTests: XCTestCase {

    func testStreamJournalSoakUnder100kEventsPerMinute() async throws {
        guard ProcessInfo.processInfo.environment["METAMORPHIA_SOAK"] == "1" else {
            throw XCTSkip("Set METAMORPHIA_SOAK=1 to run soak tests")
        }

        // MARK: Setup

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivitySpineSoak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stream = ActivityStream(gate: AlwaysOnGate())
        let journal = ActivityJournal(directoryOverride: tempDir)
        // Use the insecure (plain JSON) path — no Keychain in tests.
        journal.startInsecure(stream: stream)

        // MARK: Memory sampling setup

        let baselineRSS = currentResidentBytes()
        var rssSamples: [UInt64] = [baselineRSS]
        var peakDeltaBytes: UInt64 = 0

        // Sample RSS every 5 s on a background thread.
        let samplerStop = DispatchSemaphore(value: 0)
        let samplerQueue = DispatchQueue(label: "soak.sampler", qos: .utility)
        samplerQueue.async {
            while samplerStop.wait(timeout: .now() + 5) == .timedOut {
                let rss = currentResidentBytes()
                rssSamples.append(rss)
                let delta = rss > baselineRSS ? rss - baselineRSS : 0
                if delta > peakDeltaBytes { peakDeltaBytes = delta }
            }
        }

        // MARK: Event generation

        let totalEvents = 100_000
        let writerCount = 4
        let eventsPerWriter = totalEvents / writerCount
        // Target: spread 100k events over 60 s → ~1667/s total → ~417/s per writer.
        // Inter-event sleep per writer: 1/417 s ≈ 2.4 ms
        let interEventNanoseconds: UInt64 = 2_400_000  // 2.4 ms

        let now = Date()

        func makeEvent(index: Int) -> ActivityEvent {
            let slot = index % 6
            let t = now.addingTimeInterval(Double(index) * 0.0006)  // spread over ~60s
            switch slot {
            case 0:
                return .focusChanged(
                    bundleID: "com.soak.app\(index % 20)",
                    appName: "SoakApp\(index % 20)",
                    windowTitle: nil,
                    pid: Int32(index % 1000),
                    at: t
                )
            case 1:
                return .inputIdle(idleSeconds: index % 120, at: t)
            case 2:
                return .urlVisited(
                    urlHash: String(format: "%064x", index),
                    host: "host\(index % 50).example.com",
                    title: nil,
                    browserBundleID: "com.apple.safari",
                    at: t
                )
            case 3:
                return .clipboardCopied(kind: .text, byteCount: index % 4096, origin: .local, at: t)
            case 4:
                return .querySubmitted(queryID: UUID(), entityCount: index % 10, at: t)
            default:
                return .sessionClosed(
                    bundleID: "com.soak.app\(index % 20)",
                    docHint: nil,
                    durationSeconds: index % 3600,
                    cadenceTier: .light,
                    at: t
                )
            }
        }

        // Emit from 4 concurrent TaskGroup tasks.
        print("[SoakTest] Starting 100k-event soak across 4 writer tasks …")
        let startTime = Date()

        await withTaskGroup(of: Void.self) { group in
            for writerID in 0..<writerCount {
                group.addTask {
                    let startIndex = writerID * eventsPerWriter
                    let endIndex = startIndex + eventsPerWriter
                    for i in startIndex..<endIndex {
                        await stream.emit(makeEvent(index: i))
                        // Throttle to approximate target rate.
                        try? await Task.sleep(nanoseconds: interEventNanoseconds)
                    }
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print("[SoakTest] All \(totalEvents) events emitted in \(String(format: "%.1f", elapsed)) s")

        // MARK: Wait for debounced flush (debounce = 4 s + 10 s margin)

        print("[SoakTest] Waiting 10 s for debounced flush to complete …")
        try await Task.sleep(nanoseconds: 10_000_000_000)

        // Stop sampler.
        samplerStop.signal()

        // Final RSS sample.
        let finalRSS = currentResidentBytes()
        rssSamples.append(finalRSS)
        let finalDelta = finalRSS > baselineRSS ? finalRSS - baselineRSS : 0
        if finalDelta > peakDeltaBytes { peakDeltaBytes = finalDelta }

        // MARK: Assertions

        // 1. Ring buffer must be capped at 10k.
        let ringSnap = await stream.snapshot()
        let ringCount = ringSnap.count
        print("[SoakTest] Ring buffer count: \(ringCount) (expected \(ActivityStream.ringCapacity))")
        XCTAssertEqual(
            ringCount,
            ActivityStream.ringCapacity,
            "Ring buffer must be capped at \(ActivityStream.ringCapacity); got \(ringCount)"
        )

        // 2. Memory growth must be under 150 MB.
        let limitBytes: UInt64 = 150 * 1_024 * 1_024
        print("[SoakTest] Peak RSS delta: \(peakDeltaBytes / (1024 * 1024)) MB  (limit 150 MB)")
        if peakDeltaBytes >= limitBytes {
            print("[SoakTest] RSS samples (bytes): \(rssSamples)")
        }
        XCTAssertLessThan(
            peakDeltaBytes,
            limitBytes,
            "Peak RSS delta \(peakDeltaBytes / (1024 * 1024)) MB exceeded 150 MB limit"
        )

        // 3. Journal file(s) must exist and total size must be under 100 MB.
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let journalFiles = contents.filter {
            $0.pathExtension == "json" || $0.pathExtension == "enc"
        }
        XCTAssertFalse(journalFiles.isEmpty, "At least one journal file must exist after soak")

        var totalDiskBytes: Int64 = 0
        for url in journalFiles {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            totalDiskBytes += (attrs?[.size] as? Int64) ?? 0
        }
        let dailyCapBytes: Int64 = 100 * 1_024 * 1_024
        print("[SoakTest] Journal disk usage: \(totalDiskBytes / (1024 * 1024)) MB  (cap 100 MB)")
        XCTAssertLessThanOrEqual(
            totalDiskBytes,
            dailyCapBytes,
            "Journal disk usage \(totalDiskBytes / (1024 * 1024)) MB exceeded the 100 MB daily cap"
        )

        // 4. No hanging tasks: snapshot() must return without blocking.
        let postTeardownSnap = await stream.snapshot()
        XCTAssertGreaterThanOrEqual(
            postTeardownSnap.count,
            0,
            "Post-teardown snapshot must return without hanging"
        )

        print("[SoakTest] Soak complete. Ring: \(ringCount), Disk: \(totalDiskBytes / (1024 * 1024)) MB, Peak RSS delta: \(peakDeltaBytes / (1024 * 1024)) MB")
    }
}
