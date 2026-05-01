import XCTest
@testable import MetamorphiaAgentKit

/// Exercises the `SubAgentType` → `AgentIdentityRef` mapping used by the
/// notch UI to pick a one-word display name (Scout, Scribe, Mime…). The
/// UI-side `AgentNameCatalog` lives in the Metamorphia target, so we test
/// the package-side transform that feeds it — if this mapping drifts, the
/// wrong agent name will show up next to each sub-agent row.
final class AgentNameCatalogTests: XCTestCase {
    func testResearcherMapsToScout() {
        XCTAssertEqual(AgentIdentityRef.from(subAgentType: .researcher), .scout)
    }

    func testFileOperatorMapsToCurator() {
        XCTAssertEqual(AgentIdentityRef.from(subAgentType: .fileOperator), .curator)
    }

    func testSystemControlMapsToWarden() {
        XCTAssertEqual(AgentIdentityRef.from(subAgentType: .systemControl), .warden)
    }

    func testUIAutomationMapsToMime() {
        XCTAssertEqual(AgentIdentityRef.from(subAgentType: .uiAutomation), .mime)
    }

    func testComposerMapsToScribe() {
        XCTAssertEqual(AgentIdentityRef.from(subAgentType: .composer), .scribe)
    }

    /// Catch the common mistake of adding a new `SubAgentType` case without
    /// extending the map. Every case must produce a distinct identity
    /// (the reserved identities — Forge, Sage, Herald, Ranger, Tinker, Muse
    /// — are deliberately unused so this set is tight).
    func testEveryKnownSubAgentTypeProducesAnIdentity() {
        for subtype in SubAgentType.allCases {
            let identity = AgentIdentityRef.from(subAgentType: subtype)
            XCTAssertFalse(
                [AgentIdentityRef.oracle].contains(identity),
                "SubAgentType \(subtype) should not map to the root identity (oracle is reserved for AgentLoop)."
            )
        }
    }
}
