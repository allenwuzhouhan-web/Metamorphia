import XCTest
@testable import MetamorphiaAgentKit

final class MultimodalMessageTests: XCTestCase {

    // MARK: - Task 1: Codable round-trip

    func testContentBlockRoundTrip() throws {
        let source = MediaSource(kind: .base64, mediaType: "image/png", data: "abc123==")
        let msg = ChatMessage(
            role: "user",
            content: nil,
            contentBlocks: [.text("hello"), .image(source)]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.role, "user")
        XCTAssertNil(decoded.content)
        XCTAssertEqual(decoded.contentBlocks?.count, 2)

        if case .text(let t) = decoded.contentBlocks?[0] {
            XCTAssertEqual(t, "hello")
        } else {
            XCTFail("First block should be .text")
        }

        if case .image(let s) = decoded.contentBlocks?[1] {
            XCTAssertEqual(s.kind, .base64)
            XCTAssertEqual(s.mediaType, "image/png")
            XCTAssertEqual(s.data, "abc123==")
        } else {
            XCTFail("Second block should be .image")
        }
    }

    func testURLImageBlockRoundTrip() throws {
        let source = MediaSource(kind: .url, mediaType: "image/jpeg", data: "https://example.com/photo.jpg")
        let msg = ChatMessage.userMessage(text: "What is this?", images: [source])

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.contentBlocks?.count, 2)
        if case .image(let s) = decoded.contentBlocks?[1] {
            XCTAssertEqual(s.kind, .url)
            XCTAssertEqual(s.data, "https://example.com/photo.jpg")
        } else {
            XCTFail("Second block should be .image")
        }
    }

    // MARK: - Task 1: backward-compatible decoding

    func testTextOnlyMessageDecodesAsBefore() throws {
        let json = """
        {"role":"user","content":"hello there"}
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(ChatMessage.self, from: json)

        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.content, "hello there")
        XCTAssertNil(msg.contentBlocks)
    }

    func testExistingInitWithoutContentBlocksStillCompiles() {
        // Verify the existing convenience init signature is unchanged.
        let msg = ChatMessage(role: "assistant", content: "hi")
        XCTAssertNil(msg.contentBlocks)
        XCTAssertEqual(msg.content, "hi")
    }

    func testUserMessageConvenienceConstructor() {
        let images = [MediaSource(kind: .base64, mediaType: "image/png", data: "data")]
        let msg = ChatMessage.userMessage(text: "Describe this", images: images)
        XCTAssertEqual(msg.role, "user")
        XCTAssertNil(msg.content)
        XCTAssertEqual(msg.contentBlocks?.count, 2)
        if case .text(let t) = msg.contentBlocks?[0] { XCTAssertEqual(t, "Describe this") }
        else { XCTFail("Expected .text first block") }
    }

    // MARK: - Task 2: Anthropic serialization shape

    func testAnthropicSerializesBase64ImageBlocks() {
        let service = AnthropicService(model: "claude-sonnet-4-6-20260320")
        let source = MediaSource(kind: .base64, mediaType: "image/jpeg", data: "base64data")

        let textBlock = service.serializeContentBlock(.text("what is this"))
        XCTAssertEqual(textBlock["type"] as? String, "text")
        XCTAssertEqual(textBlock["text"] as? String, "what is this")

        let imageBlock = service.serializeContentBlock(.image(source))
        XCTAssertEqual(imageBlock["type"] as? String, "image")
        let imageSource = imageBlock["source"] as? [String: Any]
        XCTAssertEqual(imageSource?["type"] as? String, "base64")
        XCTAssertEqual(imageSource?["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(imageSource?["data"] as? String, "base64data")
    }

    func testAnthropicSerializesURLImageBlocks() {
        let service = AnthropicService(model: "claude-sonnet-4-6-20260320")
        let source = MediaSource(kind: .url, mediaType: "image/png", data: "https://example.com/img.png")

        let imageBlock = service.serializeContentBlock(.image(source))
        XCTAssertEqual(imageBlock["type"] as? String, "image")
        let imageSource = imageBlock["source"] as? [String: Any]
        XCTAssertEqual(imageSource?["type"] as? String, "url")
        XCTAssertEqual(imageSource?["url"] as? String, "https://example.com/img.png")
    }

    // MARK: - Task 3: OpenAI serialization shape

    func testOpenAISerializesBase64ImageBlocks() {
        let service = OpenAICompatibleService(provider: .openai, model: "gpt-4o")
        let source = MediaSource(kind: .base64, mediaType: "image/png", data: "base64data")

        let textPart = service.serializeOpenAIContentBlock(.text("look at this"))
        XCTAssertEqual(textPart["type"] as? String, "text")
        XCTAssertEqual(textPart["text"] as? String, "look at this")

        let imagePart = service.serializeOpenAIContentBlock(.image(source))
        XCTAssertEqual(imagePart["type"] as? String, "image_url")
        let imageURL = imagePart["image_url"] as? [String: Any]
        XCTAssertEqual(imageURL?["url"] as? String, "data:image/png;base64,base64data")
    }

    func testOpenAISerializesURLImageBlocks() {
        let service = OpenAICompatibleService(provider: .openai, model: "gpt-4o")
        let source = MediaSource(kind: .url, mediaType: "image/jpeg", data: "https://example.com/img.jpg")

        let imagePart = service.serializeOpenAIContentBlock(.image(source))
        XCTAssertEqual(imagePart["type"] as? String, "image_url")
        let imageURL = imagePart["image_url"] as? [String: Any]
        XCTAssertEqual(imageURL?["url"] as? String, "https://example.com/img.jpg")
    }

    // MARK: - Task 4: SmartRouter vision model selection

    func testSmartRouterPicksVisionModelForImage() {
        let source = MediaSource(kind: .base64, mediaType: "image/png", data: "data")
        let messages = [ChatMessage.userMessage(text: "describe this", images: [source])]

        XCTAssertTrue(SmartRouter.hasImageContent(messages))

        // Non-vision model should be overridden to the vision fallback.
        let recommended = SmartRouter.recommendedModel(
            for: messages,
            currentModel: "deepseek-chat",
            provider: .claude
        )
        XCTAssertEqual(recommended, "claude-sonnet-4-6-20260320")
    }

    func testSmartRouterKeepsVisionModelUnchanged() {
        let source = MediaSource(kind: .base64, mediaType: "image/png", data: "data")
        let messages = [ChatMessage.userMessage(text: "describe this", images: [source])]

        let recommended = SmartRouter.recommendedModel(
            for: messages,
            currentModel: "claude-sonnet-4-6-20260320",
            provider: .claude
        )
        XCTAssertEqual(recommended, "claude-sonnet-4-6-20260320")
    }

    func testSmartRouterDoesNotOverrideForTextOnly() {
        let messages = [ChatMessage(role: "user", content: "hello")]

        XCTAssertFalse(SmartRouter.hasImageContent(messages))

        let recommended = SmartRouter.recommendedModel(
            for: messages,
            currentModel: "deepseek-chat",
            provider: .deepseek
        )
        XCTAssertEqual(recommended, "deepseek-chat")
    }

    func testSmartRouterOpenAIVisionFallback() {
        let source = MediaSource(kind: .url, mediaType: "image/jpeg", data: "https://example.com/img.jpg")
        let messages = [ChatMessage.userMessage(text: "what is in this image?", images: [source])]

        let recommended = SmartRouter.recommendedModel(
            for: messages,
            currentModel: "gpt-4.1-nano",
            provider: .openai
        )
        XCTAssertEqual(recommended, "gpt-4o")
    }
}
