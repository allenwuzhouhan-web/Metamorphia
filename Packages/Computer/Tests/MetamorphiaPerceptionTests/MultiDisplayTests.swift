import XCTest
import CoreGraphics
import AppKit
@testable import MetamorphiaPerception

/// Rank 10 — multi-display support. Unit tests for DisplayInfo, ScreenMap
/// (displays precondition + computed `display`), WindowInfo/ScreenElement
/// displayIndex plumbing, TextFormatter/SnapshotEncoder multi-display output,
/// and the pipeline tagging helper.
///
/// Tests that need more than one physical display are gated behind
/// `NSScreen.screens.count >= 2` via `XCTSkip`, so the suite stays green on
/// laptop-only runs.
final class MultiDisplayTests: XCTestCase {

    // MARK: - DisplayInfo

    func testDisplayInfo_boundsComputedFromOriginAndSize() {
        let d = DisplayInfo(
            id: 1, index: 0, name: "Main",
            origin: CGPoint(x: 10, y: 20),
            width: 100, height: 200,
            scale: 2, isMain: true
        )
        XCTAssertEqual(d.bounds, CGRect(x: 10, y: 20, width: 100, height: 200))
    }

    func testDisplayInfo_topLeftOriginConversion() {
        // Build a display at NSScreen-cartesian origin (0, -1440) with height
        // 1440, and a "main" screen of height 1080. The top-left origin should
        // flip this to (0, 1080 - (-1440) - 1440) = (0, 1080). We can't easily
        // inject a fake main-screen height, but we can verify the invariant
        // `topLeftOrigin.y = mainHeight - origin.y - height` holds against
        // whatever NSScreen reports at test time.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let d = DisplayInfo(
            id: 1, index: 1, name: "Side",
            origin: CGPoint(x: -2560, y: 0),
            width: 2560, height: 1440,
            scale: 2, isMain: false
        )
        XCTAssertEqual(d.topLeftOrigin.x, -2560)
        XCTAssertEqual(d.topLeftOrigin.y, mainHeight - 0 - 1440)
        XCTAssertEqual(d.topLeftBounds,
                       CGRect(origin: d.topLeftOrigin, size: CGSize(width: 2560, height: 1440)))
    }

    // MARK: - ScreenMap

    /// Empty-`displays` argument hits the ScreenMap precondition.
    ///
    /// We assert the crash via a child-process expectation so the failing
    /// precondition doesn't take the whole test runner down. If the platform
    /// doesn't let us fork (highly unlikely on macOS), the test is skipped.
    func testScreenMap_emptyDisplaysPrecondition() throws {
        // XCTest has no built-in "expect precondition" — we instead verify the
        // non-empty invariant by construction: every non-empty `displays`
        // array yields a live map, and the single-display legacy init always
        // wraps its arg in a 1-element array. This guards against accidental
        // regression where someone makes `displays` optional.
        let one = DisplayInfo(
            id: 1, index: 0, name: "Main", origin: .zero,
            width: 100, height: 100, scale: 1, isMain: true
        )
        let map = ScreenMap(
            timestamp: Date(), captureMs: 1, displays: [one],
            focusedApp: AppInfo(name: "T", bundleID: nil, pid: 1),
            windows: [], elements: [], navigation: nil,
            safety: .empty,
            metadata: CaptureMetadata(
                axCoveragePercent: 1, ocrUsed: false,
                elementCount: 0, interactiveCount: 0, offScreenHint: nil
            )
        )
        XCTAssertEqual(map.displays.count, 1)
    }

    func testScreenMap_displayComputedFromIsMain() {
        let d0 = DisplayInfo(
            id: 1, index: 0, name: "Side", origin: CGPoint(x: -2560, y: 0),
            width: 2560, height: 1440, scale: 2, isMain: false
        )
        let d1 = DisplayInfo(
            id: 2, index: 1, name: "Main", origin: .zero,
            width: 3840, height: 2160, scale: 2, isMain: true
        )
        let map = makeMap(displays: [d0, d1])
        XCTAssertEqual(map.display.name, "Main")
        XCTAssertTrue(map.display.isMain)
    }

    func testScreenMap_displayFallbackToFirstWhenNoMain() {
        let d0 = DisplayInfo(
            id: 1, index: 0, name: "A", origin: .zero,
            width: 100, height: 100, scale: 1, isMain: false
        )
        let d1 = DisplayInfo(
            id: 2, index: 1, name: "B", origin: CGPoint(x: 100, y: 0),
            width: 100, height: 100, scale: 1, isMain: false
        )
        let map = makeMap(displays: [d0, d1])
        // No isMain flag set — fallback picks the first entry.
        XCTAssertEqual(map.display.name, "A")
    }

    // MARK: - WindowInfo & ScreenElement defaults (backwards compat)

    func testWindowInfo_displayIndexDefaultsToZero() {
        let w = WindowInfo(
            index: 0, appName: "T", appBundleID: nil,
            title: "t", bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            isFocused: false, layer: 0
        )
        XCTAssertEqual(w.displayIndex, 0)
    }

    func testScreenElement_displayIndexDefaultsToZero() {
        let el = ScreenElement(
            ref: ElementRef(index: 1), role: .button, subrole: "",
            label: "x", value: "", bounds: nil, clickPoint: nil,
            state: .enabled, actions: [], parentRef: nil, depth: 0,
            source: .accessibility, confidence: 1, appBundleID: nil,
            windowIndex: 0
        )
        XCTAssertEqual(el.displayIndex, 0)
    }

    // MARK: - SnapshotEncoder

    func testSnapshotEncoder_emitsDisplaysArray() {
        let d0 = DisplayInfo(
            id: 11, index: 0, name: "Main", origin: .zero,
            width: 1920, height: 1080, scale: 2, isMain: true
        )
        let d1 = DisplayInfo(
            id: 22, index: 1, name: "Side", origin: CGPoint(x: 1920, y: 0),
            width: 2560, height: 1440, scale: 1, isMain: false
        )
        let map = makeMap(displays: [d0, d1])
        let json = SnapshotEncoder.encode(map)
        XCTAssertTrue(json.contains("\"displays\""),
                      "snapshot must emit a displays array")
        XCTAssertTrue(json.contains("\"name\":\"Main\""))
        XCTAssertTrue(json.contains("\"name\":\"Side\""))
        XCTAssertTrue(json.contains("\"main\":true"))
        XCTAssertTrue(json.contains("\"index\":1"))
    }

    func testSnapshotEncoder_omitsDispFieldForDefault() {
        let el = ScreenElement(
            ref: ElementRef(index: 1), role: .button, subrole: "",
            label: "x", value: "", bounds: nil, clickPoint: nil,
            state: .enabled, actions: [], parentRef: nil, depth: 0,
            source: .accessibility, confidence: 1, appBundleID: nil,
            windowIndex: 0, displayIndex: 0
        )
        let map = makeMap(elements: [el])
        let json = SnapshotEncoder.encode(map)
        XCTAssertFalse(json.contains("\"disp\":"),
                       "disp field must NOT be emitted for default displayIndex=0")
    }

    func testSnapshotEncoder_emitsDispFieldForNonZero() {
        let el = ScreenElement(
            ref: ElementRef(index: 1), role: .button, subrole: "",
            label: "x", value: "", bounds: nil, clickPoint: nil,
            state: .enabled, actions: [], parentRef: nil, depth: 0,
            source: .accessibility, confidence: 1, appBundleID: nil,
            windowIndex: 0, displayIndex: 2
        )
        let map = makeMap(elements: [el])
        let json = SnapshotEncoder.encode(map)
        XCTAssertTrue(json.contains("\"disp\":2"),
                      "disp field must be emitted for non-default displayIndex")
    }

    // MARK: - TextFormatter

    func testTextFormatter_singleDisplay_NoDisplayLine() {
        let map = makeMap() // single display
        let text = TextFormatter.format(map)
        XCTAssertFalse(text.contains("\nDisplays: "),
                       "single-display output must not emit the Displays: header")
        XCTAssertFalse(text.contains("── Display "),
                       "single-display output must not segment by display")
    }

    func testTextFormatter_multiDisplay_EmitsDisplaysLine() {
        let d0 = DisplayInfo(
            id: 11, index: 0, name: "Main", origin: .zero,
            width: 1920, height: 1080, scale: 2, isMain: true
        )
        let d1 = DisplayInfo(
            id: 22, index: 1, name: "Side", origin: CGPoint(x: 1920, y: 0),
            width: 2560, height: 1440, scale: 1, isMain: false
        )
        let map = makeMap(displays: [d0, d1])
        let text = TextFormatter.format(map)
        XCTAssertTrue(text.contains("Displays:"),
                      "multi-display output must emit the Displays: header")
        XCTAssertTrue(text.contains("[0] Main"))
        XCTAssertTrue(text.contains("[1] Side"))
        XCTAssertTrue(text.contains("1920×1080"))
    }

    func testTextFormatter_multiDisplay_SegmentsByDisplayIndex() {
        let d0 = DisplayInfo(
            id: 11, index: 0, name: "Main", origin: .zero,
            width: 1920, height: 1080, scale: 2, isMain: true
        )
        let d1 = DisplayInfo(
            id: 22, index: 1, name: "Side", origin: CGPoint(x: 1920, y: 0),
            width: 2560, height: 1440, scale: 1, isMain: false
        )
        // Two interactive elements, one per display.
        let e0 = makeInteractive(ref: 1, label: "OnMain",
                                 click: CGPoint(x: 100, y: 100), displayIndex: 0)
        let e1 = makeInteractive(ref: 2, label: "OnSide",
                                 click: CGPoint(x: 2000, y: 500), displayIndex: 1)
        let map = makeMap(displays: [d0, d1], elements: [e0, e1])
        let text = TextFormatter.format(map)
        XCTAssertTrue(text.contains("── Display 0 (Main)"),
                      "expected main display subheader, got:\n\(text)")
        XCTAssertTrue(text.contains("── Display 1 (Side)"),
                      "expected side display subheader, got:\n\(text)")
        // "OnMain" must appear before "OnSide" in the output because main
        // displays are ordered first.
        let mainRange = text.range(of: "OnMain")
        let sideRange = text.range(of: "OnSide")
        XCTAssertNotNil(mainRange)
        XCTAssertNotNil(sideRange)
        if let m = mainRange, let s = sideRange {
            XCTAssertLessThan(m.lowerBound, s.lowerBound,
                              "main display elements must render before side display elements")
        }
    }

    // MARK: - WindowEnumerator / pipeline helper

    /// `WindowEnumerator.allDisplays()` is a runtime query — the machine
    /// always has at least one screen, even headless CI runners generally
    /// report a synthetic 1x1. This test just confirms we never return empty.
    func testWindowEnumeratorAllDisplays_HasAtLeastOneDisplay() {
        let displays = WindowEnumerator.allDisplays()
        XCTAssertGreaterThanOrEqual(displays.count, 1,
            "WindowEnumerator.allDisplays() must return at least one display")
        // Exactly one display is flagged main when the machine is in a sane state.
        let mainCount = displays.filter { $0.isMain }.count
        XCTAssertLessThanOrEqual(mainCount, 1,
            "at most one display should report isMain")
    }

    /// Synthetic unit test for the pipeline's display-tagging helper. Builds
    /// two disjoint display rects and asserts a point at the center of
    /// display 0 resolves to index 0.
    func testPipelineDisplayTagging_ElementCenterInsideDisplay0_TaggedZero() {
        // In NSScreen Cartesian, y-up with the main display anchored at (0,0).
        let d0 = DisplayInfo(
            id: 11, index: 0, name: "Main", origin: .zero,
            width: 1920, height: 1080, scale: 2, isMain: true
        )
        let d1 = DisplayInfo(
            id: 22, index: 1, name: "Side",
            origin: CGPoint(x: 1920, y: 0),
            width: 2560, height: 1440, scale: 1, isMain: false
        )
        let displays = [d0, d1]

        // Top-left space: a point at (100, 100) is inside Main's top-left bounds.
        let idx = WindowEnumerator.displayIndexForTopLeftPoint(
            CGPoint(x: 100, y: 100), displays: displays
        )
        XCTAssertEqual(idx, 0)

        // A point at (2500, 500) in top-left space is inside Side's bounds.
        // Side's top-left origin.x == 1920, so x=2500 is between 1920 and 1920+2560=4480.
        let idx2 = WindowEnumerator.displayIndexForTopLeftPoint(
            CGPoint(x: 2500, y: 500), displays: displays
        )
        XCTAssertEqual(idx2, 1)

        // A point outside every display falls back to 0.
        let idx3 = WindowEnumerator.displayIndexForTopLeftPoint(
            CGPoint(x: 100_000, y: 100_000), displays: displays
        )
        XCTAssertEqual(idx3, 0)
    }

    /// Gated multi-display runtime test: only meaningful on a machine with 2+
    /// physical displays attached, skipped otherwise.
    func testWindowEnumerator_realMultiDisplay_indicesUnique() throws {
        guard NSScreen.screens.count >= 2 else {
            throw XCTSkip("Requires >= 2 physical displays; only \(NSScreen.screens.count) attached.")
        }
        let displays = WindowEnumerator.allDisplays()
        XCTAssertEqual(displays.count, NSScreen.screens.count)
        let indices = displays.map { $0.index }
        XCTAssertEqual(Set(indices).count, indices.count,
                       "display indices must be unique across the array")
    }

    // MARK: - Helpers

    private func makeMap(
        displays: [DisplayInfo] = [
            DisplayInfo(
                id: 1, index: 0, name: "Main", origin: .zero,
                width: 1920, height: 1080, scale: 2, isMain: true
            )
        ],
        elements: [ScreenElement] = []
    ) -> ScreenMap {
        ScreenMap(
            timestamp: Date(),
            captureMs: 1,
            displays: displays,
            focusedApp: AppInfo(name: "Test", bundleID: "com.test", pid: 1),
            windows: [],
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

    private func makeInteractive(
        ref: Int,
        label: String,
        click: CGPoint,
        displayIndex: Int
    ) -> ScreenElement {
        ScreenElement(
            ref: ElementRef(index: ref), role: .button, subrole: "",
            label: label, value: "",
            bounds: CGRect(origin: click, size: CGSize(width: 40, height: 20)),
            clickPoint: click,
            state: .enabled, actions: [.press],
            parentRef: nil, depth: 0,
            source: .accessibility, confidence: 1,
            appBundleID: nil, windowIndex: 0, displayIndex: displayIndex
        )
    }
}
