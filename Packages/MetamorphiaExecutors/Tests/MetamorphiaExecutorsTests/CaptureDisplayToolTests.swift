import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit
import MetamorphiaPerception

/// Schema + registration tests for Rank 10's multi-display tools:
///  - `list_displays`
///  - `capture_display`
///
/// Execution paths touch real screens and are gated behind
/// `METAMORPHIA_CI` / `CI` / `GITHUB_ACTIONS` env vars so headless CI stays green.
final class CaptureDisplayToolTests: XCTestCase {

    // MARK: - Inventory

    private var newTools: [any ToolDefinition] {
        [
            ListDisplaysTool(),
            CaptureDisplayTool(),
        ]
    }

    private var expectedToolNames: Set<String> {
        ["list_displays", "capture_display"]
    }

    // MARK: - Schema

    func testBothToolsHaveNames() {
        for tool in newTools {
            XCTAssertFalse(tool.name.isEmpty, "tool missing name")
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) missing description")
        }
    }

    func testBothToolNamesMatchExpected() {
        let actual = Set(newTools.map { $0.name })
        XCTAssertEqual(actual, expectedToolNames)
    }

    func testBothToolsExposeValidJSONSchema() {
        for tool in newTools {
            let params = tool.parameters
            XCTAssertEqual(params["type"] as? String, "object",
                "\(tool.name): parameters.type must be 'object'")
            XCTAssertNotNil(params["properties"] as? [String: Any],
                "\(tool.name): parameters.properties must be a dict")

            let api = tool.toAPISchema()
            XCTAssertEqual(api["type"]?.value as? String, "function")
            let fn = api["function"]?.value as? [String: AnyCodable]
            XCTAssertNotNil(fn, "\(tool.name): function wrapper missing")
            XCTAssertEqual(fn?["name"]?.value as? String, tool.name)
        }
    }

    func testListDisplaysHasEmptyParameters() {
        let props = (ListDisplaysTool().parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertTrue(props.isEmpty, "list_displays should take no parameters")
    }

    func testCaptureDisplaySchemaHasExpectedProperties() {
        let props = (CaptureDisplayTool().parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["index"], "capture_display should accept 'index'")
        XCTAssertNotNil(props["path"], "capture_display should accept 'path'")
    }

    func testCaptureDisplayIndexIsOptional() {
        // Omitting `index` should default to the main display — so it MUST
        // NOT be in the `required` array.
        let required = (CaptureDisplayTool().parameters["required"] as? [String]) ?? []
        XCTAssertFalse(required.contains("index"),
            "capture_display.index must be optional so callers can default to main display")
    }

    // MARK: - Registration

    func testAllTools_registersBothNewDisplayTools() {
        let names = Set(MetamorphiaExecutors.allTools.map { $0.tool.name })
        for expected in expectedToolNames {
            XCTAssertTrue(names.contains(expected),
                "MetamorphiaExecutors.allTools is missing '\(expected)'")
        }
    }

    func testAllTools_displayToolsUseScreenPerceptionCategory() {
        for entry in MetamorphiaExecutors.allTools where expectedToolNames.contains(entry.tool.name) {
            XCTAssertEqual(entry.category, .screenPerception,
                "\(entry.tool.name) should be categorized under .screenPerception")
        }
    }

    // MARK: - Execution (runtime-gated)

    /// `list_displays` returns a JSON array of display descriptors. Every macOS
    /// host has at least one display attached, so we expect a non-empty array
    /// anywhere the test can actually execute AppKit.
    func testListDisplays_returnsValidJSONArray() async throws {
        try skipIfHeadlessCI()
        let result = try await ListDisplaysTool().execute(arguments: "{}")
        XCTAssertFalse(result.hasPrefix("Error:"),
            "list_displays unexpectedly failed: \(result)")
        let data = result.data(using: .utf8) ?? Data()
        let obj = try? JSONSerialization.jsonObject(with: data)
        guard let arr = obj as? [[String: Any]] else {
            XCTFail("list_displays output was not a JSON array; got \(result)")
            return
        }
        XCTAssertGreaterThanOrEqual(arr.count, 1,
            "list_displays must return at least one display")
        let first = arr[0]
        XCTAssertNotNil(first["index"])
        XCTAssertNotNil(first["name"])
        XCTAssertNotNil(first["width"])
        XCTAssertNotNil(first["height"])
        XCTAssertNotNil(first["isMain"])
    }

    func testCaptureDisplay_invalidIndexReturnsError() async throws {
        try skipIfHeadlessCI()
        let args = try json(["index": 99])
        let result = try await CaptureDisplayTool().execute(arguments: args)
        XCTAssertTrue(result.hasPrefix("Error:"),
            "capture_display with invalid index should return Error; got \(result)")
    }

    // MARK: - Helpers

    private func json(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func skipIfHeadlessCI() throws {
        let env = ProcessInfo.processInfo.environment
        if env["CI"] != nil || env["METAMORPHIA_CI"] != nil || env["GITHUB_ACTIONS"] != nil {
            throw XCTSkip("Skipped in CI — display capture requires a user session.")
        }
    }
}
