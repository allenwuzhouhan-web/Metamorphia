import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit
import MetamorphiaPerception

/// Rank 9 — GestureTools bridge tests.
///
/// Event-posting tests are deliberately omitted — real CGEvent posts would
/// disturb the user's session and be unreliable across CI environments.
/// These tests cover the deterministic surface: schema shape, registration
/// presence, and the KeyComboTool parser logic.
final class GestureToolsTests: XCTestCase {

    /// Bootstraps the process-global perception runtime before any perception
    /// test runs; without it the pipeline traps in PerceptionHost and aborts the
    /// whole test binary. Idempotent and process-global.
    override class func setUp() {
        super.setUp()
        if !PerceptionRuntime.isBootstrapped {
            PerceptionRuntime.bootstrapForTests()
        }
    }

    // MARK: - Inventory

    private var newTools: [any ToolDefinition] {
        [
            ClickAtTool(),
            DoubleClickAtTool(),
            RightClickAtTool(),
            DragTool(),
            SwipeTool(),
            ScrollTool(),
            LongPressTool(),
            TypeTextTool(),
            KeyComboTool(),
            MoveMouseTool(),
        ]
    }

    private var expectedToolNames: Set<String> {
        [
            "click_at", "double_click_at", "right_click_at",
            "drag", "swipe", "scroll", "long_press",
            "type_text", "key_combo", "move_mouse",
        ]
    }

    // MARK: - Schema Shape

    func testAllTenToolsHaveNames() {
        for tool in newTools {
            XCTAssertFalse(tool.name.isEmpty, "tool missing name")
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) missing description")
        }
    }

    func testAllTenToolNamesMatchExpected() {
        let actual = Set(newTools.map { $0.name })
        XCTAssertEqual(actual, expectedToolNames)
    }

    func testAllTenToolsExposeValidJSONSchema() {
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

    func testClickAtRequiresXY() {
        let required = (ClickAtTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("x"))
        XCTAssertTrue(required.contains("y"))
    }

    func testDoubleClickAtRequiresXY() {
        let required = (DoubleClickAtTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("x"))
        XCTAssertTrue(required.contains("y"))
    }

    func testRightClickAtRequiresXY() {
        let required = (RightClickAtTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("x"))
        XCTAssertTrue(required.contains("y"))
    }

    func testDragToolRequiresAllFourCoords() {
        let required = (DragTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("from_x"))
        XCTAssertTrue(required.contains("from_y"))
        XCTAssertTrue(required.contains("to_x"))
        XCTAssertTrue(required.contains("to_y"))
    }

    func testSwipeToolRequiresDirectionDistanceStart() {
        let required = (SwipeTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("direction"))
        XCTAssertTrue(required.contains("distance"))
        XCTAssertTrue(required.contains("start_x"))
        XCTAssertTrue(required.contains("start_y"))
    }

    func testScrollToolRequiresDirectionLines() {
        let required = (ScrollTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("direction"))
        XCTAssertTrue(required.contains("lines"))
    }

    func testLongPressToolRequiresXY() {
        let required = (LongPressTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("x"))
        XCTAssertTrue(required.contains("y"))
    }

    func testTypeTextToolRequiresText() {
        let required = (TypeTextTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("text"))
    }

    func testKeyComboToolRequiresKeys() {
        let required = (KeyComboTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("keys"))
    }

    func testMoveMouseToolRequiresXY() {
        let required = (MoveMouseTool().parameters["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("x"))
        XCTAssertTrue(required.contains("y"))
    }

    // MARK: - Registration

    func testAllTools_registers_tenGestureTools() {
        let names = Set(MetamorphiaExecutors.allTools.map { $0.tool.name })
        for expected in expectedToolNames {
            XCTAssertTrue(names.contains(expected),
                "MetamorphiaExecutors.allTools is missing '\(expected)'")
        }
    }

    func testAllTools_gestureToolsUseInputCategory() {
        for entry in MetamorphiaExecutors.allTools where expectedToolNames.contains(entry.tool.name) {
            XCTAssertEqual(entry.category, .input,
                "\(entry.tool.name) should be categorized under .input")
        }
    }

    // MARK: - KeyComboTool parseKeyCombo

    func testParseKeyCombo_cmdS() throws {
        let (mods, keys) = try KeyComboTool.parseKeyCombo(["cmd", "s"])
        XCTAssertEqual(mods, .command)
        XCTAssertEqual(keys.count, 1)
        if case .character(let c) = keys[0] {
            XCTAssertEqual(c, "s")
        } else {
            XCTFail("Expected .character('s'), got \(keys[0])")
        }
    }

    func testParseKeyCombo_cmdShiftS() throws {
        let (mods, keys) = try KeyComboTool.parseKeyCombo(["cmd", "shift", "s"])
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertEqual(keys.count, 1)
    }

    func testParseKeyCombo_allFourStandardModifiers() throws {
        let (mods, keys) = try KeyComboTool.parseKeyCombo(["cmd", "shift", "alt", "ctrl", "a"])
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertTrue(mods.contains(.option))
        XCTAssertTrue(mods.contains(.control))
        XCTAssertEqual(keys.count, 1)
    }

    func testParseKeyCombo_commonAliases() throws {
        // "command" === "cmd", "option" === "opt" === "alt", "control" === "ctrl".
        let (mods, _) = try KeyComboTool.parseKeyCombo(["command", "option", "control", "a"])
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.option))
        XCTAssertTrue(mods.contains(.control))
    }

    func testParseKeyCombo_caseInsensitive() throws {
        let (mods, keys) = try KeyComboTool.parseKeyCombo(["Cmd", "Shift", "S"])
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertEqual(keys.count, 1)
    }

    func testParseKeyCombo_namedKey_enter() throws {
        let (mods, keys) = try KeyComboTool.parseKeyCombo(["cmd", "enter"])
        XCTAssertEqual(mods, .command)
        XCTAssertEqual(keys.count, 1)
        if case .enter = keys[0] { /* ok */ } else {
            XCTFail("Expected .enter, got \(keys[0])")
        }
    }

    func testParseKeyCombo_functionKey_f5() throws {
        let (_, keys) = try KeyComboTool.parseKeyCombo(["f5"])
        XCTAssertEqual(keys.count, 1)
        if case .f5 = keys[0] { /* ok */ } else {
            XCTFail("Expected .f5, got \(keys[0])")
        }
    }

    func testParseKeyCombo_unknownToken_throws() {
        XCTAssertThrowsError(try KeyComboTool.parseKeyCombo(["garbage"])) { error in
            guard let parseErr = error as? KeyComboTool.KeyComboParseError else {
                XCTFail("Expected KeyComboParseError, got \(error)")
                return
            }
            XCTAssertEqual(parseErr.token, "garbage")
        }
    }

    // MARK: - End-to-end execute (error path)

    /// KeyComboTool with a malformed input should return a human-readable
    /// error string rather than throwing.
    func testKeyComboTool_execute_withGarbageToken_returnsErrorString() async throws {
        let tool = KeyComboTool()
        let result = try await tool.execute(arguments: #"{"keys":["garbage"]}"#)
        XCTAssertTrue(result.hasPrefix("Error:"), "expected error, got: \(result)")
        XCTAssertTrue(result.contains("garbage"))
    }

    func testKeyComboTool_execute_emptyKeys_returnsErrorString() async throws {
        let tool = KeyComboTool()
        let result = try await tool.execute(arguments: #"{"keys":[]}"#)
        XCTAssertTrue(result.hasPrefix("Error:"), "expected error, got: \(result)")
    }

    func testKeyComboTool_execute_missingKeysParam_returnsErrorString() async throws {
        let tool = KeyComboTool()
        let result = try await tool.execute(arguments: "{}")
        XCTAssertTrue(result.hasPrefix("Error:"), "expected error, got: \(result)")
    }

    func testClickAtTool_missingArgs_returnsErrorString() async throws {
        let tool = ClickAtTool()
        let result = try await tool.execute(arguments: "{}")
        XCTAssertTrue(result.hasPrefix("Error:"), "expected error, got: \(result)")
    }

    func testScrollTool_invalidDirection_returnsErrorString() async throws {
        let tool = ScrollTool()
        let result = try await tool.execute(arguments: #"{"direction":"sideways","lines":3}"#)
        XCTAssertTrue(result.hasPrefix("Error:"), "expected error, got: \(result)")
    }

    func testSwipeTool_invalidDirection_returnsErrorString() async throws {
        let tool = SwipeTool()
        let result = try await tool.execute(
            arguments: #"{"direction":"sideways","distance":100,"start_x":0,"start_y":0}"#
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "expected error, got: \(result)")
    }
}
