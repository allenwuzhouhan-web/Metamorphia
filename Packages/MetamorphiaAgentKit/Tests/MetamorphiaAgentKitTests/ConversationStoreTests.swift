import XCTest
@testable import MetamorphiaAgentKit

final class ConversationStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> FileConversationStore {
        FileConversationStore(baseURL: tempDir)
    }

    // MARK: - testRoundTripSaveLoad

    func testRoundTripSaveLoad() async throws {
        let store = makeStore()
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are a helpful assistant."),
            ChatMessage(role: "user", content: "What is 2+2?"),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(
                        id: "call_abc",
                        type: "function",
                        function: ToolCall.FunctionCall(name: "calculator", arguments: "{\"expr\":\"2+2\"}")
                    )
                ]
            ),
            ChatMessage(role: "tool", content: "4", tool_call_id: "call_abc"),
            ChatMessage(role: "assistant", content: "The answer is 4."),
        ]

        try await store.save(sessionId: "test-session", messages: messages)
        let loaded = try await store.load(sessionId: "test-session")

        XCTAssertEqual(loaded.count, messages.count)
        for (orig, got) in zip(messages, loaded) {
            XCTAssertEqual(orig.role, got.role)
            XCTAssertEqual(orig.content, got.content)
            XCTAssertEqual(orig.tool_call_id, got.tool_call_id)
            XCTAssertEqual(orig.tool_calls?.first?.id, got.tool_calls?.first?.id)
            XCTAssertEqual(orig.tool_calls?.first?.function.name, got.tool_calls?.first?.function.name)
        }
    }

    // MARK: - testListSessionsOrdersByModificationDateDescending

    func testListSessionsOrdersByModificationDateDescending() async throws {
        let store = makeStore()

        try await store.save(sessionId: "alpha", messages: [ChatMessage(role: "user", content: "a")])
        // Give filesystem time to record distinct modification timestamps.
        try await Task.sleep(nanoseconds: 50_000_000)

        try await store.save(sessionId: "beta", messages: [ChatMessage(role: "user", content: "b")])
        try await Task.sleep(nanoseconds: 50_000_000)

        // Re-save alpha — it should now be newest.
        try await store.save(sessionId: "alpha", messages: [ChatMessage(role: "user", content: "a2")])

        let sessions = try await store.listSessions()
        XCTAssertEqual(sessions.first, "alpha", "alpha was saved last so it should be first")
        XCTAssertTrue(sessions.contains("beta"))
    }

    // MARK: - testDeleteRemovesSession

    func testDeleteRemovesSession() async throws {
        let store = makeStore()
        try await store.save(sessionId: "to-delete", messages: [ChatMessage(role: "user", content: "hi")])

        try await store.delete(sessionId: "to-delete")

        let loaded = try await store.load(sessionId: "to-delete")
        XCTAssertTrue(loaded.isEmpty, "After delete, load should return empty array")

        let sessions = try await store.listSessions()
        XCTAssertFalse(sessions.contains("to-delete"))
    }

    // MARK: - testSanitizesSessionId

    func testSanitizesSessionId() async throws {
        let store = makeStore()
        let dirtyId = "hello/world..with spaces"
        let messages = [ChatMessage(role: "user", content: "sanitize me")]

        // Should not crash during save.
        try await store.save(sessionId: dirtyId, messages: messages)

        // Load with the SAME id must return the saved messages (sanitization is deterministic).
        let loaded = try await store.load(sessionId: dirtyId)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.content, "sanitize me")
    }

    // MARK: - testContentBlocksRoundTrip

    func testContentBlocksRoundTrip() async throws {
        let store = makeStore()
        let image = MediaSource(kind: .base64, mediaType: "image/png", data: "AAAA")
        let msg = ChatMessage.userMessage(text: "hi", images: [image])

        try await store.save(sessionId: "vision-session", messages: [msg])
        let loaded = try await store.load(sessionId: "vision-session")

        XCTAssertEqual(loaded.count, 1)
        guard let blocks = loaded.first?.contentBlocks else {
            XCTFail("contentBlocks should be present after round-trip")
            return
        }
        XCTAssertEqual(blocks.count, 2, "Expected one text block and one image block")

        if case .text(let t) = blocks[0] {
            XCTAssertEqual(t, "hi")
        } else {
            XCTFail("First block should be text")
        }

        if case .image(let src) = blocks[1] {
            XCTAssertEqual(src.kind, .base64)
            XCTAssertEqual(src.mediaType, "image/png")
            XCTAssertEqual(src.data, "AAAA")
        } else {
            XCTFail("Second block should be image")
        }
    }
}
