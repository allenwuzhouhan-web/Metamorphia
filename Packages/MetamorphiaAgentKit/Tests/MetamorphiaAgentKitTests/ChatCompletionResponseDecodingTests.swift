import XCTest
@testable import MetamorphiaAgentKit

/// Regression tests for the tolerant `ChatCompletionResponse` decoder.
/// The original Atoll incident: DeepSeek returned an HTTP-200 response with a
/// non-standard body after a 10-minute run, the strict decoder threw, and
/// the user saw an empty black notch with "response parse error". The fix
/// replaced the synthesized `Codable` implementation with a lenient custom
/// decoder + a surface-path hint; these tests pin that behavior in place.
final class ChatCompletionResponseDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Well-formed response — baseline sanity

    func testDecodesWellFormedResponse() throws {
        let json = """
        {
          "id": "chatcmpl-123",
          "choices": [
            {
              "index": 0,
              "message": { "role": "assistant", "content": "Hello there." },
              "finish_reason": "stop"
            }
          ],
          "usage": { "prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8 }
        }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(ChatCompletionResponse.self, from: json)

        XCTAssertEqual(decoded.id, "chatcmpl-123")
        XCTAssertEqual(decoded.choices.count, 1)
        XCTAssertEqual(decoded.choices.first?.message.content, "Hello there.")
        XCTAssertNil(decoded.topLevelError)
    }

    // MARK: - DeepSeek-style error-body-at-200 shape

    func testCapturesTopLevelErrorObject() throws {
        let json = """
        {
          "error": {
            "message": "The request timed out after 600 seconds.",
            "type": "timeout",
            "code": "deadline_exceeded"
          }
        }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(ChatCompletionResponse.self, from: json)

        XCTAssertTrue(decoded.choices.isEmpty)
        XCTAssertEqual(decoded.topLevelError, "The request timed out after 600 seconds.")
    }

    func testCapturesTopLevelErrorString() throws {
        let json = """
        { "error": "rate limit exceeded" }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(ChatCompletionResponse.self, from: json)

        XCTAssertEqual(decoded.topLevelError, "rate limit exceeded")
    }

    // MARK: - Missing `choices` field

    func testMissingChoicesDecodesAsEmptyArray() throws {
        let json = """
        { "id": "chatcmpl-empty" }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(ChatCompletionResponse.self, from: json)

        XCTAssertEqual(decoded.id, "chatcmpl-empty")
        XCTAssertTrue(decoded.choices.isEmpty)
        XCTAssertNil(decoded.topLevelError)
    }

    // MARK: - Malformed `message` inside a choice

    func testMalformedMessageFallsBackToEmptyAssistant() throws {
        // Message as an int instead of an object — the kind of mutation
        // thinking-model endpoints sometimes produce under load. We want the
        // choice to decode with a degraded assistant message rather than
        // taking down the whole response.
        let json = """
        {
          "choices": [
            { "index": 0, "message": 42, "finish_reason": "stop" }
          ]
        }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(ChatCompletionResponse.self, from: json)

        XCTAssertEqual(decoded.choices.count, 1)
        XCTAssertEqual(decoded.choices.first?.message.role, "assistant")
        XCTAssertNil(decoded.choices.first?.message.content)
    }

    // MARK: - Unknown fields should not break decoding

    func testIgnoresUnknownTopLevelFields() throws {
        let json = """
        {
          "id": "chatcmpl-1",
          "choices": [
            { "index": 0, "message": { "role": "assistant", "content": "hi" } }
          ],
          "model": "deepseek-chat",
          "created": 1700000000,
          "system_fingerprint": "fp_abc"
        }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(ChatCompletionResponse.self, from: json)

        XCTAssertEqual(decoded.choices.first?.message.content, "hi")
    }
}
