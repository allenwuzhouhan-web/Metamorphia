import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

/// Rank 6 — Selector parser tests.
///
/// Each test locks one grammar rule so regressions point at the offending
/// production. The parser is hand-written recursive descent — no regex
/// shortcuts, no string splitting — so these tests mostly inspect the
/// predicate list the parser produced.
final class SelectorParserTests: XCTestCase {

    // MARK: - Empty / malformed

    func testParse_emptySelector_throws() {
        XCTAssertThrowsError(try SelectorParser.parse("")) { error in
            XCTAssertEqual(error as? QueryError, .emptySelector)
        }
        XCTAssertThrowsError(try SelectorParser.parse("   ")) { error in
            XCTAssertEqual(error as? QueryError, .emptySelector)
        }
    }

    // MARK: - Simple predicates

    func testParse_singleRole_ok() throws {
        let selector = try SelectorParser.parse("role:button")
        XCTAssertEqual(selector.predicates.count, 1)
        guard case .role(let role) = selector.predicates[0] else {
            return XCTFail("expected .role, got \(selector.predicates[0])")
        }
        XCTAssertEqual(role, .button)
    }

    func testParse_roleAndLabel_AND() throws {
        let selector = try SelectorParser.parse("role:button label:Save")
        XCTAssertEqual(selector.predicates.count, 2)
        guard case .role(let role) = selector.predicates[0] else {
            return XCTFail("predicate 0 should be role")
        }
        guard case .labelEquals(let text, let ci) = selector.predicates[1] else {
            return XCTFail("predicate 1 should be labelEquals")
        }
        XCTAssertEqual(role, .button)
        XCTAssertEqual(text, "Save")
        XCTAssertTrue(ci, "colon syntax should default to case-insensitive")
    }

    func testParse_quotedLabelWithSpaces() throws {
        let selector = try SelectorParser.parse("label:\"Save As…\"")
        XCTAssertEqual(selector.predicates.count, 1)
        guard case .labelEquals(let text, _) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(text, "Save As…")
    }

    // MARK: - Regex

    func testParse_labelRegex_validPattern() throws {
        let selector = try SelectorParser.parse("label~/^Sign.*/")
        XCTAssertEqual(selector.predicates.count, 1)
        guard case .labelRegex(let regex) = selector.predicates[0] else {
            return XCTFail()
        }
        // Spot-check behavior.
        let range = NSRange(location: 0, length: "Sign In".utf16.count)
        XCTAssertNotNil(regex.firstMatch(in: "Sign In", options: [], range: range))
        let range2 = NSRange(location: 0, length: "Cancel".utf16.count)
        XCTAssertNil(regex.firstMatch(in: "Cancel", options: [], range: range2))
    }

    func testParse_labelRegex_invalidRegex_throws() {
        XCTAssertThrowsError(try SelectorParser.parse("label~/[unclosed/")) { error in
            guard case .invalidRegex = (error as? QueryError) else {
                return XCTFail("expected .invalidRegex")
            }
        }
    }

    // MARK: - String operators

    func testParse_labelContains_star() throws {
        let selector = try SelectorParser.parse("label*save")
        XCTAssertEqual(selector.predicates.count, 1)
        guard case .labelContains(let text, let ci) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(text, "save")
        XCTAssertTrue(ci)
    }

    func testParse_labelStartsWith_caret() throws {
        let selector = try SelectorParser.parse("label^Open")
        XCTAssertEqual(selector.predicates.count, 1)
        guard case .labelStartsWith(let text, let ci) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(text, "Open")
        XCTAssertTrue(ci)
    }

    // MARK: - Depth comparison

    func testParse_depthGreater() throws {
        let selector = try SelectorParser.parse("depth:>3")
        XCTAssertEqual(selector.predicates.count, 1)
        guard case .depthGreater(let n) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(n, 3)
    }

    func testParse_depthLess() throws {
        let selector = try SelectorParser.parse("depth:<5")
        XCTAssertEqual(selector.predicates.count, 1)
        guard case .depthLess(let n) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(n, 5)
    }

    // MARK: - Visibility

    func testParse_visibleTrue() throws {
        let selector = try SelectorParser.parse("visible:true")
        guard case .visible(let v) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertTrue(v)
    }

    func testParse_interactiveTrue() throws {
        let selector = try SelectorParser.parse("interactive:true")
        guard case .interactive(let v) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertTrue(v)
    }

    // MARK: - State

    func testParse_stateEnabled() throws {
        let selector = try SelectorParser.parse("state:enabled")
        guard case .hasState(let s) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(s, .enabled)
    }

    func testParse_stateNegated_lacksState() throws {
        let selector = try SelectorParser.parse("state:!disabled")
        guard case .lacksState(let s) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(s, .disabled)
    }

    // MARK: - Action

    func testParse_actionPress() throws {
        let selector = try SelectorParser.parse("action:press")
        guard case .hasAction(let a) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(a, .press)
    }

    // MARK: - Display

    func testParse_displayIndex() throws {
        let selector = try SelectorParser.parse("display:0")
        guard case .displayIndex(let n) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(n, 0)
    }

    // MARK: - Ref + near

    func testParse_bareRef_AtE42() throws {
        let selector = try SelectorParser.parse("@e42")
        guard case .refEquals(let ref) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(ref, ElementRef(index: 42))
    }

    func testParse_nearRef_WithRadius() throws {
        let selector = try SelectorParser.parse("near:@e42:50")
        guard case .nearRef(let ref, let radius) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(ref, ElementRef(index: 42))
        XCTAssertEqual(radius, 50)
    }

    // MARK: - Tier + confidence

    func testParse_tierLabel() throws {
        let selector = try SelectorParser.parse("tier:label")
        guard case .tier(let t) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(t, .label)
    }

    func testParse_confidenceAbove() throws {
        let selector = try SelectorParser.parse("confidence:>0.8")
        guard case .confidenceAbove(let f) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertEqual(f, 0.8, accuracy: 0.0001)
    }

    // MARK: - Negation + grouping

    func testParse_negation_bang() throws {
        // `!visible:true` → visible(false) via natural inverse.
        let selector = try SelectorParser.parse("!visible:true")
        XCTAssertEqual(selector.predicates.count, 1)
        guard case .visible(let v) = selector.predicates[0] else {
            return XCTFail()
        }
        XCTAssertFalse(v)
    }

    func testParse_grouping_parens() throws {
        // Parens wrap an AND group — the parser flattens the inner predicates
        // into the top-level list (selectors are all-AND anyway).
        let selector = try SelectorParser.parse("(role:button label:Save)")
        XCTAssertEqual(selector.predicates.count, 2)
        guard case .role = selector.predicates[0] else { return XCTFail() }
        guard case .labelEquals = selector.predicates[1] else { return XCTFail() }
    }

    // MARK: - Multi-field AND

    func testParse_multipleFields_AllANDed() throws {
        let selector = try SelectorParser.parse("role:button label*save in:\"Toolbar\"")
        XCTAssertEqual(selector.predicates.count, 3)
        guard case .role(let r) = selector.predicates[0] else { return XCTFail() }
        XCTAssertEqual(r, .button)
        guard case .labelContains(let lc, _) = selector.predicates[1] else { return XCTFail() }
        XCTAssertEqual(lc, "save")
        guard case .inContainer(let inc, _) = selector.predicates[2] else { return XCTFail() }
        XCTAssertEqual(inc, "Toolbar")
    }

    // MARK: - Field / value validation

    func testParse_unknownField_throws() {
        XCTAssertThrowsError(try SelectorParser.parse("zzz:foo")) { error in
            XCTAssertEqual(error as? QueryError, .unknownField("zzz"))
        }
    }

    func testParse_invalidRoleValue_throws() {
        XCTAssertThrowsError(try SelectorParser.parse("role:notARealRole")) { error in
            XCTAssertEqual(error as? QueryError, .invalidRoleValue("notARealRole"))
        }
    }
}
