import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

/// Rank 2 — Ref-only delta encoding for LLM.
///
/// Exercises:
/// - Baseline vs. delta payload shape
/// - Added / removed / changed / retained partitioning
/// - Bounds-tolerance (4 px) for noise suppression
/// - Per-tier handling (identifier/label/position/fallback)
/// - JSON encoding + text rendering
/// - Filter-stats delta + meta-change detection
final class DeltaEncoderTests: XCTestCase {

    // MARK: - 1. First call is baseline

    func testBuildPayload_firstCall_IsBaseline() {
        let map = makeMap(elements: [
            makeElement(ref: 1, role: .button, label: "Save",
                        bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label
        ]
        let payload = DeltaEncoder.buildPayload(
            previous: nil, current: map,
            previousTiers: nil, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 0
        )
        XCTAssertTrue(payload.isBaseline)
        XCTAssertNotNil(payload.baselineJSON)
        XCTAssertNil(payload.delta)
        XCTAssertEqual(payload.sequenceNumber, 0)
    }

    // MARK: - 2. Second call is pure delta

    func testBuildPayload_secondCall_IsPureDelta() {
        let e1 = makeElement(ref: 1, role: .button, label: "Save",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let map1 = makeMap(elements: [e1])
        let map2 = makeMap(elements: [e1])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        XCTAssertFalse(payload.isBaseline)
        XCTAssertNil(payload.baselineJSON)
        XCTAssertNotNil(payload.delta)
    }

    // MARK: - 3. No changes → empty added/removed/changed, all retained

    func testBuildPayload_noChanges_EmitsEmptyDelta() {
        let e1 = makeElement(ref: 1, role: .button, label: "Save",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let e2 = makeElement(ref: 2, role: .textField, label: "Title",
                             bounds: CGRect(x: 10, y: 50, width: 200, height: 30))
        let map = makeMap(elements: [e1, e2])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .label
        ]
        let payload = DeltaEncoder.buildPayload(
            previous: map, current: map,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertTrue(delta.added.isEmpty)
        XCTAssertTrue(delta.removedRefs.isEmpty)
        XCTAssertTrue(delta.changed.isEmpty)
        XCTAssertEqual(delta.retained.count, 2)
    }

    // MARK: - 4. Added element emits full body

    func testBuildPayload_addedElement_FullBodyIncluded() {
        let e1 = makeElement(ref: 1, role: .button, label: "Save",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let map1 = makeMap(elements: [e1])
        let e2 = makeElement(ref: 2, role: .button, label: "Cancel",
                             bounds: CGRect(x: 100, y: 10, width: 80, height: 30))
        let map2 = makeMap(elements: [e1, e2])
        let prevTiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label
        ]
        let currTiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .label
        ]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: prevTiers, currentTiers: currTiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertEqual(delta.added.count, 1)
        XCTAssertEqual(delta.added.first?.ref, ElementRef(index: 2))
        XCTAssertEqual(delta.added.first?.label, "Cancel")
    }

    // MARK: - 5. Removed element → ref only

    func testBuildPayload_removedElement_RefOnlyIncluded() {
        let e1 = makeElement(ref: 1, role: .button, label: "Save",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let e2 = makeElement(ref: 2, role: .button, label: "Cancel",
                             bounds: CGRect(x: 100, y: 10, width: 80, height: 30))
        let map1 = makeMap(elements: [e1, e2])
        let map2 = makeMap(elements: [e1])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .label
        ]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertEqual(delta.removedRefs, [ElementRef(index: 2)])
        XCTAssertTrue(delta.added.isEmpty)
    }

    // MARK: - 6. Changed label emits `label` field

    func testBuildPayload_changedLabel_EmitsLabelField() {
        let e1a = makeElement(ref: 1, role: .button, label: "Draft",
                              bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let e1b = makeElement(ref: 1, role: .button, label: "Draft (edited)",
                              bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let map1 = makeMap(elements: [e1a])
        let map2 = makeMap(elements: [e1b])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertEqual(delta.changed.count, 1)
        let fc = delta.changed[0]
        XCTAssertEqual(fc.ref, ElementRef(index: 1))
        XCTAssertNotNil(fc.fields["label"])
        XCTAssertEqual(fc.fields["label"]?.value as? String, "Draft (edited)")
    }

    // MARK: - 7. Changed state emits `state` field

    func testBuildPayload_changedState_EmitsStateField() {
        let e1a = makeElement(ref: 1, role: .button, label: "OK", state: .enabled,
                              bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let e1b = makeElement(ref: 1, role: .button, label: "OK", state: .disabled,
                              bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let map1 = makeMap(elements: [e1a])
        let map2 = makeMap(elements: [e1b])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertEqual(delta.changed.count, 1)
        let fc = delta.changed[0]
        XCTAssertNotNil(fc.fields["state"])
        let names = fc.fields["state"]?.value as? [String]
        XCTAssertEqual(names, ["disabled"])
    }

    // MARK: - 8. Small bounds shift below tolerance is NOT emitted

    func testBuildPayload_changedBoundsSmall_BelowTolerance_NotEmitted() {
        let e1a = makeElement(ref: 1, role: .button, label: "OK",
                              bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        // 2px shift in origin — below 4 px tolerance.
        let e1b = makeElement(ref: 1, role: .button, label: "OK",
                              bounds: CGRect(x: 12, y: 11, width: 80, height: 30))
        let map1 = makeMap(elements: [e1a])
        let map2 = makeMap(elements: [e1b])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertTrue(delta.changed.isEmpty, "2 px drift should be below tolerance")
        XCTAssertEqual(delta.retained, [ElementRef(index: 1)])
    }

    // MARK: - 9. Large bounds shift above tolerance IS emitted

    func testBuildPayload_changedBoundsLarge_AboveTolerance_Emitted() {
        let e1a = makeElement(ref: 1, role: .button, label: "OK",
                              bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        // 20px shift — well above tolerance.
        let e1b = makeElement(ref: 1, role: .button, label: "OK",
                              bounds: CGRect(x: 30, y: 30, width: 80, height: 30))
        let map1 = makeMap(elements: [e1a])
        let map2 = makeMap(elements: [e1b])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertEqual(delta.changed.count, 1)
        XCTAssertNotNil(delta.changed[0].fields["bounds"])
    }

    // MARK: - 10. Identifier-tier ref uses stability (label change keeps same ref)

    func testBuildPayload_tierIdentifier_UsesRefStability() {
        // identifier tier → the ref is trusted across captures. Even a big
        // label shift should come through as a `changed` row (not a
        // removed + added pair).
        let e1a = makeElement(ref: 1, role: .button, label: "Save",
                              bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let e1b = makeElement(ref: 1, role: .button, label: "Save Document",
                              bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let map1 = makeMap(elements: [e1a])
        let map2 = makeMap(elements: [e1b])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .identifier]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertEqual(delta.changed.count, 1, "identifier-tier ref survives label change")
        XCTAssertTrue(delta.added.isEmpty)
        XCTAssertTrue(delta.removedRefs.isEmpty)
    }

    // MARK: - 11. Fallback-tier ref is always treated as new

    func testBuildPayload_tierFallback_AlwaysTreatedAsNew() {
        // Fallback tier = unstable. Even when the ref number matches by
        // coincidence, it must be emitted as added (prev as removed).
        let e1a = makeElement(ref: 1, role: .button, label: "Icon",
                              bounds: CGRect(x: 10, y: 10, width: 30, height: 30))
        let e1b = makeElement(ref: 1, role: .button, label: "Icon",
                              bounds: CGRect(x: 10, y: 10, width: 30, height: 30))
        let map1 = makeMap(elements: [e1a])
        let map2 = makeMap(elements: [e1b])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .fallback]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        // Fallback matching refs surface as added + removed (no change, no retained).
        XCTAssertTrue(delta.changed.isEmpty, "fallback tier should not emit changes")
        XCTAssertEqual(delta.added.count, 1)
        XCTAssertEqual(delta.removedRefs, [ElementRef(index: 1)])
    }

    // MARK: - 12. Position-tier ref includes bounds on ANY change

    func testBuildPayload_tierPosition_IncludesBoundsInChange() {
        // Position-tier refs must emit bounds even below the 4px tolerance
        // since the consumer uses bounds to re-anchor them.
        let e1a = makeElement(ref: 1, role: .button, label: "Button",
                              bounds: CGRect(x: 10, y: 10, width: 30, height: 30))
        let e1b = makeElement(ref: 1, role: .button, label: "Button-v2",
                              bounds: CGRect(x: 11, y: 11, width: 30, height: 30))
        let map1 = makeMap(elements: [e1a])
        let map2 = makeMap(elements: [e1b])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .position]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertEqual(delta.changed.count, 1)
        XCTAssertNotNil(delta.changed[0].fields["bounds"],
                        "position-tier ref must always ship bounds in a change")
    }

    // MARK: - 13. JSON encoding shape is valid

    func testEncode_JSON_ShapeIsValid() {
        let e1 = makeElement(ref: 1, role: .button, label: "Save",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let e2 = makeElement(ref: 2, role: .button, label: "Cancel",
                             bounds: CGRect(x: 100, y: 10, width: 80, height: 30))
        let map1 = makeMap(elements: [e1])
        let map2 = makeMap(elements: [e1, e2])
        let prevTiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let currTiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .label
        ]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: prevTiers, currentTiers: currTiers,
            sessionID: "s1", sequenceNumber: 2
        )
        let json = DeltaEncoder.encode(payload)
        let data = try! XCTUnwrap(json.data(using: .utf8))
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["session"] as? String, "s1")
        XCTAssertEqual(obj["seq"] as? Int, 2)
        XCTAssertEqual(obj["baseline"] as? Bool, false)
        let delta = try! XCTUnwrap(obj["delta"] as? [String: Any])
        XCTAssertNotNil(delta["added"])
        XCTAssertNotNil(delta["removed"])
        XCTAssertNotNil(delta["changed"])
        XCTAssertNotNil(delta["retained"])
        XCTAssertNotNil(delta["filter"])
    }

    // MARK: - 14. Text format — delta produces header + counts

    func testEncodeText_Delta_FormatsCorrectly() {
        let e1 = makeElement(ref: 1, role: .button, label: "Save",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let e2 = makeElement(ref: 2, role: .button, label: "Cancel",
                             bounds: CGRect(x: 100, y: 10, width: 80, height: 30))
        let map1 = makeMap(elements: [e1])
        let map2 = makeMap(elements: [e1, e2])
        let prevTiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let currTiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .label
        ]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: prevTiers, currentTiers: currTiers,
            sessionID: "s1", sequenceNumber: 5
        )
        let text = DeltaEncoder.encodeText(payload)
        XCTAssertTrue(text.contains("Delta #5"), "text should include delta header with seq")
        XCTAssertTrue(text.contains("+1 elements"), "text should surface added count")
        XCTAssertTrue(text.contains("@e2"), "added ref should be in text")
        XCTAssertTrue(text.contains("retained"), "retained line should be in text")
    }

    // MARK: - 15. Text format — baseline produces baseline header

    func testEncodeText_Baseline_FormatsCorrectly() {
        let e1 = makeElement(ref: 1, role: .button, label: "Save",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let map = makeMap(elements: [e1])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let payload = DeltaEncoder.buildPayload(
            previous: nil, current: map,
            previousTiers: nil, currentTiers: tiers,
            sessionID: "init", sequenceNumber: 0
        )
        let text = DeltaEncoder.encodeText(payload)
        XCTAssertTrue(text.contains("Baseline #0"))
        XCTAssertTrue(text.contains("session init"))
    }

    // MARK: - 16. Filter-stats delta reflects per-rule diffs

    func testFilterStatsDelta_CorrectDiffs() {
        // Include a non-interactive element fully outside the window on the
        // current tick but not on the previous tick. Uses `.fallback` tier so
        // the Rank 4 tier-rescue doesn't keep the outside element. That
        // drives a +1 droppedOutsideWindow delta we can verify.
        let e1 = makeElement(ref: 1, role: .staticText, label: "OK",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let offScreen = makeElement(ref: 2, role: .staticText, label: "faroff",
                                    bounds: CGRect(x: 5000, y: 5000, width: 80, height: 30))
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // Previous map has only the in-window one — nothing dropped.
        let map1 = makeMap(elements: [e1], windows: [window])
        // Current map adds the off-window one — dropped via outsideWindow.
        let map2 = makeMap(elements: [e1, offScreen], windows: [window])
        // Fallback tier on ref 2 so the filter won't rescue it.
        let prevTiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label
        ]
        let currTiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .fallback
        ]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: prevTiers, currentTiers: currTiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        XCTAssertEqual(delta.filterStats.keptNow, 1)
        XCTAssertEqual(delta.filterStats.keptBefore, 1)
        XCTAssertEqual(delta.filterStats.droppedChanges["outside"], 1,
                       "one extra outside-window drop this tick")
    }

    // MARK: - Extra: Token-savings benchmark (sanity check)

    /// Documents the realistic delta savings — emitted to the test log so the
    /// ratio stays visible next to CI output even though there's no XCTAssert.
    /// Rank 2 deliverable: for a 200-element map where only 3 change per tick,
    /// this should comfortably drop delta payload size by ~80 %.
    func testBenchmark_DeltaVsFull_200Elements_3Changes() {
        let N = 200
        var baseline: [ScreenElement] = []
        for i in 0..<N {
            baseline.append(makeElement(
                ref: i + 1, role: .button, label: "Item \(i)",
                bounds: CGRect(x: 10 + (i % 20) * 40, y: 10 + (i / 20) * 32, width: 60, height: 28)
            ))
        }
        let map1 = makeMap(elements: baseline)
        // 3 labels change.
        var modified = baseline
        modified[4]  = makeElement(ref: 5,  role: .button, label: "Item 4 edited",
                                   bounds: baseline[4].bounds!)
        modified[9]  = makeElement(ref: 10, role: .button, label: "Item 9 edited",
                                   bounds: baseline[9].bounds!)
        modified[14] = makeElement(ref: 15, role: .button, label: "Item 14 edited",
                                   bounds: baseline[14].bounds!)
        let map2 = makeMap(elements: modified)
        var tiers: [ElementRef: IdentityTier] = [:]
        for i in 0..<N { tiers[ElementRef(index: i + 1)] = .label }
        let full = SnapshotEncoder.encode(map2)
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "bench", sequenceNumber: 1
        )
        let delta = DeltaEncoder.encode(payload)
        let ratio = Double(delta.utf8.count) / Double(full.utf8.count)
        // Sanity: delta must be materially smaller. Aim for < 50% of full.
        XCTAssertLessThan(ratio, 0.5,
                          "delta should be < 50% of full; got \(ratio)")
        // Emit the measurement so the ratio shows up in test logs.
        print("[rank2-benchmark] full=\(full.utf8.count) delta=\(delta.utf8.count) ratio=\(String(format: "%.3f", ratio))")
    }

    // MARK: - 17. Meta change — app switch detected

    func testMetaChange_appSwitch_Detected() {
        let e1 = makeElement(ref: 1, role: .button, label: "X",
                             bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        let appA = AppInfo(name: "Safari", bundleID: "com.apple.Safari", pid: 100)
        let appB = AppInfo(name: "Mail", bundleID: "com.apple.mail", pid: 200)
        let map1 = makeMap(elements: [e1], focusedApp: appA)
        let map2 = makeMap(elements: [e1], focusedApp: appB)
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let payload = DeltaEncoder.buildPayload(
            previous: map1, current: map2,
            previousTiers: tiers, currentTiers: tiers,
            sessionID: "s1", sequenceNumber: 1
        )
        let delta = try! XCTUnwrap(payload.delta)
        let meta = try! XCTUnwrap(delta.metaChanges)
        XCTAssertEqual(meta.focusedApp, "Mail")
    }

    // MARK: - Fixture helpers

    private func makeMap(
        elements: [ScreenElement],
        windows: [WindowInfo]? = nil,
        focusedApp: AppInfo? = nil
    ) -> ScreenMap {
        ScreenMap(
            timestamp: Date(),
            captureMs: 1,
            displays: [
                DisplayInfo(
                    id: 1, index: 0, name: "Main", origin: .zero,
                    width: 1920, height: 1080, scale: 2, isMain: true
                )
            ],
            focusedApp: focusedApp ?? AppInfo(name: "Test", bundleID: "com.test", pid: 1),
            windows: windows ?? [
                WindowInfo(
                    index: 0, appName: focusedApp?.name ?? "Test",
                    appBundleID: focusedApp?.bundleID ?? "com.test",
                    title: "Win", bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    isFocused: true, layer: 0, displayIndex: 0
                )
            ],
            elements: elements,
            navigation: nil,
            safety: .empty,
            metadata: CaptureMetadata(
                axCoveragePercent: 1, ocrUsed: false,
                elementCount: elements.count,
                interactiveCount: elements.filter { $0.role.isInteractive }.count,
                offScreenHint: nil
            )
        )
    }

    private func makeElement(
        ref: Int,
        role: ElementRole,
        label: String,
        state: ElementState = .enabled,
        bounds: CGRect?,
        parentRef: ElementRef? = nil,
        depth: Int = 0
    ) -> ScreenElement {
        ScreenElement(
            ref: ElementRef(index: ref),
            role: role,
            subrole: "",
            label: label,
            value: "",
            bounds: bounds,
            clickPoint: bounds.map { CGPoint(x: $0.midX, y: $0.midY) },
            state: state,
            actions: role.isInteractive ? [.press] : [],
            parentRef: parentRef,
            depth: depth,
            source: .accessibility,
            confidence: 1.0,
            appBundleID: "com.test",
            windowIndex: 0,
            displayIndex: 0
        )
    }

    private func makeWindow(bounds: CGRect, focused: Bool = true) -> WindowInfo {
        WindowInfo(
            index: 0, appName: "Test", appBundleID: "com.test",
            title: "Win", bounds: bounds, isFocused: focused, layer: 0,
            displayIndex: 0
        )
    }
}
