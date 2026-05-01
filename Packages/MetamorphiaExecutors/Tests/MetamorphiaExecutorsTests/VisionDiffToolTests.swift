import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit
import MetamorphiaPerception

/// Rank 8 — Cropped vision diff tools.
///
/// Schema-shape tests only. The execute paths hit the AX + screen-capture
/// stack and are covered by ComputerLib's `VisionDifferTests` plus the
/// broader ScreenPerceive execution tests gated on AX permission.
final class VisionDiffToolTests: XCTestCase {

    // MARK: - 1. vision_diff schema

    func testVisionDiffTool_schema_ok() {
        let tool = VisionDiffTool()
        XCTAssertEqual(tool.name, "vision_diff")
        XCTAssertFalse(tool.description.isEmpty)

        let params = tool.parameters
        XCTAssertEqual(params["type"] as? String, "object")
        let props = (params["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["session_id"])
        XCTAssertNotNil(props["margin_px"])
        XCTAssertNotNil(props["full_screen_threshold"])
        XCTAssertNotNil(props["save_to_path"])

        let required = (params["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("session_id"),
                      "session_id must be required")

        let api = tool.toAPISchema()
        XCTAssertEqual(api["type"]?.value as? String, "function")
    }

    // MARK: - 2. vision_diff_multi schema

    func testVisionDiffMultiTool_schema_ok() {
        let tool = VisionDiffMultiTool()
        XCTAssertEqual(tool.name, "vision_diff_multi")
        XCTAssertFalse(tool.description.isEmpty)

        let params = tool.parameters
        XCTAssertEqual(params["type"] as? String, "object")
        let props = (params["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["session_id"])
        XCTAssertNotNil(props["margin_px"])

        let required = (params["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("session_id"))

        let api = tool.toAPISchema()
        XCTAssertEqual(api["type"]?.value as? String, "function")
    }

    // MARK: - 3. Missing session_id returns error

    func testVisionDiffTool_missingSessionID_returnsError() async throws {
        let result = try await VisionDiffTool().execute(arguments: "{}")
        XCTAssertTrue(result.hasPrefix("Error:"),
                      "expected error for missing session_id; got: \(result)")

        let resultMulti = try await VisionDiffMultiTool().execute(arguments: "{}")
        XCTAssertTrue(resultMulti.hasPrefix("Error:"),
                      "expected error for missing session_id; got: \(resultMulti)")
    }

    // MARK: - 4. Registered in allTools

    func testVisionDiffTool_registeredInAllTools() {
        let names = Set(MetamorphiaExecutors.allTools.map { $0.tool.name })
        XCTAssertTrue(names.contains("vision_diff"),
                      "MetamorphiaExecutors.allTools must include vision_diff")
        XCTAssertTrue(names.contains("vision_diff_multi"),
                      "MetamorphiaExecutors.allTools must include vision_diff_multi")

        let visionNames: Set<String> = ["vision_diff", "vision_diff_multi"]
        for entry in MetamorphiaExecutors.allTools where visionNames.contains(entry.tool.name) {
            XCTAssertEqual(entry.category, .screenPerception,
                           "\(entry.tool.name) should be categorized under .screenPerception")
        }
    }
}
