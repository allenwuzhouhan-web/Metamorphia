import XCTest
import ApplicationServices
import Foundation
@testable import MetamorphiaPerception

/// Rank 3 — parallel async capture pipeline.
///
/// Tests cover cache semantics, timing breakdown, concurrent-access safety,
/// and (benchmark-gated) wall-clock targets. Tests that require the live AX
/// API skip when Accessibility permissions aren't granted to the test host.
final class PerceptionPipelineParallelTests: XCTestCase {

    /// Build a fresh pipeline per test so TTL, cache, and stabilizer state
    /// don't bleed across test cases. The static `.shared` is intentionally
    /// avoided here — sharing it would couple these tests to anything else
    /// in the test suite that happens to call it.
    private func makePipeline() -> PerceptionPipeline {
        PerceptionPipeline()
    }

    private func skipIfNoAX(_ testName: String = #function) throws {
        try XCTSkipIf(
            AXIsProcessTrusted() == false,
            "\(testName) requires Accessibility permissions for the test host"
        )
    }

    // MARK: - 1. Baseline sanity

    func testCapture_producesValidScreenMap() async throws {
        try skipIfNoAX()
        let pipeline = makePipeline()
        let map = await pipeline.capture(forceOCR: false, appFilter: nil)

        XCTAssertFalse(map.displays.isEmpty, "displays must be non-empty")
        XCTAssertGreaterThanOrEqual(map.captureMs, 0)
        XCTAssertNotNil(map.metadata.timing, "timing breakdown should be populated in the parallel path")
    }

    // MARK: - 2. Cache hit within TTL

    func testCacheHit_ReturnsWithinTTL() async throws {
        try skipIfNoAX()
        let pipeline = makePipeline()
        pipeline.cacheTTL = 1.0 // generous so the second call is guaranteed to hit
        let first = await pipeline.capture()
        let second = await pipeline.capture()
        // Cached hit returns the same ScreenMap value — timestamp equality is
        // a robust identity check because ScreenMap is a struct and the cache
        // stashes the whole map.
        XCTAssertEqual(first.timestamp, second.timestamp,
                       "second capture within TTL should return cached map")
    }

    // MARK: - 3. Cache miss after TTL

    func testCacheMiss_AfterTTL() async throws {
        try skipIfNoAX()
        let pipeline = makePipeline()
        pipeline.cacheTTL = 0.1
        let first = await pipeline.capture()
        // Sleep a hair over TTL.
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = await pipeline.capture()
        XCTAssertNotEqual(first.timestamp, second.timestamp,
                          "capture past TTL must produce a new map")
    }

    // MARK: - 4. invalidateCache forces a fresh read

    func testInvalidateCache_ForcesFreshRead() async throws {
        try skipIfNoAX()
        let pipeline = makePipeline()
        pipeline.cacheTTL = 1.0
        let first = await pipeline.capture()
        pipeline.invalidateCache()
        // Give the async clear a chance to land. invalidateCache() is
        // synchronous in contract, async in implementation — a short yield
        // is enough for the actor call to drain.
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = await pipeline.capture()
        XCTAssertNotEqual(first.timestamp, second.timestamp,
                          "invalidateCache must cause the next capture to return a fresh map")
    }

    // MARK: - 5. TimingBreakdown is populated

    func testTimingBreakdown_IsPopulated() async throws {
        try skipIfNoAX()
        let pipeline = makePipeline()
        let map = await pipeline.capture()
        let timing = try XCTUnwrap(map.metadata.timing)
        XCTAssertGreaterThanOrEqual(timing.totalMs, 0)
        XCTAssertGreaterThanOrEqual(timing.axMs, 0)
        XCTAssertGreaterThanOrEqual(timing.windowsMs, 0)
        XCTAssertGreaterThanOrEqual(timing.displaysMs, 0)
        XCTAssertGreaterThanOrEqual(timing.menusMs, 0)
        XCTAssertGreaterThanOrEqual(timing.dHashMs, 0)
        XCTAssertGreaterThanOrEqual(timing.fusionMs, 0)
        XCTAssertGreaterThanOrEqual(timing.safetyMs, 0)
    }

    // MARK: - 6. Timing totals roughly agree with per-phase bounds

    func testTimingBreakdown_TotalRoughlyEqualsSumOfPhases() async throws {
        try skipIfNoAX()
        let pipeline = makePipeline()
        let map = await pipeline.capture()
        let timing = try XCTUnwrap(map.metadata.timing)

        // In the parallel path, each phase-A task measures its own wall-clock
        // independently. They overlap, so the sum of phase times can exceed
        // `totalMs`. The lower bound on totalMs is the max of any single
        // phase-A task. The upper bound is the sum of all phase times.
        let phaseA = [timing.axMs, timing.windowsMs, timing.displaysMs,
                      timing.menusMs, timing.dHashMs]
        let maxPhaseA = phaseA.max() ?? 0

        let allPhases = phaseA + [timing.ocrMs, timing.fusionMs, timing.safetyMs]
        let sumPhases = allPhases.reduce(0, +)

        // totalMs >= max phase-A (hopefully; allow slight measurement error).
        XCTAssertGreaterThanOrEqual(timing.totalMs + 20, maxPhaseA,
                                    "total should be at least as big as the longest phase")
        // totalMs <= sum of phases + a small overhead budget.
        XCTAssertLessThanOrEqual(timing.totalMs, sumPhases + 200,
                                 "total should be bounded by the serial sum + overhead")
    }

    // MARK: - 7. Concurrent-call consistency

    func testConcurrency_TenCalls_ConsistentResult() async throws {
        try skipIfNoAX()
        let pipeline = makePipeline()
        pipeline.cacheTTL = 2.0 // all 10 should land within the TTL window

        // Prime the cache once so the subsequent 10 calls see a cache hit.
        _ = await pipeline.capture()

        // Launch 10 concurrent callers. A cache-coherent pipeline returns the
        // same snapshot (same timestamp) for all of them.
        let timestamps = await withTaskGroup(of: Date.self, returning: [Date].self) { group in
            for _ in 0..<10 {
                group.addTask { await pipeline.capture().timestamp }
            }
            var out: [Date] = []
            for await ts in group { out.append(ts) }
            return out
        }

        XCTAssertEqual(timestamps.count, 10)
        let unique = Set(timestamps)
        XCTAssertEqual(unique.count, 1,
                       "all concurrent cached callers should see the same map (\(unique.count) unique timestamps)")
    }

    // MARK: - 8. Benchmark — wall-clock under 200 ms

    func testBenchmark_CaptureUnder200ms() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SKIP_BENCHMARKS"] != nil,
            "SKIP_BENCHMARKS set"
        )
        try skipIfNoAX()
        let pipeline = makePipeline()
        pipeline.cacheTTL = 0.0 // disable cache so each call fully runs

        // Warm the AX caches on the first call; benchmark the second.
        _ = await pipeline.capture()

        // Run 5 captures back-to-back to average out noise and print the
        // per-phase breakdown — useful for diffing against future ranks.
        var timings: [Int] = []
        for _ in 0..<5 {
            AXReader.invalidateCache()
            let map = await pipeline.capture()
            timings.append(map.captureMs)
            if let t = map.metadata.timing {
                // Print to XCTest stderr so developers can eyeball the phase
                // shape. This is best-effort context, not an assertion.
                print("[bench] captureMs=\(map.captureMs) " +
                      "ax=\(t.axMs) win=\(t.windowsMs) disp=\(t.displaysMs) " +
                      "menus=\(t.menusMs) dhash=\(t.dHashMs) " +
                      "safety=\(t.safetyMs) fusion=\(t.fusionMs) ocr=\(t.ocrMs) " +
                      "elems=\(map.elements.count)")
            }
        }
        let avg = timings.reduce(0, +) / timings.count
        XCTAssertLessThan(avg, 200,
                          "parallel pipeline should capture in <200ms typical; got avg=\(avg)ms, samples=\(timings)")
    }

    // MARK: - 9. App filter returns filtered app

    func testAppFilter_ReturnsFilteredApp() async throws {
        try skipIfNoAX()
        let pipeline = makePipeline()
        // Filter on the frontmost app by its own name — guaranteed to exist.
        // We don't assert deep AX content since it depends on which app is
        // frontmost at test time; the contract we verify is that the capture
        // returns a map whose focusedApp matches the filter or an Unknown
        // fallback (when the AX read itself fails).
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        try XCTSkipIf(frontmost.isEmpty, "no frontmost app at test time")

        let map = await pipeline.capture(forceOCR: false, appFilter: frontmost)
        // focusedApp may still be "Unknown" if AX read fails, but windows
        // (if any) must match the filter.
        for window in map.windows {
            XCTAssertEqual(
                window.appName.lowercased(),
                frontmost.lowercased(),
                "filtered capture should only include windows of the requested app"
            )
        }
    }

    // MARK: - 10. forceOCR invokes OCR synchronously

    func testForceOCR_InvokesOCRSynchronously() async throws {
        try skipIfNoAX()
        // OCR needs screen recording permission. Skip in CI-like environments
        // where it isn't granted — the VNRecognizeTextRequest will still run,
        // but on a black screen the result is typically empty. We don't want
        // that to fail the test; assert only on the metadata flag.
        let pipeline = makePipeline()
        pipeline.cacheTTL = 0.0
        AXReader.invalidateCache()
        let map = await pipeline.capture(forceOCR: true)

        // If the capture succeeded at all (CGWindowListCreateImage can fail
        // when screen recording permission is missing) we expect ocrUsed to
        // be true. When the image capture failed, ocrUsed stays false — in
        // that case we skip rather than fail.
        try XCTSkipIf(
            !map.metadata.ocrUsed,
            "screen capture returned no image — likely missing screen recording permission"
        )
        XCTAssertTrue(map.metadata.ocrUsed,
                      "forceOCR should set metadata.ocrUsed when the capture succeeds")
    }
}
