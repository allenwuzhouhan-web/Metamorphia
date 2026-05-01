import XCTest
@testable import MetamorphiaPerception

/// Lock-in tests for the `IdentityTier.code` grammar. The codes are
/// persisted into SQL columns (`elements.identity_tier`), WorkflowStep
/// JSON, and ElementDatabase rows — changing any of them silently would
/// invalidate cross-session identity lookups. These tests exist so that
/// kind of change requires acknowledging a broken invariant.
final class IdentityTierCodeTests: XCTestCase {

    func testIdentifierCodeIsT1() { XCTAssertEqual(IdentityTier.identifier.code, "t1") }
    func testDomCodeIsT2()        { XCTAssertEqual(IdentityTier.dom.code,        "t2") }
    func testMenuCodeIsT3()       { XCTAssertEqual(IdentityTier.menu.code,       "t3") }
    func testLabelCodeIsT4()      { XCTAssertEqual(IdentityTier.label.code,      "t4") }
    func testPositionCodeIsT5()   { XCTAssertEqual(IdentityTier.position.code,   "t5") }
    func testVisualCodeIsT6()     { XCTAssertEqual(IdentityTier.visual.code,     "t6") }
    func testFallbackCodeIsTF()   { XCTAssertEqual(IdentityTier.fallback.code,   "tF") }
}
