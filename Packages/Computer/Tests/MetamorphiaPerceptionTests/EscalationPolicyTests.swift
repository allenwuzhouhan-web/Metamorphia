import XCTest
@testable import MetamorphiaPerception

final class EscalationPolicyTests: XCTestCase {

    // MARK: - Helpers

    /// Fresh policy instance for each test to avoid shared state.
    private func policy() -> EscalationPolicy { EscalationPolicy() }

    private func ctx(
        bundle: String? = "com.example.app",
        reason: EscalationPolicy.Reason,
        at: Date = Date()
    ) -> EscalationPolicy.EscalationContext {
        .init(bundleID: bundle, reason: reason, at: at)
    }

    // MARK: - secureInputAdjacent always denies

    func testSecureInputAdjacentAlwaysDenies() async {
        let p = policy()
        for _ in 0..<5 {
            let d = await p.evaluate(
                lane: .ocrFallback,
                context: ctx(reason: .secureInputAdjacent)
            )
            XCTAssertFalse(d.allow)
            XCTAssertEqual(d.denyCause, "hard-deny")
            XCTAssertNil(d.tokenID)
        }
    }

    // MARK: - Debounce: axEmpty (2.0 s)

    func testAxEmptyDebounceDeniesWithinWindow() async {
        let p = policy()
        let t0 = Date()
        // First call: allow
        let d1 = await p.evaluate(lane: .axPoll, context: ctx(reason: .axEmpty, at: t0))
        XCTAssertTrue(d1.allow, "First evaluate should allow")
        XCTAssertNotNil(d1.tokenID)

        // Second call 1 s later: deny (debounce = 2 s)
        let t1 = t0.addingTimeInterval(1.0)
        let d2 = await p.evaluate(lane: .axPoll, context: ctx(reason: .axEmpty, at: t1))
        XCTAssertFalse(d2.allow)
        XCTAssertEqual(d2.denyCause, "debounce")
    }

    func testAxEmptyAllowsAfterDebounceExpires() async {
        let p = policy()
        let t0 = Date()
        _ = await p.evaluate(lane: .axPoll, context: ctx(reason: .axEmpty, at: t0))

        // 2.1 s later: should allow again
        let t2 = t0.addingTimeInterval(2.1)
        let d = await p.evaluate(lane: .axPoll, context: ctx(reason: .axEmpty, at: t2))
        XCTAssertTrue(d.allow)
        XCTAssertEqual(d.denyCause, nil)
    }

    // MARK: - Debounce: agentRequestedVerify (0.0 s — never debounced)

    func testAgentRequestedVerifyNeverDebounced() async {
        let p = policy()
        let t0 = Date()
        for i in 0..<5 {
            let d = await p.evaluate(
                lane: .ocrFallback,
                context: ctx(reason: .agentRequestedVerify, at: t0.addingTimeInterval(Double(i) * 0.001))
            )
            XCTAssertTrue(d.allow, "agentRequestedVerify should always pass debounce")
        }
    }

    // MARK: - Debounce: each reason honored

    func testAllReasonsHaveDebounce() async {
        let debounces: [EscalationPolicy.Reason: TimeInterval] = [
            .axEmpty: 2.0,
            .axShallow: 3.0,
            .knownOpaqueApp: 5.0,
            .userInteractedUnnamedElement: 0.3,
            .attentionSpike: 1.0,
            .driftDetected: 10.0,
        ]
        for (reason, window) in debounces {
            let p = policy()
            let t0 = Date()
            let d1 = await p.evaluate(lane: .axPoll, context: ctx(reason: reason, at: t0))
            XCTAssertTrue(d1.allow, "\(reason) first call should allow")

            // Just inside the window
            let tInside = t0.addingTimeInterval(window * 0.5)
            let d2 = await p.evaluate(lane: .axPoll, context: ctx(reason: reason, at: tInside))
            XCTAssertFalse(d2.allow, "\(reason) within window should deny")
            XCTAssertEqual(d2.denyCause, "debounce", "\(reason)")

            // Just outside the window
            let tOutside = t0.addingTimeInterval(window + 0.1)
            let d3 = await p.evaluate(lane: .axPoll, context: ctx(reason: reason, at: tOutside))
            XCTAssertTrue(d3.allow, "\(reason) after window should allow")
        }
    }

    // MARK: - Daily cap: axEmpty capped at 200

    func testAxEmptyDailyCap() async {
        let p = policy()
        let bundle = "com.example.cap"
        var allowCount = 0
        var denyCapCount = 0

        // Issue 201 evaluations with increasing times (past debounce each time)
        for i in 0..<201 {
            // Each call spaced 3 s apart to clear the 2 s debounce
            let t = Date(timeIntervalSinceReferenceDate: Double(i) * 3.0)
            let d = await p.evaluate(
                lane: .axPoll,
                context: .init(bundleID: bundle, reason: .axEmpty, at: t)
            )
            if d.allow { allowCount += 1 }
            else if d.denyCause == "cap" { denyCapCount += 1 }
        }

        XCTAssertEqual(allowCount, 200, "Exactly 200 should be allowed before cap")
        XCTAssertEqual(denyCapCount, 1, "201st should be denied with 'cap'")
    }

    // MARK: - Daily reset

    func testDailyCountsResetAcrossCalendarDay() async {
        let p = policy()
        let bundle = "com.example.reset"

        // Exhaust the attentionSpike cap (30) today
        let todayBase = Date()
        for i in 0..<30 {
            let t = todayBase.addingTimeInterval(Double(i) * 2.0)
            _ = await p.evaluate(lane: .axPoll, context: .init(bundleID: bundle, reason: .attentionSpike, at: t))
        }
        let denied = await p.evaluate(
            lane: .axPoll,
            context: .init(bundleID: bundle, reason: .attentionSpike, at: todayBase.addingTimeInterval(200))
        )
        XCTAssertFalse(denied.allow)
        XCTAssertEqual(denied.denyCause, "cap")

        // Simulate tomorrow
        var tomorrowComponents = Calendar.current.dateComponents([.year, .month, .day], from: todayBase)
        tomorrowComponents.day! += 1
        tomorrowComponents.hour = 9
        let tomorrow = Calendar.current.date(from: tomorrowComponents)!

        let nextDay = await p.evaluate(
            lane: .axPoll,
            context: .init(bundleID: bundle, reason: .attentionSpike, at: tomorrow)
        )
        XCTAssertTrue(nextDay.allow, "Cap should reset on a new calendar day")
    }

    // MARK: - Oscillation guard: settle clears outstanding token

    func testSettleWithMatchingTokenClearsOutstanding() async {
        let p = policy()
        let d = await p.evaluate(lane: .ocrFallback, context: ctx(reason: .axEmpty))
        XCTAssertTrue(d.allow)
        guard let token = d.tokenID else { return XCTFail("Expected tokenID") }

        // Outstanding token should exist
        let before = await p.outstandingToken(bundleID: "com.example.app", reason: .axEmpty)
        XCTAssertEqual(before, token)

        await p.settle(tokenID: token, result: .completed)

        let after = await p.outstandingToken(bundleID: "com.example.app", reason: .axEmpty)
        XCTAssertNil(after, "settle(completed) should clear the outstanding token")
    }

    func testSettleWithStaleTokenIsNoop() async {
        let p = policy()
        let t0 = Date()

        let d1 = await p.evaluate(lane: .ocrFallback, context: ctx(reason: .axEmpty, at: t0))
        guard let staleToken = d1.tokenID else { return XCTFail("Expected tokenID") }

        // Issue a newer escalation to supersede the first token
        let t1 = t0.addingTimeInterval(2.1)
        let d2 = await p.evaluate(lane: .ocrFallback, context: ctx(reason: .axEmpty, at: t1))
        guard let newToken = d2.tokenID else { return XCTFail("Expected second tokenID") }
        XCTAssertNotEqual(staleToken, newToken)

        // Settling the stale token should not clear the current outstanding one
        await p.settle(tokenID: staleToken, result: .supersededByPrimary)

        let outstanding = await p.outstandingToken(bundleID: "com.example.app", reason: .axEmpty)
        XCTAssertEqual(outstanding, newToken, "Stale settle must not remove the current token")
    }

    // MARK: - Profile: axQualityScore decays on axEmpty

    func testAxQualityDecaysOn20AxEmpty() async {
        let p = policy()
        let bundle = "com.example.decay"

        // 20 × axEmpty, spaced past debounce
        for i in 0..<20 {
            let t = Date(timeIntervalSinceReferenceDate: Double(i) * 3.0)
            _ = await p.evaluate(lane: .axPoll, context: .init(bundleID: bundle, reason: .axEmpty, at: t))
        }

        let profile = await p.profile(forBundle: bundle)
        XCTAssertEqual(profile.axQualityScore, 1.0 - 0.2, accuracy: 0.001,
                       "20 axEmpty events should decay score by 0.20")
    }

    func testAxQualityClimbsAfterRecordAXSuccess() async {
        let p = policy()
        let bundle = "com.example.climb"

        // Decay the score with 20 axEmpty events
        for i in 0..<20 {
            let t = Date(timeIntervalSinceReferenceDate: Double(i) * 3.0)
            _ = await p.evaluate(lane: .axPoll, context: .init(bundleID: bundle, reason: .axEmpty, at: t))
        }
        let decayed = await p.profile(forBundle: bundle)
        XCTAssertLessThan(decayed.axQualityScore, 1.0)

        // 100 recordAXSuccess calls
        for _ in 0..<100 {
            await p.recordAXSuccess(bundle: bundle)
        }

        let recovered = await p.profile(forBundle: bundle)
        XCTAssertGreaterThan(recovered.axQualityScore, decayed.axQualityScore,
                              "recordAXSuccess should improve axQualityScore")
    }

    // MARK: - Profile: strategy heuristic

    func testStrategyHeuristicAxPlusOcr() async {
        let p = policy()
        let bundle = "com.example.strategy"

        // Decay score below 0.3 but above 0.1 (need 71+ events past debounce)
        // 71 × axEmpty decays 0.71, leaving 0.29
        for i in 0..<71 {
            let t = Date(timeIntervalSinceReferenceDate: Double(i) * 3.0)
            _ = await p.evaluate(lane: .axPoll, context: .init(bundleID: bundle, reason: .axEmpty, at: t))
        }

        let profile = await p.profile(forBundle: bundle)
        XCTAssertEqual(profile.preferredStrategy, .axPlusOcr,
                       "Score \(profile.axQualityScore) in (0.1, 0.3) should yield axPlusOcr")
    }

    func testStrategyHeuristicOcrOnly() async {
        let p = policy()
        let bundle = "com.example.ocr-only"

        // Decay score below 0.1 (need 91+ events)
        for i in 0..<91 {
            let t = Date(timeIntervalSinceReferenceDate: Double(i) * 3.0)
            _ = await p.evaluate(lane: .axPoll, context: .init(bundleID: bundle, reason: .axEmpty, at: t))
        }

        let profile = await p.profile(forBundle: bundle)
        XCTAssertLessThan(profile.axQualityScore, 0.1)
        XCTAssertEqual(profile.preferredStrategy, .ocrOnly)
    }

    // MARK: - Profile default construction

    func testProfileDefaultForUnknownBundle() async {
        let p = policy()
        let profile = await p.profile(forBundle: "com.new.app")
        XCTAssertEqual(profile.axQualityScore, 1.0)
        XCTAssertEqual(profile.preferredStrategy, .ax)
        XCTAssertTrue(profile.sevenDayCounts.isEmpty)
    }

    // MARK: - dailyReport

    func testDailyReportContainsAllBundlesWithData() async {
        let p = policy()
        let bundles = ["com.a", "com.b", "com.c"]
        var t = Date()
        for bundle in bundles {
            _ = await p.evaluate(lane: .axPoll,
                                 context: .init(bundleID: bundle, reason: .axEmpty, at: t))
            t = t.addingTimeInterval(1)
        }

        let report = await p.dailyReport()
        let reportedBundles = Set(report.map(\.bundleID))
        for bundle in bundles {
            XCTAssertTrue(reportedBundles.contains(bundle),
                          "dailyReport should include \(bundle)")
        }
    }

    func testDailyReportHasRecentEscalationTimestamps() async {
        let p = policy()
        let bundle = "com.example.report"
        var t = Date()
        for _ in 0..<5 {
            _ = await p.evaluate(
                lane: .axPoll,
                context: .init(bundleID: bundle, reason: .attentionSpike, at: t)
            )
            t = t.addingTimeInterval(2.0)
        }

        let report = await p.dailyReport()
        let tally = report.first(where: { $0.bundleID == bundle })
        XCTAssertNotNil(tally)
        XCTAssertEqual(tally!.lastEscalations.count, 5)
    }

    func testDailyReportRingBufferCapAt10() async {
        let p = policy()
        let bundle = "com.example.ring"
        // Issue 15 evaluations, each spaced past the 1s attentionSpike debounce
        for i in 0..<15 {
            let t = Date(timeIntervalSinceReferenceDate: Double(i) * 2.0)
            _ = await p.evaluate(
                lane: .axPoll,
                context: .init(bundleID: bundle, reason: .attentionSpike, at: t)
            )
        }
        let report = await p.dailyReport()
        let tally = report.first(where: { $0.bundleID == bundle })!
        XCTAssertLessThanOrEqual(tally.lastEscalations.count, 10,
                                  "Ring buffer should cap at 10 entries")
    }
}
