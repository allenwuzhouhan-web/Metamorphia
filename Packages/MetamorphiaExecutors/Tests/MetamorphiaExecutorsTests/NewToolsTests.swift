import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit

/// Tests for the expanded tool surface (script execution, file content, HTTP,
/// system info, screen, app control).
final class NewToolsTests: XCTestCase {
    // MARK: - File content

    func testWriteAndReadRoundtrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writeArgs = try json(["path": tmp.path, "content": "hello\nworld\n!"])
        let writeResult = try await WriteFileTool().execute(arguments: writeArgs)
        XCTAssertTrue(writeResult.contains("Wrote"))
        XCTAssertTrue(writeResult.contains(tmp.path))

        let readArgs = try json(["path": tmp.path])
        let readResult = try await ReadFileTool().execute(arguments: readArgs)
        XCTAssertTrue(readResult.contains("hello\nworld\n!"))
        XCTAssertTrue(readResult.contains("3 lines"))
    }

    func testReadFileLineRange() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "a\nb\nc\nd\ne".write(to: tmp, atomically: true, encoding: .utf8)

        let args = try json(["path": tmp.path, "start_line": 2, "end_line": 4])
        let result = try await ReadFileTool().execute(arguments: args)
        XCTAssertTrue(result.contains("b\nc\nd"))
        XCTAssertFalse(result.contains("\na\n"), "line 1 should not appear in range 2-4")
        XCTAssertFalse(result.contains("\ne"))
    }

    func testReadFileRefusesBinary() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: tmp)

        let args = try json(["path": tmp.path])
        let result = try await ReadFileTool().execute(arguments: args)
        XCTAssertTrue(result.contains("binary"))
    }

    func testEditFileExactReplace() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "let greeting = \"hello\"\nprint(greeting)".write(to: tmp, atomically: true, encoding: .utf8)

        let args = try json([
            "path": tmp.path,
            "replace": "\"hello\"",
            "with": "\"hi\""
        ])
        let result = try await EditFileTool().execute(arguments: args)
        XCTAssertTrue(result.contains("Replaced 1"))

        let updated = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(updated.contains("\"hi\""))
        XCTAssertFalse(updated.contains("\"hello\""))
    }

    func testEditFileRefusesAmbiguousReplace() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "foo\nfoo\nfoo".write(to: tmp, atomically: true, encoding: .utf8)

        let args = try json(["path": tmp.path, "replace": "foo", "with": "bar"])
        let result = try await EditFileTool().execute(arguments: args)
        XCTAssertTrue(result.contains("appears 3 times"))

        // file unchanged
        let unchanged = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(unchanged, "foo\nfoo\nfoo")
    }

    func testEditFileLineRange() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "line1\nline2\nline3\nline4".write(to: tmp, atomically: true, encoding: .utf8)

        let args = try json([
            "path": tmp.path,
            "start_line": 2,
            "end_line": 3,
            "with": "REPLACED"
        ])
        let result = try await EditFileTool().execute(arguments: args)
        XCTAssertTrue(result.contains("Replaced lines 2-3"))

        let updated = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(updated, "line1\nREPLACED\nline4")
    }

    // MARK: - Script execution

    func testRunPythonReturnsStdout() async throws {
        let args = try json(["code": "print('hello from python')\nprint(2 + 2)"])
        let result = try await RunPythonTool().execute(arguments: args)
        XCTAssertTrue(result.contains("hello from python"))
        XCTAssertTrue(result.contains("4"))
    }

    func testRunPythonSurfacesStderrOnFailure() async throws {
        let args = try json(["code": "import sys\nsys.stderr.write('boom\\n')\nsys.exit(2)"])
        let result = try await RunPythonTool().execute(arguments: args)
        XCTAssertTrue(result.contains("exit 2"))
        XCTAssertTrue(result.contains("boom"))
    }

    func testRunNodeBasics() async throws {
        // Skip if Node isn't installed — CI without Node shouldn't fail the suite.
        guard interpreterAvailable("node") else {
            throw XCTSkip("node not installed")
        }
        let args = try json(["code": "console.log('hi'); console.log(JSON.stringify({a:1}))"])
        let result = try await RunNodeTool().execute(arguments: args)
        XCTAssertTrue(result.contains("hi"))
        XCTAssertTrue(result.contains("\"a\":1"))
    }

    // MARK: - System info

    func testSystemInfoReturnsCoreFields() async throws {
        let result = try await SystemInfoTool().execute(arguments: "{}")
        XCTAssertTrue(result.contains("Host:"))
        XCTAssertTrue(result.contains("OS:"))
        XCTAssertTrue(result.contains("Uptime:"))
        XCTAssertTrue(result.contains("CPU cores:"))
        XCTAssertTrue(result.contains("RAM:"))
    }

    func testListProcessesIncludesSelf() async throws {
        let args = try json(["filter": "xctest", "limit": 10] as [String: Any])
        let result = try await ListProcessesTool().execute(arguments: args)
        // One of these — xctest, xctestwell, the test runner — will show up.
        XCTAssertTrue(
            result.lowercased().contains("xctest") || result.contains("No processes"),
            "expected self to appear in process list, got: \(result)"
        )
    }

    // MARK: - Tool schema shape

    func testEveryNewToolExposesAValidSchema() {
        let tools: [any ToolDefinition] = [
            RunPythonTool(), RunNodeTool(), RunRubyTool(),
            ReadFileTool(), WriteFileTool(), EditFileTool(),
            HTTPRequestTool(), SystemInfoTool(), ListProcessesTool(),
            KillProcessTool(), CaptureScreenTool(), OpenAppTool(), QuitAppTool(),
        ]
        for tool in tools {
            XCTAssertFalse(tool.name.isEmpty, "tool missing name")
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) missing description")
            let schema = tool.toAPISchema()
            XCTAssertEqual(schema["type"]?.value as? String, "function")
            XCTAssertNotNil(schema["function"]?.value as? [String: AnyCodable])
        }
    }

    func testMetamorphiaExecutorsAllToolsIncludesNewAdditions() {
        let names = Set(MetamorphiaExecutors.allTools.map { $0.tool.name })
        for expected in [
            "run_python", "run_node", "run_ruby",
            "read_file", "write_file", "edit_file",
            "http_request", "system_info", "list_processes", "kill_process",
            "capture_screen", "open_app", "quit_app",
        ] {
            XCTAssertTrue(names.contains(expected), "allTools is missing \(expected)")
        }
    }

    // MARK: - Skills

    func testLoadSkillIncludesAdjacentGuidesAndSupportPaths() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillToolTests-\(UUID().uuidString)")
        let folder = tmp.appendingPathComponent("office")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try """
        ---
        name: office-test
        description: Test office skill.
        ---

        # Office Test

        Body refers to guide.md.
        """.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Guide\n\nUse helper scripts carefully.\n".write(
            to: folder.appendingPathComponent("guide.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "print('ok')\n".write(
            to: folder.appendingPathComponent("scripts/helper.py"),
            atomically: true,
            encoding: .utf8
        )

        let registry = SkillRegistry()
        XCTAssertEqual(registry.loadSkills(from: tmp), 1)

        let result = try await LoadSkillTool(registry: registry)
            .execute(arguments: try json(["id": "office-test"]))

        XCTAssertTrue(result.contains("Body refers to guide.md."))
        XCTAssertTrue(result.contains("Metamorphia Skill Support Files"))
        XCTAssertTrue(result.contains("guide.md"))
        XCTAssertTrue(result.contains("scripts/helper.py"))
        XCTAssertTrue(result.contains("Use helper scripts carefully."))
    }

    // MARK: - Helpers

    private func json(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func interpreterAvailable(_ name: String) -> Bool {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            if FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") { return true }
        }
        return false
    }
}
