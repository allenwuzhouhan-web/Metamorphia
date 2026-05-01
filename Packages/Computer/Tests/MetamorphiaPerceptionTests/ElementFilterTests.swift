import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

/// Rank 1 — Viewport + visibility filter pre-encoding.
///
/// These tests exercise every rule in `ElementFilter.apply`:
/// 1. Window bounds           → `droppedOutsideWindow`
/// 2. Min-area                → `droppedTooSmall`
/// 3. Scroll clip             → `droppedClipped`
/// 4. Occlusion               → `droppedOccluded`
/// 5. Non-interactive depth   → `droppedDeep`
///
/// Plus the integration surface:
/// - `alwaysKeepInteractive` / `alwaysKeepRoles` / `pinnedRefs`
/// - Rank-4 identity-tier rescue (label/identifier tier)
/// - TextFormatter + SnapshotEncoder filter-summary emission
final class ElementFilterTests: XCTestCase {

    // MARK: - Test 1: default keeps everything inside a focused window

    func testDefault_keepsAllElementsInsideFocusedWindow() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let a = makeElement(ref: 1, role: .button, label: "OK",
                            bounds: CGRect(x: 100, y: 100, width: 60, height: 24))
        let b = makeElement(ref: 2, role: .staticText, label: "Hello",
                            bounds: CGRect(x: 200, y: 200, width: 80, height: 16))
        let map = makeMap(elements: [a, b], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        XCTAssertEqual(result.totalKept, 2)
        XCTAssertEqual(result.totalDropped, 0)
    }

    // MARK: - Test 2: drops element fully outside the only window

    func testDropsElementsFullyOutsideWindow() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // staticText — not interactive, no always-keep role, real bounds way outside.
        let outside = makeElement(ref: 1, role: .staticText, label: "faroff",
                                  bounds: CGRect(x: 5000, y: 5000, width: 50, height: 20))
        let inside = makeElement(ref: 2, role: .staticText, label: "inside",
                                 bounds: CGRect(x: 20, y: 20, width: 100, height: 20))
        let map = makeMap(elements: [outside, inside], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        XCTAssertEqual(result.totalKept, 1)
        XCTAssertEqual(result.droppedOutsideWindow, 1)
        XCTAssertEqual(result.kept.first?.ref, ElementRef(index: 2))
    }

    // MARK: - Test 3: alwaysKeepInteractive keeps interactive outside window

    func testKeepsInteractiveOutsideWindow_WhenPolicyAllows() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let outsideBtn = makeElement(ref: 1, role: .button, label: "Far",
                                     bounds: CGRect(x: 5000, y: 5000, width: 60, height: 24))
        let map = makeMap(elements: [outsideBtn], windows: [window])
        // alwaysKeepInteractive = true (default)
        let result = ElementFilter.apply(map.elements, in: map)
        XCTAssertEqual(result.totalKept, 1)
        XCTAssertEqual(result.droppedOutsideWindow, 0)
    }

    // MARK: - Test 4: policy disabling alwaysKeepInteractive drops outside-window buttons

    func testDropsInteractiveOutsideWindow_WhenPolicyDisables() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let outsideBtn = makeElement(ref: 1, role: .button, label: "Far",
                                     bounds: CGRect(x: 5000, y: 5000, width: 60, height: 24))
        let map = makeMap(elements: [outsideBtn], windows: [window])
        var policy = FilterPolicy.default
        policy.alwaysKeepInteractive = false
        let result = ElementFilter.apply(map.elements, in: map, policy: policy)
        XCTAssertEqual(result.totalKept, 0)
        XCTAssertEqual(result.droppedOutsideWindow, 1)
    }

    // MARK: - Test 5: drops tiny elements under minArea

    func testDropsTinyElements_BelowMinArea() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // 1x1 — 1 pixel² < default 4.0. Non-interactive so no always-keep rescue.
        let tiny = makeElement(ref: 1, role: .staticText, label: "t",
                               bounds: CGRect(x: 10, y: 10, width: 1, height: 1))
        let map = makeMap(elements: [tiny], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        XCTAssertEqual(result.totalKept, 0)
        XCTAssertEqual(result.droppedTooSmall, 1)
    }

    // MARK: - Test 6: virtualized interactive rows with zero bounds are kept

    func testDoesNotDropInteractiveWithZeroBounds() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // zero-width/height bounds — typical of virtualized AX rows before scroll.
        let zero = makeElement(ref: 1, role: .button, label: "Row 42", bounds: .zero)
        // nil bounds is a separate case.
        let none = makeElement(ref: 2, role: .button, label: "NoBounds", bounds: nil)
        let map = makeMap(elements: [zero, none], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        XCTAssertEqual(result.totalKept, 2)
        XCTAssertEqual(result.droppedTooSmall, 0)
    }

    // MARK: - Test 7: scroll-clip drops when visible fraction < threshold

    func testScrollClip_dropsWhenVisibleFractionTooLow() {
        // scrollArea 100x100, child 100x100 positioned almost entirely outside.
        // Child's bounds (80, 80, 100, 100) intersect scroll (0, 0, 100, 100) in
        // a 20x20 = 400 px² rect, so visible fraction = 400 / 10000 = 0.04 < 0.2.
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let scroll = makeElement(ref: 1, role: .scrollArea, label: "list",
                                 bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        // staticText so interactive-rescue doesn't kick in.
        let child = makeElement(ref: 2, role: .staticText, label: "row",
                                bounds: CGRect(x: 80, y: 80, width: 100, height: 100),
                                parentRef: ElementRef(index: 1))
        let map = makeMap(elements: [scroll, child], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        // scrollArea itself has role .scrollArea → not alwaysKeepRole, not
        // interactive — it may pass (large, in-window). We verify at least the
        // clipped child was dropped.
        XCTAssertEqual(result.droppedClipped, 1)
        XCTAssertFalse(result.kept.contains { $0.ref == ElementRef(index: 2) })
    }

    // MARK: - Test 8: scroll-clip keeps when visible fraction above threshold

    func testScrollClip_keepsWhenVisibleFractionAbove() {
        // Child (0, 0, 100, 100) entirely inside scroll (0, 0, 100, 100) →
        // visible fraction = 1.0 → kept.
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let scroll = makeElement(ref: 1, role: .scrollArea, label: "list",
                                 bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let child = makeElement(ref: 2, role: .staticText, label: "row",
                                bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                parentRef: ElementRef(index: 1))
        let map = makeMap(elements: [scroll, child], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        XCTAssertTrue(result.kept.contains { $0.ref == ElementRef(index: 2) })
        XCTAssertEqual(result.droppedClipped, 0)
    }

    // MARK: - Test 9: occlusion drops elements covered > 90%

    func testOcclusion_dropsElementCoveredBy90Percent() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // Two non-interactive elements. The first sits at windowIndex 0 depth 0
        // (bottom layer); the second at windowIndex 0 depth 1 (front) and fully
        // covers it.
        let back = makeElement(ref: 1, role: .staticText, label: "hidden",
                               bounds: CGRect(x: 10, y: 10, width: 100, height: 100),
                               depth: 0)
        let front = makeElement(ref: 2, role: .staticText, label: "cover",
                                bounds: CGRect(x: 10, y: 10, width: 100, height: 100),
                                depth: 1)
        let map = makeMap(elements: [back, front], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        // `back` should be dropped; `front` (bigger depth) stays.
        XCTAssertFalse(result.kept.contains { $0.ref == ElementRef(index: 1) },
                       "fully-covered background element should be dropped by occlusion")
        XCTAssertEqual(result.droppedOccluded, 1)
        XCTAssertTrue(result.kept.contains { $0.ref == ElementRef(index: 2) })
    }

    // MARK: - Test 10: partial occlusion keeps the element

    func testOcclusion_keepsPartiallyVisible() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let back = makeElement(ref: 1, role: .staticText, label: "partial",
                               bounds: CGRect(x: 10, y: 10, width: 100, height: 100),
                               depth: 0)
        // front covers only 50% horizontally → 50% area → < 90% threshold.
        let front = makeElement(ref: 2, role: .staticText, label: "half",
                                bounds: CGRect(x: 10, y: 10, width: 50, height: 100),
                                depth: 1)
        let map = makeMap(elements: [back, front], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        XCTAssertTrue(result.kept.contains { $0.ref == ElementRef(index: 1) })
        XCTAssertTrue(result.kept.contains { $0.ref == ElementRef(index: 2) })
        XCTAssertEqual(result.droppedOccluded, 0)
    }

    // MARK: - Test 11: depth decay produces correct priority ordering

    func testDepthDecay_emitsCorrectPriorities() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let shallow = makeElement(ref: 1, role: .staticText, label: "shallow",
                                  bounds: CGRect(x: 10, y: 10, width: 100, height: 100),
                                  depth: 0)
        let deep = makeElement(ref: 2, role: .staticText, label: "deep",
                               bounds: CGRect(x: 10, y: 300, width: 100, height: 100),
                               depth: 5)
        let map = makeMap(elements: [shallow, deep], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        // With decay=0.15, depth=0 → 1.0, depth=5 → 1 / (1+0.75) ≈ 0.571
        let shallowP = result.priorityByRef[ElementRef(index: 1)] ?? 0
        let deepP = result.priorityByRef[ElementRef(index: 2)] ?? 0
        XCTAssertGreaterThan(shallowP, deepP)
        XCTAssertEqual(shallowP, 1.0, accuracy: 0.001)
        XCTAssertEqual(deepP, 1.0 / (1.0 + 0.15 * 5), accuracy: 0.001)
    }

    // MARK: - Test 12: alwaysKeepRoles (.dialog) always kept

    func testAlwaysKeepRoles_dialogAlwaysKept() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // Dialog positioned completely outside the window, tiny, deep — nothing
        // should evict it.
        let dialog = makeElement(ref: 1, role: .dialog, label: "Confirm",
                                 bounds: CGRect(x: 5000, y: 5000, width: 1, height: 1),
                                 depth: 99)
        let map = makeMap(elements: [dialog], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        XCTAssertEqual(result.totalKept, 1)
        XCTAssertEqual(result.kept.first?.ref, ElementRef(index: 1))
    }

    // MARK: - Test 13: pinnedRefs never dropped

    func testPinnedRefs_neverDropped() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // Non-interactive, outside window, tiny — would be dropped by three
        // rules at once. Pinning rescues it.
        let pinned = makeElement(ref: 7, role: .staticText, label: "pinned",
                                 bounds: CGRect(x: 5000, y: 5000, width: 1, height: 1))
        var policy = FilterPolicy.default
        policy.pinnedRefs = [ElementRef(index: 7)]
        let map = makeMap(elements: [pinned], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map, policy: policy)
        XCTAssertEqual(result.totalKept, 1)
        XCTAssertEqual(result.droppedOutsideWindow, 0)
        XCTAssertEqual(result.droppedTooSmall, 0)
    }

    // MARK: - Test 14: FilterResult counts are correct

    func testFilterResult_countsAreCorrect() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // 1 kept inside, 1 outside, 1 tiny, 1 clipped, 1 deep.
        let inside = makeElement(ref: 1, role: .staticText, label: "in",
                                 bounds: CGRect(x: 10, y: 10, width: 80, height: 40))
        let outside = makeElement(ref: 2, role: .staticText, label: "out",
                                  bounds: CGRect(x: 5000, y: 5000, width: 80, height: 40))
        let tiny = makeElement(ref: 3, role: .staticText, label: "t",
                               bounds: CGRect(x: 20, y: 20, width: 1, height: 1))
        let scroll = makeElement(ref: 4, role: .scrollArea, label: "list",
                                 bounds: CGRect(x: 0, y: 100, width: 100, height: 100))
        let clipped = makeElement(ref: 5, role: .staticText, label: "clip",
                                  bounds: CGRect(x: 80, y: 180, width: 100, height: 100),
                                  parentRef: ElementRef(index: 4))
        let deep = makeElement(ref: 6, role: .staticText, label: "deep",
                               bounds: CGRect(x: 50, y: 50, width: 80, height: 20),
                               depth: 15)
        let map = makeMap(elements: [inside, outside, tiny, scroll, clipped, deep], windows: [window])
        let result = ElementFilter.apply(map.elements, in: map)
        // Count expectations.
        XCTAssertEqual(result.totalInput, 6)
        XCTAssertEqual(result.droppedOutsideWindow, 1)
        XCTAssertEqual(result.droppedTooSmall, 1)
        XCTAssertEqual(result.droppedClipped, 1)
        XCTAssertEqual(result.droppedDeep, 1)
        // scroll (ref 4) is inside, container role. It is non-interactive depth=0,
        // survives clip/area/window. So kept = {inside, scroll}. totalKept = 2.
        XCTAssertEqual(result.totalKept, 2)
        XCTAssertEqual(result.totalDropped, 4)
    }

    // MARK: - Test 15: stable-ref demotion — not dropped, priority lowered

    func testStableRefDemotion_notDropped_butPriorityLowered() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // Non-interactive element outside the window — default filter would drop it.
        let el = makeElement(ref: 42, role: .staticText, label: "StableCopy",
                             bounds: CGRect(x: 5000, y: 5000, width: 80, height: 20),
                             depth: 2)
        let map = makeMap(elements: [el], windows: [window])

        // Tier snapshot says this ref is identified at Tier-2 label.
        let tierSnapshot: [ElementRef: IdentityTier] = [ElementRef(index: 42): .label]

        let result = ElementFilter.apply(
            map.elements, in: map,
            policy: .default,
            tierSnapshot: tierSnapshot
        )
        // Rescued — not dropped.
        XCTAssertEqual(result.totalKept, 1)
        XCTAssertEqual(result.droppedOutsideWindow, 0)
        // Priority demoted below 0.3.
        let p = result.priorityByRef[ElementRef(index: 42)] ?? 1.0
        XCTAssertLessThan(p, 0.3)
    }

    // MARK: - Test 16: aggressive drops more than default

    func testFilterPolicy_aggressive_dropsMore_thanDefault() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        // Elements that survive .default but not .aggressive:
        //   - 10x10 staticText (area 100, > 4 but < 16 → default keeps, aggressive drops)
        //   - deep=8 staticText (depth <= default 10 but > aggressive 6 → default keeps, aggressive drops)
        let smallOK = makeElement(ref: 1, role: .staticText, label: "a",
                                  bounds: CGRect(x: 10, y: 10, width: 3, height: 3))
        let mediumDeep = makeElement(ref: 2, role: .staticText, label: "b",
                                     bounds: CGRect(x: 30, y: 30, width: 80, height: 20),
                                     depth: 8)
        let map = makeMap(elements: [smallOK, mediumDeep], windows: [window])
        let def = ElementFilter.apply(map.elements, in: map, policy: .default)
        let agg = ElementFilter.apply(map.elements, in: map, policy: .aggressive)
        XCTAssertGreaterThan(agg.totalDropped, def.totalDropped,
            "aggressive policy must drop strictly more than default for this mixed fixture")
    }

    // MARK: - Test 17: TextFormatter emits filter summary when anything dropped

    func testTextFormatter_emitsFilterSummary_whenAnyDropped() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let inside = makeElement(ref: 1, role: .staticText, label: "in",
                                 bounds: CGRect(x: 10, y: 10, width: 80, height: 40))
        let outside = makeElement(ref: 2, role: .staticText, label: "out",
                                  bounds: CGRect(x: 5000, y: 5000, width: 80, height: 40))
        let map = makeMap(elements: [inside, outside], windows: [window])
        let text = TextFormatter.format(map)
        XCTAssertTrue(text.contains("[filtered:"),
            "expected filter summary line; got:\n\(text)")
        XCTAssertTrue(text.contains("kept 1/2"),
            "expected 'kept 1/2' in summary; got:\n\(text)")
        XCTAssertTrue(text.contains("1 window"),
            "expected '1 window' drop reason; got:\n\(text)")
    }

    // MARK: - Test 18: TextFormatter omits summary when nothing dropped

    func testTextFormatter_doesNotEmitSummary_whenNothingDropped() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let a = makeElement(ref: 1, role: .button, label: "OK",
                            bounds: CGRect(x: 10, y: 10, width: 80, height: 24))
        let map = makeMap(elements: [a], windows: [window])
        let text = TextFormatter.format(map)
        XCTAssertFalse(text.contains("[filtered:"),
            "no summary expected when nothing was dropped; got:\n\(text)")
    }

    // MARK: - Test 19: SnapshotEncoder emits filter stats when anything dropped

    func testSnapshotEncoder_emitsFilterStats_whenAnyDropped() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let inside = makeElement(ref: 1, role: .staticText, label: "in",
                                 bounds: CGRect(x: 10, y: 10, width: 80, height: 40))
        let outside = makeElement(ref: 2, role: .staticText, label: "out",
                                  bounds: CGRect(x: 5000, y: 5000, width: 80, height: 40))
        let map = makeMap(elements: [inside, outside], windows: [window])
        let json = SnapshotEncoder.encode(map)
        XCTAssertTrue(json.contains("\"filter\""),
            "expected filter stats block in JSON; got:\n\(json)")
        XCTAssertTrue(json.contains("\"outside\":1"),
            "expected outside drop count in JSON; got:\n\(json)")
        XCTAssertTrue(json.contains("\"kept\":1"))
        XCTAssertTrue(json.contains("\"total\":2"))
    }

    // MARK: - Test 20: SnapshotEncoder omits filter stats for pass-through

    func testSnapshotEncoder_omitsFilterStats_whenPassThrough() {
        let window = makeWindow(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let a = makeElement(ref: 1, role: .button, label: "OK",
                            bounds: CGRect(x: 10, y: 10, width: 80, height: 24))
        let map = makeMap(elements: [a], windows: [window])
        let json = SnapshotEncoder.encode(map)
        XCTAssertFalse(json.contains("\"filter\""),
            "no filter block expected when nothing was dropped; got:\n\(json)")
    }

    // MARK: - Helper-level assertions (extra coverage)

    func testInternalHelper_isOutsideAnyWindow() {
        let w = [makeWindow(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))]
        let inside = makeElement(ref: 1, role: .staticText, label: "",
                                 bounds: CGRect(x: 20, y: 20, width: 10, height: 10))
        let outside = makeElement(ref: 2, role: .staticText, label: "",
                                  bounds: CGRect(x: 200, y: 200, width: 10, height: 10))
        let noBounds = makeElement(ref: 3, role: .staticText, label: "", bounds: nil)
        XCTAssertFalse(ElementFilter.isOutsideAnyWindow(inside, windows: w))
        XCTAssertTrue(ElementFilter.isOutsideAnyWindow(outside, windows: w))
        XCTAssertFalse(ElementFilter.isOutsideAnyWindow(noBounds, windows: w))
    }

    func testInternalHelper_isOccluded_exact() {
        let el = makeElement(ref: 1, role: .staticText, label: "",
                             bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let fullCover = makeElement(ref: 2, role: .staticText, label: "",
                                    bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let halfCover = makeElement(ref: 3, role: .staticText, label: "",
                                    bounds: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertTrue(ElementFilter.isOccluded(el, by: [fullCover], maxFraction: 0.9))
        XCTAssertFalse(ElementFilter.isOccluded(el, by: [halfCover], maxFraction: 0.9))
    }

    func testInternalHelper_depthPriority_monotonic() {
        let a = makeElement(ref: 1, role: .staticText, label: "", bounds: nil, depth: 0)
        let b = makeElement(ref: 2, role: .staticText, label: "", bounds: nil, depth: 1)
        let c = makeElement(ref: 3, role: .staticText, label: "", bounds: nil, depth: 5)
        let pa = ElementFilter.depthPriority(a, decay: 0.15)
        let pb = ElementFilter.depthPriority(b, decay: 0.15)
        let pc = ElementFilter.depthPriority(c, decay: 0.15)
        XCTAssertGreaterThan(pa, pb)
        XCTAssertGreaterThan(pb, pc)
    }

    func testInternalHelper_clipByParents() {
        // Parent scroll (0,0,100,100), child staticText at (50,50,100,100).
        // Child's visible intersection = (50,50,50,50) = 2500 / 10000 = 0.25.
        let scroll = makeElement(ref: 1, role: .scrollArea, label: "",
                                 bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let child = makeElement(ref: 2, role: .staticText, label: "",
                                bounds: CGRect(x: 50, y: 50, width: 100, height: 100),
                                parentRef: ElementRef(index: 1))
        let lookup: [ElementRef: ScreenElement] = [
            ElementRef(index: 1): scroll,
            ElementRef(index: 2): child
        ]
        let visible = ElementFilter.clipByParents(child, parents: lookup)
        XCTAssertEqual(visible, 0.25, accuracy: 0.001)
    }

    // MARK: - Fixture helpers

    /// Build a synthetic ScreenMap with the given elements/windows/displays.
    /// Single-display default so most tests don't have to spell out DisplayInfo.
    private func makeMap(
        elements: [ScreenElement],
        windows: [WindowInfo] = [],
        displays: [DisplayInfo] = [
            DisplayInfo(
                id: 1, index: 0, name: "Main", origin: .zero,
                width: 1920, height: 1080, scale: 2, isMain: true
            )
        ]
    ) -> ScreenMap {
        ScreenMap(
            timestamp: Date(),
            captureMs: 1,
            displays: displays,
            focusedApp: AppInfo(name: "Test", bundleID: "com.test", pid: 1),
            windows: windows,
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
        bounds: CGRect?,
        parentRef: ElementRef? = nil,
        depth: Int = 0,
        windowIndex: Int = 0
    ) -> ScreenElement {
        ScreenElement(
            ref: ElementRef(index: ref),
            role: role,
            subrole: "",
            label: label,
            value: "",
            bounds: bounds,
            clickPoint: bounds.map { CGPoint(x: $0.midX, y: $0.midY) },
            state: .enabled,
            actions: role.isInteractive ? [.press] : [],
            parentRef: parentRef,
            depth: depth,
            source: .accessibility,
            confidence: 1.0,
            appBundleID: "com.test",
            windowIndex: windowIndex,
            displayIndex: 0
        )
    }

    private func makeWindow(bounds: CGRect, index: Int = 0, focused: Bool = true) -> WindowInfo {
        WindowInfo(
            index: index,
            appName: "Test",
            appBundleID: "com.test",
            title: "Win",
            bounds: bounds,
            isFocused: focused,
            layer: 0,
            displayIndex: 0
        )
    }
}
