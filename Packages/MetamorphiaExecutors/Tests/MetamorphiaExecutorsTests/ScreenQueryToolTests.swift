import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit
import MetamorphiaPerception

/// Rank 6 — Tests for the rewritten `screen_query` tool.
///
/// Schema-shape tests are pure instantiation + dict inspection and run
/// anywhere. Execution tests hit AX and are gated behind the same CI
/// environment check as the other perception tool tests.
final class ScreenQueryToolTests: XCTestCase {

    // MARK: - Bootstrap

    /// `screen_query` execution reaches `PerceptionRuntime.host`, which
    /// `preconditionFailure`s (signal 5, aborting the whole test binary) if the
    /// runtime was never bootstrapped. Install a throwaway temp-dir host before
    /// any test runs. Idempotent and process-global.
    override class func setUp() {
        super.setUp()
        if !PerceptionRuntime.isBootstrapped {
            PerceptionRuntime.bootstrapForTests()
        }
    }

    // MARK: - Schema

    func testScreenQueryTool_schemaShape() {
        let tool = ScreenQueryTool()
        XCTAssertEqual(tool.name, "screen_query")
        XCTAssertFalse(tool.description.isEmpty)
        // Description should advertise at least the key grammar keywords.
        for keyword in ["role", "label", "near", "session_id"] {
            XCTAssertTrue(tool.description.contains(keyword),
                          "description should mention '\(keyword)'")
        }
        let params = tool.parameters
        XCTAssertEqual(params["type"] as? String, "object")
        let props = (params["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["selector"])
        let required = (params["required"] as? [String]) ?? []
        XCTAssertTrue(required.contains("selector"))
    }

    // MARK: - Error handling

    func testScreenQueryTool_malformedSelector_returnsError() async throws {
        // Empty selector triggers the required-param guard before reaching
        // the parser; use a malformed but non-empty one to exercise the
        // error JSON path.
        let args = try json(["selector": "zzz:foo"])
        let result = try await ScreenQueryTool().execute(arguments: args)

        // Output must be valid JSON …
        let data = result.data(using: .utf8) ?? Data()
        let parsed = try? JSONSerialization.jsonObject(with: data)
        XCTAssertNotNil(parsed, "malformed selector response must be valid JSON, got: \(result)")

        // … with `error` and `at` fields.
        if let dict = parsed as? [String: Any] {
            XCTAssertNotNil(dict["error"] as? String,
                "malformed selector response must include 'error' field, got: \(dict)")
            XCTAssertNotNil(dict["at"] as? Int,
                "malformed selector response must include 'at' offset, got: \(dict)")
        } else {
            XCTFail("expected error object, got: \(result)")
        }
    }

    // MARK: - Parameter schema

    func testScreenQueryTool_validSelector_returnsJSON_shape() async throws {
        try skipIfHeadlessCI()
        // A valid but likely-empty selector (no AX elements on the test
        // harness display will match this label). We only care that:
        //  - execution doesn't throw
        //  - output parses as a JSON array
        //  - per-element shape matches the spec
        let args = try json(["selector": "role:button label*__unlikely_label__", "max_results": 5])
        let result = try await ScreenQueryTool().execute(arguments: args)

        let data = result.data(using: .utf8) ?? Data()
        let parsed = try? JSONSerialization.jsonObject(with: data)
        // Could be empty array, or array of results, or an error object — only
        // the empty/result array cases are "valid shape" here.
        if let arr = parsed as? [[String: Any]] {
            for row in arr {
                XCTAssertNotNil(row["ref"] as? String, "each row must have ref")
                XCTAssertNotNil(row["role"] as? String, "each row must have role")
                XCTAssertNotNil(row["label"] as? String, "each row must have label")
                XCTAssertNotNil(row["matchScore"] as? Double, "each row must have matchScore")
            }
        } else if let dict = parsed as? [String: Any], dict["error"] != nil {
            // Error shape is acceptable too — it means the selector parsed
            // but executing the query elsewhere failed. Test is still green.
        } else {
            XCTFail("expected JSON array or error object, got: \(result)")
        }
    }

    func testScreenQueryTool_sessionIDParam_InSchema() {
        let tool = ScreenQueryTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["session_id"],
                        "screen_query must expose session_id to reuse SnapshotCache maps")
    }

    func testScreenQueryTool_maxResultsParam_InSchema() {
        let tool = ScreenQueryTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["max_results"],
                        "screen_query must expose max_results for truncation")
    }

    // MARK: - Helpers

    private func json(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func skipIfHeadlessCI() throws {
        let env = ProcessInfo.processInfo.environment
        if env["CI"] != nil || env["METAMORPHIA_CI"] != nil || env["GITHUB_ACTIONS"] != nil {
            throw XCTSkip("Skipped in CI — AX capture requires a user session with Accessibility permission.")
        }
    }
}
