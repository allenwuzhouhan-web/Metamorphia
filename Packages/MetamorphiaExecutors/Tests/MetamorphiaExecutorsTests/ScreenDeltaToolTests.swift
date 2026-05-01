import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit
import MetamorphiaPerception

/// Rank 2 — Delta encoding tools.
///
/// Schema-shape tests only. The execute paths hit the AX API and are covered
/// by the broader Computer package's delta tests plus the screen-perceive
/// execution tests gated on AX permission.
final class ScreenDeltaToolTests: XCTestCase {

    // MARK: - 1. screen_delta schema

    func testScreenDeltaTool_schema_ok() {
        let tool = ScreenDeltaTool()
        XCTAssertEqual(tool.name, "screen_delta")
        XCTAssertFalse(tool.description.isEmpty)

        let params = tool.parameters
        XCTAssertEqual(params["type"] as? String, "object")
        let props = (params["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["session_id"])
        XCTAssertNotNil(props["format"])
        XCTAssertNotNil(props["max_elements"])

        let api = tool.toAPISchema()
        XCTAssertEqual(api["type"]?.value as? String, "function")
    }

    // MARK: - 2. screen_reset_session schema

    func testScreenResetSessionTool_schema_ok() {
        let tool = ScreenResetSessionTool()
        XCTAssertEqual(tool.name, "screen_reset_session")
        XCTAssertFalse(tool.description.isEmpty)

        let params = tool.parameters
        XCTAssertEqual(params["type"] as? String, "object")
        let required = (params["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("session_id"),
                      "session_id should be a required parameter")
    }

    // MARK: - 3. screen_perceive's session_id param in schema

    func testScreenPerceiveTool_sessionParam_InSchema() {
        let tool = ScreenPerceiveTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["session_id"],
                        "ScreenPerceiveTool should advertise session_id for Rank 2 delta mode")
        let sessionProp = props["session_id"] as? [String: Any]
        XCTAssertEqual(sessionProp?["type"] as? String, "string")
    }

    // MARK: - 4. Registration — new tools present in allTools

    func testAllTools_registers_newDeltaTools() {
        let names = Set(MetamorphiaExecutors.allTools.map { $0.tool.name })
        XCTAssertTrue(names.contains("screen_delta"),
                      "MetamorphiaExecutors.allTools must include screen_delta")
        XCTAssertTrue(names.contains("screen_reset_session"),
                      "MetamorphiaExecutors.allTools must include screen_reset_session")
    }

    func testAllTools_newDeltaTools_UseScreenPerceptionCategory() {
        let deltaNames: Set<String> = ["screen_delta", "screen_reset_session"]
        for entry in MetamorphiaExecutors.allTools where deltaNames.contains(entry.tool.name) {
            XCTAssertEqual(entry.category, .screenPerception,
                           "\(entry.tool.name) should be categorized under .screenPerception")
        }
    }

    // MARK: - 5. Reset-session returns error for missing session_id

    func testScreenResetSessionTool_missingSessionId_ReturnsError() async throws {
        let result = try await ScreenResetSessionTool().execute(arguments: "{}")
        XCTAssertTrue(result.hasPrefix("Error:"),
                      "expected error for missing session_id; got: \(result)")
    }
}
