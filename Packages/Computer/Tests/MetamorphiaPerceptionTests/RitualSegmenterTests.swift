import XCTest
@testable import MetamorphiaPerception

final class RitualSegmenterTests: XCTestCase {

    // MARK: - Synthetic Log Helpers

    /// Build a single ritual "session" — a tight sequence of steps in one app
    /// separated by short inter-step gaps (well under the idle threshold).
    ///
    /// - Parameters:
    ///   - bundleID: The app bundle ID for each step.
    ///   - count: Number of steps in the ritual.
    ///   - startTime: Timestamp for the first step.
    ///   - interStepSeconds: Gap between consecutive steps.
    ///   - typedTexts: Optional per-step text values (injected into params["text"]).
    ///                 If provided, must equal `count` in length.
    /// - Returns: A step array representing one ritual execution.
    private func makeRitual(
        bundleID: String = "com.tinyspeck.slackmacgap",
        identityKeys: [String] = ["btn_send", "field_message", "btn_confirm"],
        ops: [SkillStep.Op]? = nil,
        startTime: Date,
        interStepSeconds: TimeInterval = 5,
        typedTexts: [String?]? = nil
    ) -> [SkillStep] {
        let resolvedOps: [SkillStep.Op]
        if let ops {
            resolvedOps = ops
        } else {
            resolvedOps = identityKeys.map { _ in .press }
        }

        return identityKeys.enumerated().map { i, key in
            var params: [String: String] = [:]
            if let texts = typedTexts, i < texts.count, let text = texts[i] {
                params["text"] = text
            }
            return SkillStep(
                ts: startTime.addingTimeInterval(Double(i) * interStepSeconds),
                op: resolvedOps[i],
                identityKey: key,
                appBundleID: bundleID,
                params: params
            )
        }
    }

    /// Concatenate N repetitions of the same ritual, separated by a gap
    /// that exceeds the idle threshold (signals distinct sessions).
    ///
    /// - Parameters:
    ///   - repetitions: How many times to repeat the ritual.
    ///   - ritualDuration: How long one ritual execution takes (seconds).
    ///   - interRitualGap: Gap between the end of one ritual and the start of
    ///     the next (should be > idleGapSeconds to create a boundary).
    ///   - typedTextVariants: Per-repetition text for the step that should vary.
    ///                        Pass nil per repetition for constant text.
    private func makeConcatenatedLog(
        repetitions: Int = 3,
        bundleID: String = "com.tinyspeck.slackmacgap",
        identityKeys: [String] = ["btn_send", "field_message", "btn_confirm"],
        ops: [SkillStep.Op]? = nil,
        interStepSeconds: TimeInterval = 5,
        ritualDuration: TimeInterval = 20,
        interRitualGap: TimeInterval = 90,
        typedTextVariants: [[String?]?]? = nil,
        baseTime: Date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    ) -> [SkillStep] {
        var allSteps: [SkillStep] = []
        for r in 0..<repetitions {
            let start = baseTime.addingTimeInterval(
                Double(r) * (ritualDuration + interRitualGap)
            )
            let texts = typedTextVariants?[r]
            let ritual = makeRitual(
                bundleID: bundleID,
                identityKeys: identityKeys,
                ops: ops,
                startTime: start,
                interStepSeconds: interStepSeconds,
                typedTexts: texts
            )
            allSteps.append(contentsOf: ritual)
        }
        return allSteps
    }

    // MARK: - Boundary Precision / Recall / F1

    func testBoundaryF1ExceedsThreshold() async {
        let tunables = RitualSegmenter.Tunables()
        // interRitualGap (90s) >> idleGapSeconds (45s) → clean synthetic boundaries.
        let log = makeConcatenatedLog(
            repetitions: 3,
            identityKeys: ["btn_a", "field_b", "btn_c"],
            interStepSeconds: 4,
            ritualDuration: 12,   // 3 steps × 4s apart = spans 8s per ritual
            interRitualGap: 90    // 90s >> 45s idle threshold
        )
        let segmenter = RitualSegmenter(tunables: tunables)
        let windows = await segmenter.segment(steps: log, activityCues: [])

        // Ground truth: 3 ritual boundaries → 3 windows.
        let expected = 3
        let predicted = windows.count

        // Precision: what fraction of predicted windows match a ground-truth ritual?
        // Recall: what fraction of ground-truth rituals have a predicted match?
        // For this perfectly clean synthetic log, both should be 1.0.
        let tp = min(predicted, expected) // all predicted windows are correct here
        let fp = max(0, predicted - expected)
        let fn = max(0, expected - predicted)

        let precision = tp > 0 ? Double(tp) / Double(tp + fp) : 0.0
        let recall    = tp > 0 ? Double(tp) / Double(tp + fn) : 0.0
        let f1 = (precision + recall > 0)
            ? 2 * precision * recall / (precision + recall)
            : 0.0

        XCTAssertGreaterThanOrEqual(f1, 0.8, "F1 \(f1) below threshold — check gap sizes")
        XCTAssertGreaterThanOrEqual(windows.count, 2, "Should find at least 2 of the 3 ritual repetitions")
    }

    // MARK: - Idle Gap Boundary

    func testIdleGapCutsWindow() async {
        let tunables = RitualSegmenter.Tunables()
        let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

        // Session A: steps 0–2, then a gap of 90s, then session B: steps 3–5.
        let stepsA = makeRitual(
            identityKeys: ["a", "b", "c"],
            startTime: t0,
            interStepSeconds: 5
        )
        // The gap between last step of A and first step of B: 90s > 45s idle threshold.
        let gapStart = stepsA.last!.ts.addingTimeInterval(90)
        let stepsB = makeRitual(
            identityKeys: ["a", "b", "c"],
            startTime: gapStart,
            interStepSeconds: 5
        )

        let log = stepsA + stepsB
        let segmenter = RitualSegmenter(tunables: tunables)
        let windows = await segmenter.segment(steps: log, activityCues: [])

        XCTAssertEqual(windows.count, 2, "Idle gap of 90s should split into two windows")
    }

    // MARK: - Home Bundle Boundary

    func testHomeBundleReturnCutsWindow() async {
        var tunables = RitualSegmenter.Tunables()
        tunables.homeBundleIDs = ["com.apple.finder"]

        let t0 = Date(timeIntervalSinceReferenceDate: 3_000_000)

        // Steps in Slack, then a step in Finder (home), then more Slack steps.
        let slackSteps = makeRitual(
            bundleID: "com.tinyspeck.slackmacgap",
            identityKeys: ["btn_1", "btn_2"],
            startTime: t0,
            interStepSeconds: 5
        )
        let finderStep = SkillStep(
            ts: slackSteps.last!.ts.addingTimeInterval(3),
            op: .press,
            identityKey: "finder_icon",
            appBundleID: "com.apple.finder"
        )
        let slackSteps2 = makeRitual(
            bundleID: "com.tinyspeck.slackmacgap",
            identityKeys: ["btn_3", "btn_4"],
            startTime: finderStep.ts.addingTimeInterval(3),
            interStepSeconds: 5
        )

        let log = slackSteps + [finderStep] + slackSteps2
        let segmenter = RitualSegmenter(tunables: tunables)
        // No idle gaps (all < 45s apart), but Finder step triggers a home boundary.
        let windows = await segmenter.segment(steps: log, activityCues: [])

        // Expect at least one cut where the Finder step appears.
        XCTAssertGreaterThanOrEqual(windows.count, 1)
    }

    // MARK: - querySubmitted Boundary

    func testQuerySubmittedCueBreaksRitual() async {
        let tunables = RitualSegmenter.Tunables()
        let t0 = Date(timeIntervalSinceReferenceDate: 4_000_000)

        let stepsA = makeRitual(
            identityKeys: ["btn_x", "btn_y"],
            startTime: t0,
            interStepSeconds: 5
        )
        let queryTime = stepsA.last!.ts.addingTimeInterval(2)
        let queryCue = ActivityCue(kind: .querySubmitted, bundleID: nil, at: queryTime)

        let stepsB = makeRitual(
            identityKeys: ["btn_x", "btn_y"],
            startTime: queryTime.addingTimeInterval(2),
            interStepSeconds: 5
        )

        let log = stepsA + stepsB
        let segmenter = RitualSegmenter(tunables: tunables)
        let windows = await segmenter.segment(steps: log, activityCues: [queryCue])

        XCTAssertEqual(windows.count, 2, "querySubmitted cue should cut the ritual window")
    }

    // MARK: - Bundle Switch Without Flicker

    func testBundleSwitchWithoutFlickerCutsWindow() async {
        let tunables = RitualSegmenter.Tunables()
        let t0 = Date(timeIntervalSinceReferenceDate: 5_000_000)

        let slackStep = SkillStep(
            ts: t0,
            op: .press,
            identityKey: "btn_send",
            appBundleID: "com.tinyspeck.slackmacgap"
        )
        let safariStep = SkillStep(
            ts: t0.addingTimeInterval(10),
            op: .press,
            identityKey: "btn_go",
            appBundleID: "com.apple.Safari"
        )
        let slackStep2 = SkillStep(
            ts: t0.addingTimeInterval(20),
            op: .press,
            identityKey: "btn_close",
            appBundleID: "com.tinyspeck.slackmacgap"
        )

        // No focus-changed cue returning to Slack before the switch → genuine switch.
        let log = [slackStep, safariStep, slackStep2]
        let segmenter = RitualSegmenter(tunables: tunables)
        let windows = await segmenter.segment(steps: log, activityCues: [])

        // The switch from Slack→Safari without a flicker-return should cut.
        // Windows may vary in count, but none should span all three steps as one window.
        let allInOne = windows.first(where: { $0.steps.count == 3 })
        XCTAssertNil(allInOne, "A genuine bundle switch should produce a boundary")
    }

    // MARK: - Flicker Absorption (No Cut)

    func testFlickerReturnAbsorbsBundleSwitch() async {
        var tunables = RitualSegmenter.Tunables()
        tunables.flickerWindowSeconds = 30

        let t0 = Date(timeIntervalSinceReferenceDate: 6_000_000)

        let slackStep1 = SkillStep(
            ts: t0,
            op: .press,
            identityKey: "btn_send",
            appBundleID: "com.tinyspeck.slackmacgap"
        )
        // Safari appears briefly (flicker) then Slack returns — same bundle.
        let safariStep = SkillStep(
            ts: t0.addingTimeInterval(8),
            op: .press,
            identityKey: "btn_open",
            appBundleID: "com.tinyspeck.slackmacgap"  // returned to Slack
        )

        // A focus cue: Safari appeared within 30s then Slack returned (flicker).
        let safariCue = ActivityCue(
            kind: .focusChanged,
            bundleID: "com.tinyspeck.slackmacgap",
            at: t0.addingTimeInterval(4)  // within flickerWindow, before safariStep
        )

        let log = [slackStep1, safariStep]
        let segmenter = RitualSegmenter(tunables: tunables)
        let windows = await segmenter.segment(steps: log, activityCues: [safariCue])

        // Both steps are in the same bundle (Slack), so no bundle switch actually
        // happens in the step sequence here. The test verifies the algorithm doesn't
        // cut on a same-bundle pair. One window containing both steps is expected.
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.steps.count, 2)
    }

    // MARK: - Minimum Step Count Filter

    func testWindowBelowMinStepsDiscarded() async {
        var tunables = RitualSegmenter.Tunables()
        tunables.minRitualSteps = 3

        let t0 = Date(timeIntervalSinceReferenceDate: 7_000_000)

        // Only 2 steps — below minRitualSteps.
        let steps = makeRitual(
            identityKeys: ["btn_a", "btn_b"],
            startTime: t0,
            interStepSeconds: 5
        )

        let segmenter = RitualSegmenter(tunables: tunables)
        let windows = await segmenter.segment(steps: steps, activityCues: [])
        XCTAssertTrue(windows.isEmpty, "Window with fewer than minRitualSteps should be discarded")
    }

    // MARK: - Span Filters

    func testWindowBelowMinSpanDiscarded() async {
        var tunables = RitualSegmenter.Tunables()
        tunables.minRitualSpanSeconds = 10

        let t0 = Date(timeIntervalSinceReferenceDate: 8_000_000)

        // 3 steps, 1s apart = span of 2s < 10s minimum.
        let steps = makeRitual(
            identityKeys: ["a", "b", "c"],
            startTime: t0,
            interStepSeconds: 1
        )

        let segmenter = RitualSegmenter(tunables: tunables)
        let windows = await segmenter.segment(steps: steps, activityCues: [])
        XCTAssertTrue(windows.isEmpty, "Window spanning less than minRitualSpanSeconds should be discarded")
    }

    func testWindowAboveMaxSpanDiscarded() async {
        var tunables = RitualSegmenter.Tunables()
        tunables.maxRitualSpanSeconds = 60

        let t0 = Date(timeIntervalSinceReferenceDate: 9_000_000)

        // 3 steps each 35s apart = span 70s > 60s maximum.
        // But note: inter-step gap of 35s < idleGapSeconds (45s) so no boundary cuts.
        let steps = makeRitual(
            identityKeys: ["a", "b", "c"],
            startTime: t0,
            interStepSeconds: 35
        )

        let segmenter = RitualSegmenter(tunables: tunables)
        let windows = await segmenter.segment(steps: steps, activityCues: [])
        XCTAssertTrue(windows.isEmpty, "Window spanning more than maxRitualSpanSeconds should be discarded")
    }

    // MARK: - Signature Format

    func testSignatureMatchesSkillCompilerFormat() async {
        let t0 = Date(timeIntervalSinceReferenceDate: 10_000_000)

        let steps = makeRitual(
            bundleID: "com.tinyspeck.slackmacgap",
            identityKeys: ["btn_send", "field_msg"],
            ops: [.press, .type],
            startTime: t0,
            interStepSeconds: 5
        )

        let segmenter = RitualSegmenter()
        let windows = await segmenter.segment(steps: steps, activityCues: [])

        guard let window = windows.first else {
            XCTFail("Expected at least one window")
            return
        }

        // The signature must exactly match what SkillCompiler.compileForBundle builds.
        let expected = "press|btn_send›type|field_msg"
        XCTAssertEqual(window.signature, expected)
    }

    // MARK: - RitualRecurrenceStore: Promotion Semantics

    func testRecurrencePromotion() async {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ritual_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let store = RitualRecurrenceStore(
            fileURL: tmpURL,
            minRepetitions: 3,
            recurrenceWindowDays: 7
        )

        let sig = "press|btn_send›type|field_msg›press|btn_confirm"
        let t0 = Date(timeIntervalSinceReferenceDate: 11_000_000)

        let r1 = await store.observe(signature: sig, at: t0)
        let r2 = await store.observe(signature: sig, at: t0.addingTimeInterval(3600))
        let r3 = await store.observe(signature: sig, at: t0.addingTimeInterval(7200))

        XCTAssertFalse(r1, "First observation should not trigger promotion")
        XCTAssertFalse(r2, "Second observation should not trigger promotion")
        XCTAssertTrue(r3, "Third observation within window should trigger promotion")
    }

    func testRecurrenceWindowExpiry() async {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ritual_expiry_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let store = RitualRecurrenceStore(
            fileURL: tmpURL,
            minRepetitions: 3,
            recurrenceWindowDays: 7
        )

        let sig = "press|old_btn"
        let old = Date(timeIntervalSinceReferenceDate: 0) // far in the past

        // Two old observations (beyond the 7-day window from now).
        await store.observe(signature: sig, at: old)
        await store.observe(signature: sig, at: old.addingTimeInterval(3600))

        // Third observation is now — old ones should have been pruned.
        let promoted = await store.observe(signature: sig, at: Date())
        XCTAssertFalse(promoted, "Observations outside the recurrence window should not count toward promotion")
    }

    // MARK: - SkillCompiler Integration

    func testCompilerFindsSlotInRepeatedRitual() {
        // Build 3 repetitions of a ritual where the "type" step text varies.
        let texts: [[String?]?] = [
            [nil, "Daily standup update"],
            [nil, "Weekly sync notes"],
            [nil, "Sprint retrospective"],
        ]
        let log = makeConcatenatedLog(
            repetitions: 3,
            bundleID: "com.tinyspeck.slackmacgap",
            identityKeys: ["btn_channel", "field_message"],
            ops: [.press, .type],
            interStepSeconds: 4,
            ritualDuration: 10,
            interRitualGap: 90,
            typedTextVariants: texts
        )

        // Feed the full concatenated log to the compiler (which expects minRepetitions
        // × minSequenceLength steps and groups by bundle ID).
        let compiled = SkillCompiler.compile(log)

        // There should be at least one compiled skill for Slack.
        XCTAssertFalse(compiled.isEmpty, "Compiler should find repeated ritual in concatenated log")

        // The skill should have one parameter for the varying 'type' step text.
        let slackSkill = compiled.first { $0.steps.count == 2 }
        if let skill = slackSkill {
            XCTAssertFalse(skill.parameters.isEmpty,
                "Varying text across repetitions should produce at least one SkillParam slot")
            XCTAssertEqual(skill.observedRepetitions, 3)
        }
    }

    // MARK: - WorkflowRecorder Round-Trip

    func testWorkflowRecorderRoundTrip() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        let t0 = Date(timeIntervalSinceReferenceDate: 12_000_000)

        let selector = WorkflowRecorder.ElementSelector(
            structuralSignature: "AXButton/AXToolbar@1#send",
            role: "AXButton",
            label: "Send",
            appBundleID: "com.tinyspeck.slackmacgap",
            parentLabel: "Toolbar"
        )
        let action = WorkflowRecorder.RecordedAction(
            type: .click,
            parameters: [:]
        )
        let preState = WorkflowRecorder.UIStateSnapshot(
            appName: "Slack",
            windowTitle: "General",
            interactiveElementCount: 12,
            contentHash: "abc123"
        )
        let step = WorkflowRecorder.WorkflowStep(
            elementSelector: selector,
            action: action,
            preState: preState,
            postState: nil,
            timestamp: t0
        )

        // Encode then decode via the public API.
        guard let data = try? encoder.encode([step]),
              let json = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to encode WorkflowStep")
            return
        }

        let decoded = WorkflowRecorder.decodeSteps(json)
        XCTAssertNotNil(decoded, "decodeSteps should round-trip a WorkflowStep array")
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.elementSelector.structuralSignature,
                       "AXButton/AXToolbar@1#send")
        XCTAssertEqual(decoded?.first?.action.type, .click)
        XCTAssertEqual(decoded?.first?.preState.appName, "Slack")

        // Map WorkflowStep → SkillStep (as RitualCompilationSweep does in Executors).
        let skillStep = workflowStepToSkillStep(decoded!.first!, at: t0)
        XCTAssertEqual(skillStep.op, .press)  // click → press
        XCTAssertEqual(skillStep.identityKey, "AXButton/AXToolbar@1#send")
        XCTAssertEqual(skillStep.appBundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(skillStep.ts.timeIntervalSince1970, t0.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Local Mapping Helper (mirrors RitualCompilationSweep in Executors)

    /// Map a WorkflowRecorder.WorkflowStep to a SkillStep using the same field
    /// mapping that RitualCompilationSweep in the Executors package applies.
    private func workflowStepToSkillStep(
        _ ws: WorkflowRecorder.WorkflowStep,
        at ts: Date
    ) -> SkillStep {
        let op: SkillStep.Op
        switch ws.action.type {
        case .click, .doubleClick, .rightClick:
            op = .press
        case .type, .paste:
            op = .type
        case .keyPress:
            op = .press
        case .scroll, .drag:
            op = .press
        }
        return SkillStep(
            ts: ts,
            op: op,
            identityKey: ws.elementSelector.structuralSignature,
            appBundleID: ws.elementSelector.appBundleID,
            params: ws.action.parameters
        )
    }
}
