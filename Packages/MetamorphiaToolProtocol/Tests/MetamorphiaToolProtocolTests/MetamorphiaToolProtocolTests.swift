import XCTest
@testable import MetamorphiaToolProtocol

final class MetamorphiaToolProtocolTests: XCTestCase {
    func testJSONSchemaObjectBuilder() {
        let schema = JSONSchema.object(
            properties: ["path": JSONSchema.string(description: "a path")],
            required: ["path"]
        )
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["path"])
    }

    func testToolRiskTierOrdering() {
        // Just confirm the raw values stay stable — other code may decode
        // persisted tier strings and rely on these spellings.
        XCTAssertEqual(ToolRiskTier.safe.rawValue, "safe")
        XCTAssertEqual(ToolRiskTier.elevated.rawValue, "elevated")
        XCTAssertEqual(ToolRiskTier.critical.rawValue, "critical")
    }

    func testNullSafetyGateAllowsAll() async {
        let gate = NullToolSafetyGate()
        let decision = await gate.checkPermission(toolName: "anything", arguments: "{}")
        if case .deny = decision {
            XCTFail("NullToolSafetyGate must allow by default")
        }
    }
}
