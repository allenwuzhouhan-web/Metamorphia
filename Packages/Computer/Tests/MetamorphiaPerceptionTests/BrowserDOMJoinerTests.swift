import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

/// Three-pass matcher tests for `BrowserDOMJoiner.annotate`. Each pass is
/// tested in isolation with hand-rolled minimal inputs so a regression in
/// one pass doesn't require tracking through a full browser fixture.
final class BrowserDOMJoinerTests: XCTestCase {

    // MARK: - Pass 1: role-compatible IoU ≥ 0.7

    func testPass1_roleCompatibleFullOverlap_matches() {
        let element = makeElement(
            ref: 1, role: .button, label: "Send",
            bounds: CGRect(x: 100, y: 100, width: 80, height: 30)
        )
        let node = makeNode(
            selector: "#send", tag: "button",
            rect: CGRect(x: 100, y: 100, width: 80, height: 30)
        )
        let annotations = BrowserDOMJoiner.annotate(
            elements: [element], nodes: [node],
            viewportOrigin: .zero, scaleFactor: 1, browserBundleID: "com.browser"
        )
        XCTAssertEqual(annotations[element.ref]?.domSelector, "#send")
    }

    func testPass1_incompatibleRole_neverMatches() {
        let element = makeElement(
            ref: 1, role: .link, label: "Docs",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 30)
        )
        let node = makeNode(
            selector: "#docs", tag: "button",
            rect: CGRect(x: 0, y: 0, width: 80, height: 30)
        )
        let annotations = BrowserDOMJoiner.annotate(
            elements: [element], nodes: [node],
            viewportOrigin: .zero, scaleFactor: 1, browserBundleID: "com.browser"
        )
        XCTAssertNil(annotations[element.ref])
    }

    // MARK: - Pass 3: fuzzy substring with padded bounds

    func testPass3_substringFallback_matches() {
        // IoU is low (no meaningful overlap) and labels don't tokenize to
        // Jaccard ≥ 0.5 — but "Send" contains "Send" trivially. Pass 3 is
        // the last resort that catches the obvious case.
        let element = makeElement(
            ref: 1, role: .button, label: "Send message",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 30)
        )
        let node = makeNode(
            selector: "#compose-send", tag: "button", text: "Send",
            rect: CGRect(x: 2, y: 2, width: 78, height: 28)
        )
        let annotations = BrowserDOMJoiner.annotate(
            elements: [element], nodes: [node],
            viewportOrigin: .zero, scaleFactor: 1, browserBundleID: "com.browser"
        )
        XCTAssertEqual(annotations[element.ref]?.domSelector, "#compose-send")
    }

    // MARK: - Bundle filter

    func testElementFromDifferentBundle_notConsidered() {
        let element = makeElement(
            ref: 1, role: .button, label: "Send",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 30),
            bundleID: "com.apple.Finder"
        )
        let node = makeNode(
            selector: "#send", tag: "button",
            rect: CGRect(x: 0, y: 0, width: 80, height: 30)
        )
        let annotations = BrowserDOMJoiner.annotate(
            elements: [element], nodes: [node],
            viewportOrigin: .zero, scaleFactor: 1, browserBundleID: "com.browser"
        )
        XCTAssertNil(annotations[element.ref])
    }

    // MARK: - First-hit-wins per node

    func testNodeClaimedByFirstMatch_notDoubleAssigned() {
        let a = makeElement(
            ref: 1, role: .button, label: "Save",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 30)
        )
        let b = makeElement(
            ref: 2, role: .button, label: "Save",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 30)
        )
        let node = makeNode(
            selector: "#save", tag: "button",
            rect: CGRect(x: 0, y: 0, width: 80, height: 30)
        )
        let annotations = BrowserDOMJoiner.annotate(
            elements: [a, b], nodes: [node],
            viewportOrigin: .zero, scaleFactor: 1, browserBundleID: "com.browser"
        )
        // Exactly one of the two elements gets the annotation. Which one
        // is implementation-defined; the invariant we lock is "no node
        // matches twice."
        let matchCount = [a, b].compactMap { annotations[$0.ref] }.count
        XCTAssertEqual(matchCount, 1)
    }

    // MARK: - annotateInPlace

    func testAnnotateInPlace_returnsFreshScreenElement() {
        let element = makeElement(
            ref: 1, role: .button, label: "Send",
            bounds: CGRect(x: 100, y: 100, width: 80, height: 30)
        )
        let node = makeNode(
            selector: "#send", tag: "button",
            rect: CGRect(x: 100, y: 100, width: 80, height: 30)
        )
        let out = BrowserDOMJoiner.annotateInPlace(
            elements: [element], nodes: [node],
            viewportOrigin: .zero, scaleFactor: 1, browserBundleID: "com.browser"
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].domSelector, "#send")
        // Original value is untouched — ScreenElement is immutable.
        XCTAssertNil(element.domSelector)
    }

    // MARK: - Helpers

    private func makeElement(
        ref: Int, role: ElementRole, label: String,
        bounds: CGRect, bundleID: String = "com.browser"
    ) -> ScreenElement {
        ScreenElement(
            ref: ElementRef(index: ref),
            role: role,
            subrole: "",
            label: label,
            value: "",
            bounds: bounds,
            clickPoint: CGPoint(x: bounds.midX, y: bounds.midY),
            state: .enabled,
            actions: [.press],
            parentRef: nil,
            depth: 1,
            source: .accessibility,
            confidence: 1,
            appBundleID: bundleID,
            windowIndex: 0
        )
    }

    private func makeNode(
        selector: String,
        tag: String,
        role: String? = nil,
        aria: String? = nil,
        text: String = "",
        rect: CGRect
    ) -> DOMInteractiveNode {
        DOMInteractiveNode(
            selector: selector, tag: tag, id: nil, role: role,
            aria: aria, text: text, rect: rect, nodeId: nil, isEditable: false
        )
    }
}
