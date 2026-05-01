import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit

final class AppleScriptToolTests: XCTestCase {

    func testToolDefinitionShape() {
        let tool = RunAppleScriptTool()
        XCTAssertEqual(tool.name, "run_applescript")
        XCTAssertFalse(tool.description.isEmpty)
        XCTAssertNotNil(tool.parameters["properties"])
    }

    func testRunsTrivialScriptAndReturnsResult() async throws {
        let tool = RunAppleScriptTool()
        let args = #"{"script":"return \"hello\""}"#
        let result = try await tool.execute(arguments: args)
        XCTAssertEqual(result, "hello")
    }

    func testInvalidScriptThrows() async {
        let tool = RunAppleScriptTool()
        let args = #"{"script":"not valid applescript syntax !!"}"#
        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw on invalid AppleScript")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AppleScript"))
        }
    }

    func testMissingScriptArgumentThrowsInvalidArguments() async {
        let tool = RunAppleScriptTool()
        do {
            _ = try await tool.execute(arguments: "{}")
            XCTFail("expected throw on missing script arg")
        } catch let err as MetamorphiaError {
            if case .invalidArguments = err { return }
            XCTFail("expected .invalidArguments, got \(err)")
        } catch {
            XCTFail("expected MetamorphiaError, got \(error)")
        }
    }

    func testShellRunnerEchoesStdout() throws {
        let result = try ShellRunner.run("echo hello-world", timeout: 5)
        XCTAssertEqual(result.stdout, "hello-world")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRegisterAddsToolsToRegistry() {
        let registry = ToolRegistry()
        MetamorphiaExecutors.register(into: registry)
        XCTAssertGreaterThanOrEqual(registry.count, 2)
        XCTAssertNotNil(registry.tool(named: "run_applescript"))
        XCTAssertNotNil(registry.tool(named: "run_shell_command"))
    }
}
