import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

/// Rank 6 — Query engine execution tests.
///
/// These exercise the end-to-end `QueryEngine.execute` path: filter-first
/// pipeline, per-predicate scoring, sort orders, truncation. Each test builds
/// a small fixture `ScreenMap` so the asserts stay local.
final class QueryEngineTests: XCTestCase {

    // MARK: - Basic matching

    func testExecute_noMatches_returnsEmpty() throws {
        let window = makeWindow()
        let el = makeElement(ref: 1, role: .staticText, label: "Hello",
                             bounds: CGRect(x: 10, y: 10, width: 100, height: 20))
        let map = makeMap(elements: [el], windows: [window])
        let results = try QueryEngine.query("role:button", in: map, tiers: [:])
        XCTAssertTrue(results.isEmpty)
    }

    func testExecute_roleButton_matchesButtonsOnly() throws {
        let window = makeWindow()
        let btn = makeElement(ref: 1, role: .button, label: "OK",
                              bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let txt = makeElement(ref: 2, role: .staticText, label: "Hello",
                              bounds: CGRect(x: 10, y: 40, width: 100, height: 20))
        let map = makeMap(elements: [btn, txt], windows: [window])
        let results = try QueryEngine.query("role:button", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, btn.ref)
    }

    // MARK: - Label matching

    func testExecute_labelEquals_exactMatch() throws {
        let window = makeWindow()
        let a = makeElement(ref: 1, role: .button, label: "Save",
                            bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let b = makeElement(ref: 2, role: .button, label: "Save As",
                            bounds: CGRect(x: 80, y: 10, width: 60, height: 24))
        let map = makeMap(elements: [a, b], windows: [window])
        let results = try QueryEngine.query("label:Save", in: map, tiers: [:])
        // Colon is case-insensitive equals — only "Save" matches exactly.
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, a.ref)
    }

    func testExecute_labelContains_partialMatch_caseInsensitive() throws {
        let window = makeWindow()
        let a = makeElement(ref: 1, role: .button, label: "SAVE NOW",
                            bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let b = makeElement(ref: 2, role: .button, label: "Cancel",
                            bounds: CGRect(x: 80, y: 10, width: 60, height: 24))
        let map = makeMap(elements: [a, b], windows: [window])
        let results = try QueryEngine.query("label*save", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, a.ref)
    }

    func testExecute_labelRegex_pattern() throws {
        let window = makeWindow()
        let a = makeElement(ref: 1, role: .button, label: "Sign In",
                            bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let b = makeElement(ref: 2, role: .button, label: "Submit",
                            bounds: CGRect(x: 80, y: 10, width: 60, height: 24))
        let map = makeMap(elements: [a, b], windows: [window])
        let results = try QueryEngine.query("label~/^Sign.*/", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, a.ref)
    }

    // MARK: - Hierarchy

    func testExecute_parentLabel_ancestorLookup() throws {
        let window = makeWindow()
        let toolbar = makeElement(ref: 1, role: .toolbar, label: "Toolbar",
                                  bounds: CGRect(x: 0, y: 0, width: 500, height: 40))
        let button = makeElement(ref: 2, role: .button, label: "Save",
                                 bounds: CGRect(x: 10, y: 10, width: 60, height: 24),
                                 parentRef: toolbar.ref, depth: 1)
        let map = makeMap(elements: [toolbar, button], windows: [window])
        let results = try QueryEngine.query("parent:Toolbar", in: map, tiers: [:])
        // Only the button has Toolbar as parent; toolbar itself does not.
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, button.ref)
    }

    func testExecute_inContainer_deepAncestor() throws {
        let window = makeWindow()
        let sidebar = makeElement(ref: 1, role: .list, label: "Sidebar",
                                  bounds: CGRect(x: 0, y: 0, width: 200, height: 500))
        let group = makeElement(ref: 2, role: .group, label: "Row A",
                                bounds: CGRect(x: 0, y: 0, width: 200, height: 40),
                                parentRef: sidebar.ref, depth: 1)
        let button = makeElement(ref: 3, role: .button, label: "Open",
                                 bounds: CGRect(x: 160, y: 5, width: 30, height: 30),
                                 parentRef: group.ref, depth: 2)
        let map = makeMap(elements: [sidebar, group, button], windows: [window])
        let results = try QueryEngine.query("in:Sidebar", in: map, tiers: [:])
        // Both `group` and `button` have Sidebar as an ancestor.
        let refs = Set(results.map { $0.ref })
        XCTAssertTrue(refs.contains(group.ref))
        XCTAssertTrue(refs.contains(button.ref))
        XCTAssertFalse(refs.contains(sidebar.ref))
    }

    // MARK: - Depth

    func testExecute_depthGreaterThan() throws {
        let window = makeWindow()
        let a = makeElement(ref: 1, role: .button, label: "Shallow",
                            bounds: CGRect(x: 10, y: 10, width: 60, height: 24), depth: 1)
        let b = makeElement(ref: 2, role: .button, label: "Deep",
                            bounds: CGRect(x: 80, y: 10, width: 60, height: 24), depth: 5)
        let map = makeMap(elements: [a, b], windows: [window])
        let results = try QueryEngine.query("depth:>3", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, b.ref)
    }

    // MARK: - Visibility / interactivity

    func testExecute_visibleOnly_excludesOffScreen() throws {
        let window = makeWindow()
        let on = makeElement(ref: 1, role: .button, label: "OnScreen",
                             bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        var off = makeElement(ref: 2, role: .button, label: "Offscreen",
                              bounds: CGRect(x: 80, y: 10, width: 60, height: 24))
        off = withState(off, state: [.enabled, .offScreen])
        let map = makeMap(elements: [on, off], windows: [window])
        let results = try QueryEngine.query("visible:true", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, on.ref)
    }

    func testExecute_interactiveOnly() throws {
        let window = makeWindow()
        let btn = makeElement(ref: 1, role: .button, label: "OK",
                              bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let txt = makeElement(ref: 2, role: .staticText, label: "Hello",
                              bounds: CGRect(x: 10, y: 40, width: 100, height: 20))
        let map = makeMap(elements: [btn, txt], windows: [window])
        let results = try QueryEngine.query("interactive:true", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, btn.ref)
    }

    // MARK: - State + action

    func testExecute_stateFilter() throws {
        let window = makeWindow()
        let a = makeElement(ref: 1, role: .button, label: "Enabled",
                            bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        var b = makeElement(ref: 2, role: .button, label: "Disabled",
                            bounds: CGRect(x: 80, y: 10, width: 60, height: 24))
        b = withState(b, state: .disabled)
        let map = makeMap(elements: [a, b], windows: [window])
        let results = try QueryEngine.query("state:enabled", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, a.ref)
    }

    // MARK: - Display index

    func testExecute_displayIndexFilter() throws {
        let window = makeWindow()
        var a = makeElement(ref: 1, role: .button, label: "A",
                            bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        a = withDisplayIndex(a, displayIndex: 1)
        let b = makeElement(ref: 2, role: .button, label: "B",
                            bounds: CGRect(x: 80, y: 10, width: 60, height: 24))
        let map = makeMap(elements: [a, b], windows: [window])
        let results = try QueryEngine.query("display:1", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, a.ref)
    }

    // MARK: - Near ref

    func testExecute_nearRef_withinRadius() throws {
        let window = makeWindow()
        let anchor = makeElement(ref: 5, role: .button, label: "Anchor",
                                 bounds: CGRect(x: 100, y: 100, width: 40, height: 40))
        let close = makeElement(ref: 6, role: .button, label: "Close",
                                bounds: CGRect(x: 140, y: 100, width: 40, height: 40))
        let far = makeElement(ref: 7, role: .button, label: "Far",
                              bounds: CGRect(x: 500, y: 500, width: 40, height: 40))
        let map = makeMap(elements: [anchor, close, far], windows: [window])
        let results = try QueryEngine.query("near:@e5:100", in: map, tiers: [:])
        let refs = Set(results.map { $0.ref })
        // Anchor itself is distance 0 from itself; `close` is distance 40.
        // `far` is far outside the 100pt radius.
        XCTAssertTrue(refs.contains(anchor.ref))
        XCTAssertTrue(refs.contains(close.ref))
        XCTAssertFalse(refs.contains(far.ref))
    }

    // MARK: - Combined predicates

    func testExecute_combinesMultiplePredicates_AND() throws {
        let window = makeWindow()
        let toolbar = makeElement(ref: 1, role: .toolbar, label: "Toolbar",
                                  bounds: CGRect(x: 0, y: 0, width: 500, height: 40))
        let saveBtn = makeElement(ref: 2, role: .button, label: "Save",
                                  bounds: CGRect(x: 10, y: 10, width: 60, height: 24),
                                  parentRef: toolbar.ref, depth: 1)
        let saveMenu = makeElement(ref: 3, role: .menuItem, label: "Save",
                                   bounds: CGRect(x: 0, y: 40, width: 100, height: 20))
        let cancelBtn = makeElement(ref: 4, role: .button, label: "Cancel",
                                    bounds: CGRect(x: 80, y: 10, width: 60, height: 24),
                                    parentRef: toolbar.ref, depth: 1)
        let map = makeMap(elements: [toolbar, saveBtn, saveMenu, cancelBtn], windows: [window])
        let results = try QueryEngine.query("role:button label*save in:Toolbar", in: map, tiers: [:])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, saveBtn.ref)
    }

    // MARK: - Truncation

    func testExecute_maxResults_truncates() throws {
        let window = makeWindow()
        var elements: [ScreenElement] = []
        for i in 0..<10 {
            elements.append(makeElement(
                ref: i + 1, role: .button, label: "Btn\(i)",
                bounds: CGRect(x: Double(i * 60), y: 10, width: 60, height: 24)
            ))
        }
        let map = makeMap(elements: elements, windows: [window])
        var options = QueryOptions()
        options.maxResults = 3
        let results = QueryEngine.execute(
            try QueryEngine.parse("role:button"),
            in: map, tiers: [:], options: options
        )
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Sort orders

    func testExecute_sortByMatchScore() throws {
        let window = makeWindow()
        let a = makeElement(ref: 1, role: .button, label: "Save",
                            bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let b = makeElement(ref: 2, role: .button, label: "Save As",
                            bounds: CGRect(x: 80, y: 10, width: 60, height: 24))
        let map = makeMap(elements: [a, b], windows: [window])
        var options = QueryOptions()
        options.sortBy = .matchScore
        // Use a fuzzy predicate so scores differ.
        let selector = Selector(raw: "labelFuzzy", predicates: [
            .labelFuzzyMatches("Save", threshold: 0.3),
        ])
        let results = QueryEngine.execute(selector, in: map, tiers: [:], options: options)
        XCTAssertEqual(results.count, 2)
        // "Save" has higher similarity to "Save" than "Save As".
        XCTAssertEqual(results[0].ref, a.ref)
        XCTAssertGreaterThanOrEqual(results[0].matchScore, results[1].matchScore)
    }

    func testExecute_sortByTopToBottom() throws {
        let window = makeWindow()
        let bottom = makeElement(ref: 1, role: .button, label: "Bottom",
                                 bounds: CGRect(x: 10, y: 500, width: 60, height: 24))
        let top = makeElement(ref: 2, role: .button, label: "Top",
                              bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let map = makeMap(elements: [bottom, top], windows: [window])
        var options = QueryOptions()
        options.sortBy = .topToBottom
        let results = QueryEngine.execute(
            try QueryEngine.parse("role:button"),
            in: map, tiers: [:], options: options
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].ref, top.ref)
        XCTAssertEqual(results[1].ref, bottom.ref)
    }

    func testExecute_sortByStabilityScore() throws {
        let window = makeWindow()
        let a = makeElement(ref: 1, role: .button, label: "A",
                            bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let b = makeElement(ref: 2, role: .button, label: "B",
                            bounds: CGRect(x: 80, y: 10, width: 60, height: 24))
        let map = makeMap(elements: [a, b], windows: [window])
        let tiers: [ElementRef: IdentityTier] = [
            a.ref: .fallback,       // lower score
            b.ref: .identifier,     // higher score
        ]
        var options = QueryOptions()
        options.sortBy = .stabilityScore
        let results = QueryEngine.execute(
            try QueryEngine.parse("role:button"),
            in: map, tiers: tiers, options: options
        )
        XCTAssertEqual(results.count, 2)
        // identifier-tier should come first.
        XCTAssertEqual(results[0].ref, b.ref)
        XCTAssertEqual(results[1].ref, a.ref)
    }

    // MARK: - Negation — engine side

    /// `!role:button` triggers the NOT-sentinel path because `role` has no
    /// natural inverse predicate. Verify the engine correctly inverts.
    func testExecute_negatedRole_excludesButtons() throws {
        let window = makeWindow()
        let btn = makeElement(ref: 1, role: .button, label: "OK",
                              bounds: CGRect(x: 10, y: 10, width: 60, height: 24))
        let txt = makeElement(ref: 2, role: .staticText, label: "Hello",
                              bounds: CGRect(x: 10, y: 40, width: 100, height: 20))
        let map = makeMap(elements: [btn, txt], windows: [window])
        // Turn off interactive filter so staticText survives.
        var options = QueryOptions()
        options.applyFilter = false
        let results = QueryEngine.execute(
            try QueryEngine.parse("!role:button"),
            in: map, tiers: [:], options: options
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, txt.ref)
    }

    // MARK: - Filter integration

    func testExecute_filterApplied_excludesFilteredElements() throws {
        let window = makeWindow()
        // Non-interactive tiny element — default filter drops this.
        let tiny = makeElement(ref: 1, role: .staticText, label: "tiny",
                               bounds: CGRect(x: 10, y: 10, width: 1, height: 1))
        let big = makeElement(ref: 2, role: .staticText, label: "big",
                              bounds: CGRect(x: 10, y: 30, width: 100, height: 20))
        let map = makeMap(elements: [tiny, big], windows: [window])
        var options = QueryOptions()
        options.applyFilter = true
        options.filterPolicy = .default   // drops tiny
        let results = QueryEngine.execute(
            try QueryEngine.parse("role:staticText"),
            in: map, tiers: [:], options: options
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ref, big.ref)
    }

    func testExecute_filterDisabled_includesAllElements() throws {
        let window = makeWindow()
        let tiny = makeElement(ref: 1, role: .staticText, label: "tiny",
                               bounds: CGRect(x: 10, y: 10, width: 1, height: 1))
        let big = makeElement(ref: 2, role: .staticText, label: "big",
                              bounds: CGRect(x: 10, y: 30, width: 100, height: 20))
        let map = makeMap(elements: [tiny, big], windows: [window])
        var options = QueryOptions()
        options.applyFilter = false
        let results = QueryEngine.execute(
            try QueryEngine.parse("role:staticText"),
            in: map, tiers: [:], options: options
        )
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Fixture helpers

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
        windowIndex: Int = 0,
        value: String = "",
        confidence: Float = 1.0
    ) -> ScreenElement {
        ScreenElement(
            ref: ElementRef(index: ref),
            role: role,
            subrole: "",
            label: label,
            value: value,
            bounds: bounds,
            clickPoint: bounds.map { CGPoint(x: $0.midX, y: $0.midY) },
            state: .enabled,
            actions: role.isInteractive ? [.press] : [],
            parentRef: parentRef,
            depth: depth,
            source: .accessibility,
            confidence: confidence,
            appBundleID: "com.test",
            windowIndex: windowIndex,
            displayIndex: 0
        )
    }

    private func makeWindow(
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800),
        index: Int = 0,
        focused: Bool = true
    ) -> WindowInfo {
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

    private func withState(_ el: ScreenElement, state: ElementState) -> ScreenElement {
        ScreenElement(
            ref: el.ref, role: el.role, subrole: el.subrole,
            label: el.label, value: el.value,
            bounds: el.bounds, clickPoint: el.clickPoint,
            state: state,
            actions: el.actions, parentRef: el.parentRef, depth: el.depth,
            source: el.source, confidence: el.confidence,
            appBundleID: el.appBundleID, windowIndex: el.windowIndex,
            displayIndex: el.displayIndex
        )
    }

    private func withDisplayIndex(_ el: ScreenElement, displayIndex: Int) -> ScreenElement {
        ScreenElement(
            ref: el.ref, role: el.role, subrole: el.subrole,
            label: el.label, value: el.value,
            bounds: el.bounds, clickPoint: el.clickPoint,
            state: el.state, actions: el.actions,
            parentRef: el.parentRef, depth: el.depth,
            source: el.source, confidence: el.confidence,
            appBundleID: el.appBundleID, windowIndex: el.windowIndex,
            displayIndex: displayIndex
        )
    }
}
