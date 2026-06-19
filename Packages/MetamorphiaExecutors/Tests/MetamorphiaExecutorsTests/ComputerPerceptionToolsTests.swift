import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit
import MetamorphiaPerception

/// Tests for the seven Computer → Metamorphia bridge tools (Rank 0).
///
/// Schema-shape tests run anywhere — they're pure instantiation + dictionary
/// inspection. Execution tests hit the AX API and are gated behind the
/// `METAMORPHIA_CI` / `CI` environment variable and AX-permission detection, so CI
/// headless runs skip them cleanly without failing the suite.
final class ComputerPerceptionToolsTests: XCTestCase {

    // MARK: - Bootstrap

    /// The perception pipeline reaches `PerceptionRuntime.host` on first
    /// access and `preconditionFailure`s (signal 5, aborting the whole test
    /// binary) if `bootstrap`/`bootstrapForTests` was never called. Install a
    /// throwaway temp-dir host before any test in this class runs. The call is
    /// idempotent and process-global, so it also covers sibling perception
    /// test classes whatever the run order.
    override class func setUp() {
        super.setUp()
        if !PerceptionRuntime.isBootstrapped {
            PerceptionRuntime.bootstrapForTests()
        }
    }

    // MARK: - Inventory

    /// Single source of truth for "the seven new tools". Tests derive off this.
    private var newTools: [any ToolDefinition] {
        [
            ScreenPerceiveTool(),
            ScreenQueryTool(),
            ScreenDiffTool(),
            InvokeMenuTool(),
            FindElementTool(),
            SuggestActionsTool(),
            ShortcutsTool(),
        ]
    }

    private var expectedToolNames: Set<String> {
        [
            "screen_perceive", "screen_query", "screen_diff",
            "invoke_menu", "find_element", "suggest_actions",
            "list_shortcuts",
        ]
    }

    // MARK: - Schema Shape

    func testAllSevenToolsHaveNames() {
        for tool in newTools {
            XCTAssertFalse(tool.name.isEmpty, "tool missing name")
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) missing description")
        }
    }

    func testAllSevenToolNamesMatchExpected() {
        let actual = Set(newTools.map { $0.name })
        XCTAssertEqual(actual, expectedToolNames)
    }

    func testAllSevenToolsExposeValidJSONSchema() {
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

    func testScreenPerceiveSchemaHasExpectedProperties() {
        let tool = ScreenPerceiveTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["force_ocr"])
        XCTAssertNotNil(props["app"])
        XCTAssertNotNil(props["format"])
        XCTAssertNotNil(props["max_elements"])
    }

    func testScreenQueryRequiresSelector() {
        let tool = ScreenQueryTool()
        let required = (tool.parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("selector"))
    }

    func testInvokeMenuRequiresPath() {
        let tool = InvokeMenuTool()
        let required = (tool.parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("path"))
    }

    func testFindElementRequiresRef() {
        let tool = FindElementTool()
        let required = (tool.parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("ref"))
    }

    func testSuggestActionsRequiresGoal() {
        let tool = SuggestActionsTool()
        let required = (tool.parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("goal"))
    }

    func testShortcutsHasEmptyParameters() {
        // list_shortcuts still exposes no parameters.
        let tool: any ToolDefinition = ShortcutsTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertTrue(props.isEmpty, "\(tool.name) should expose no parameters")
    }

    func testScreenDiff_AcceptsDeltaParameters() {
        // Rank 2 — `screen_diff` is now a back-compat alias for the delta
        // encoder and exposes `session_id` + `format` instead of being empty.
        let tool = ScreenDiffTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["session_id"],
                        "post-Rank 2 screen_diff must expose session_id")
        XCTAssertNotNil(props["format"],
                        "post-Rank 2 screen_diff must expose format")
    }

    // MARK: - Registration

    func testAllTools_registers_sevenPerceptionTools() {
        let names = Set(MetamorphiaExecutors.allTools.map { $0.tool.name })
        for expected in expectedToolNames {
            XCTAssertTrue(names.contains(expected),
                "MetamorphiaExecutors.allTools is missing '\(expected)'")
        }
    }

    func testAllTools_perceptionToolsUseScreenPerceptionCategory() {
        let perceptionNames = expectedToolNames
        for entry in MetamorphiaExecutors.allTools where perceptionNames.contains(entry.tool.name) {
            XCTAssertEqual(entry.category, .screenPerception,
                "\(entry.tool.name) should be categorized under .screenPerception")
        }
    }

    // MARK: - Execution (AX-permission gated)

    /// End-to-end capture test. AX permission is required; without it the
    /// pipeline still returns a ScreenMap (probably empty), so we just check
    /// the output is a non-empty string and parseable as text or JSON.
    func testScreenPerceive_textFormat_returnsNonEmpty() async throws {
        try skipIfHeadlessCI()
        let result = try await ScreenPerceiveTool().execute(arguments: "{}")
        XCTAssertFalse(result.isEmpty, "expected non-empty text output")
        XCTAssertFalse(result.hasPrefix("Error:"), "unexpected error: \(result)")
    }

    func testScreenPerceive_jsonFormat_returnsValidJSON() async throws {
        try skipIfHeadlessCI()
        let args = try json(["format": "json"])
        let result = try await ScreenPerceiveTool().execute(arguments: args)
        XCTAssertFalse(result.hasPrefix("Error:"), "unexpected error: \(result)")
        let data = result.data(using: .utf8) ?? Data()
        let obj = try? JSONSerialization.jsonObject(with: data)
        XCTAssertNotNil(obj, "screen_perceive(json) output must be valid JSON, got: \(result.prefix(200))")
    }

    // MARK: - Helpers

    private func json(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Skip execution-heavy tests in CI / headless environments. The capture
    /// pipeline requires `PerceptionRuntime` to have been bootstrapped (see
    /// `setUp`) — without it the pipeline traps on `PerceptionRuntime.host`.
    /// Even bootstrapped, CI runners with no display may trip on AppKit init or
    /// the menu-bar reader, so a conservative skip keeps green.
    private func skipIfHeadlessCI() throws {
        let env = ProcessInfo.processInfo.environment
        if env["CI"] != nil || env["METAMORPHIA_CI"] != nil || env["GITHUB_ACTIONS"] != nil {
            throw XCTSkip("Skipped in CI — AX capture requires a user session with Accessibility permission.")
        }
    }
}
