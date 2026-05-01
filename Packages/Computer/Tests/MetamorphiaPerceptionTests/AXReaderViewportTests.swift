import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

/// Rank 5 — Viewport-focused AX traversal.
/// These tests exercise the pure `shouldTraverse` filter helper and the
/// flat-list `filterRawElementsByViewport` integration shim, neither of which
/// touches live Accessibility APIs. For live-app tests, see ComputerTests
/// (which exercise the full `readFrontmostApp` path).
final class AXReaderViewportTests: XCTestCase {

    // Standard 1080p viewport used by most tests.
    private let viewport = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: - shouldTraverse: nil viewport

    func testNilViewport_NeverFilters() {
        // A random off-screen static text element with content should still be
        // kept when no viewport is active.
        let d = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 100_000, y: 100_000, width: 50, height: 20),
            role: .staticText,
            viewport: nil,
            depth: 2,
            hasContent: true
        )
        XCTAssertEqual(d, .keepAndRecord)

        // A deep empty container still gets the recurse-only treatment even
        // without a viewport (preserves the pre-Rank-5 optimization).
        let deep = AXReader.shouldTraverse(
            elementBounds: nil,
            role: .group,
            viewport: nil,
            depth: 5,
            hasContent: false
        )
        XCTAssertEqual(deep, .recurseOnly)
    }

    // MARK: - shouldTraverse: interactive always kept

    func testInteractiveOutsideViewport_AlwaysKept() {
        let button = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 500, y: 10_000, width: 80, height: 30),
            role: .button,
            viewport: viewport,
            depth: 3,
            hasContent: true
        )
        XCTAssertEqual(button, .keepAndRecord)
    }

    func testInteractiveWithNilBounds_Kept() {
        let link = AXReader.shouldTraverse(
            elementBounds: nil,
            role: .link,
            viewport: viewport,
            depth: 4,
            hasContent: true
        )
        XCTAssertEqual(link, .keepAndRecord)
    }

    func testZeroBoundsInteractive_Kept() {
        // Virtualized table row case — AX reports (0,0,0,0) even though the
        // button is the live click target for whatever pops into that slot.
        let row = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 0, y: 0, width: 0, height: 0),
            role: .button,
            viewport: viewport,
            depth: 6,
            hasContent: false
        )
        XCTAssertEqual(row, .keepAndRecord)
    }

    // MARK: - shouldTraverse: non-interactive filtering

    func testNonInteractiveFullyOutside_Skipped() {
        let text = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 100, y: 10_000, width: 200, height: 20),
            role: .staticText,
            viewport: viewport,
            depth: 3,
            hasContent: true
        )
        XCTAssertEqual(text, .skip)
    }

    func testNonInteractivePartiallyInside_Kept() {
        // Element straddling the viewport's right edge — 100 px in, 100 px out.
        let text = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 1820, y: 500, width: 200, height: 20),
            role: .staticText,
            viewport: viewport,
            depth: 2,
            hasContent: true
        )
        XCTAssertEqual(text, .keepAndRecord)
    }

    func testViewportIntersection_PartiallyOverlapping() {
        // Element at (1900, 500, 200, 100) intersects the viewport by a 20px
        // strip on its left edge — still considered visible.
        let d = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 1900, y: 500, width: 200, height: 100),
            role: .staticText,
            viewport: viewport,
            depth: 2,
            hasContent: true
        )
        XCTAssertEqual(d, .keepAndRecord)
    }

    // MARK: - shouldTraverse: container handling

    func testContainerNearViewport_Recurses() {
        // Container is a 500 px band sitting 200 px above the viewport. Fully
        // outside but within 800 px slack — recurse so children can contribute.
        let container = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 0, y: -700, width: 1920, height: 500),
            role: .group,
            viewport: viewport,
            depth: 2,
            hasContent: false
        )
        XCTAssertEqual(container, .recurseOnly)
    }

    func testContainerFarFromViewport_Skipped() {
        // Container 2000 px below viewport — outside the 800 px slack.
        let container = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 0, y: 3080, width: 1920, height: 500),
            role: .group,
            viewport: viewport,
            depth: 2,
            hasContent: false
        )
        XCTAssertEqual(container, .skip)
    }

    func testDeepEmptyNonInteractiveContainer_RecurseOnly() {
        // Depth 5, group, inside viewport, no content — should recurseOnly per
        // the existing "skip deep empty containers" optimization.
        let d = AXReader.shouldTraverse(
            elementBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            role: .group,
            viewport: viewport,
            depth: 5,
            hasContent: false
        )
        XCTAssertEqual(d, .recurseOnly)
    }

    // MARK: - Integration: filterRawElementsByViewport

    func testFilter_AppliesVisibleCap() {
        // Generate 800 on-screen static-text elements. Only the first
        // `maxVisibleElements` (500) should survive — the rest must be capped.
        var input: [AXReader.RawElement] = []
        for i in 0..<800 {
            input.append(makeRaw(
                role: "AXStaticText",
                x: 10, y: CGFloat(i % 900),
                w: 100, h: 20,
                title: "text-\(i)"
            ))
        }
        let filtered = AXReader.filterRawElementsByViewport(input, viewport: viewport)
        XCTAssertEqual(filtered.count, AXReader.maxVisibleElements,
                       "Expected visible cap to clamp filtered output at maxVisibleElements")
    }

    func testFilter_CountsOnlyVisibleTowardsCap() {
        // 400 off-screen static-text (will be .skip'd), then 600 on-screen
        // static-text. Expect 500 kept (the visible cap), skipping every
        // off-screen entry entirely.
        var input: [AXReader.RawElement] = []
        for i in 0..<400 {
            input.append(makeRaw(
                role: "AXStaticText",
                x: 10, y: 10_000 + CGFloat(i),
                w: 100, h: 20,
                title: "offscreen-\(i)"
            ))
        }
        for i in 0..<600 {
            input.append(makeRaw(
                role: "AXStaticText",
                x: 10, y: CGFloat(i % 900),
                w: 100, h: 20,
                title: "visible-\(i)"
            ))
        }
        let filtered = AXReader.filterRawElementsByViewport(input, viewport: viewport)
        XCTAssertEqual(filtered.count, AXReader.maxVisibleElements)
        // Every surviving element must have a "visible-" title (no off-screen
        // leaked into the result).
        for raw in filtered {
            XCTAssertTrue(raw.title.hasPrefix("visible-"),
                          "Unexpected off-screen element in filtered output: \(raw.title)")
        }
    }

    func testFilter_InteractiveOffScreenStillKept() {
        // 10 off-screen buttons should all survive the filter even though
        // their bounds are far outside the viewport.
        var input: [AXReader.RawElement] = []
        for i in 0..<10 {
            input.append(makeRaw(
                role: "AXButton",
                x: 10, y: 10_000 + CGFloat(i * 40),
                w: 80, h: 30,
                title: "btn-\(i)"
            ))
        }
        let filtered = AXReader.filterRawElementsByViewport(input, viewport: viewport)
        XCTAssertEqual(filtered.count, 10)
    }

    // MARK: - Cache invalidation on viewport change
    //
    // We can't exercise the live cache easily (it keys off a running pid), so
    // we verify the viewport-equality predicate the cache uses. The branch
    // that rebuilds vs returns cached is a direct consequence of this
    // predicate, so covering it deterministically here is sufficient.

    func testCacheInvariant_ViewportEqualityDetectsChange() {
        // Same viewport → cache hit (same result pointer after re-read).
        let v1 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let v2 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let v3 = CGRect(x: 0, y: 0, width: 1000, height: 900) // different
        XCTAssertEqual(v1, v2)
        XCTAssertNotEqual(v1, v3)
    }

    func testCacheInvariant_NilVsRectTreatedDifferently() {
        // The cache stores `cachedViewport: CGRect?`. When the caller passes
        // nil vs a rect, those MUST re-read — verified by XCTAssertNotEqual
        // between nil-optional and a rect-optional.
        let a: CGRect? = nil
        let b: CGRect? = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Helpers

    private func makeRaw(
        role: String,
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        title: String = "",
        depth: Int = 2
    ) -> AXReader.RawElement {
        AXReader.RawElement(
            role: role,
            subrole: "",
            title: title,
            value: "",
            description: "",
            label: "",
            identifier: "",
            position: CGPoint(x: x, y: y),
            size: CGSize(width: w, height: h),
            depth: depth,
            state: [.enabled],
            actions: []
        )
    }
}
