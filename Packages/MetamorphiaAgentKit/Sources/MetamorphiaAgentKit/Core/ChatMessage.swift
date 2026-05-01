import Foundation

// MARK: - Multimodal Content Block Types

/// A typed, Codable content block for vision messages.
/// Internal wire shape: {"type":"text","text":"..."} or {"type":"image","source":{...}}
/// aligning with Anthropic's content-block schema.
public enum ContentBlock: Codable, Sendable {
    case text(String)
    case image(MediaSource)

    private enum CodingKeys: String, CodingKey { case type, text, source }
    private enum BlockType: String { case text, image }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case BlockType.text.rawValue:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case BlockType.image.rawValue:
            let source = try container.decode(MediaSource.self, forKey: .source)
            self = .image(source)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                debugDescription: "Unknown ContentBlock type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let str):
            try container.encode(BlockType.text.rawValue, forKey: .type)
            try container.encode(str, forKey: .text)
        case .image(let source):
            try container.encode(BlockType.image.rawValue, forKey: .type)
            try container.encode(source, forKey: .source)
        }
    }
}

/// Describes where image data lives — inline base64 or a remote URL.
public struct MediaSource: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case base64, url }

    public let kind: Kind
    /// MIME type, e.g. "image/png", "image/jpeg".
    public let mediaType: String
    /// Base64-encoded bytes when kind == .base64; absolute URL string when kind == .url.
    public let data: String

    public init(kind: Kind, mediaType: String, data: String) {
        self.kind = kind
        self.mediaType = mediaType
        self.data = data
    }
}

// MARK: - Chat Message

/// One turn in an LLM conversation, in OpenAI-compatible shape.
///
/// Lenient decoding: different API providers (DeepSeek, Kimi, Gemini, MiniMax, Anthropic)
/// return slightly different JSON, so unknown fields and type mismatches are tolerated.
public struct ChatMessage: Codable, @unchecked Sendable {
    public let role: String
    public let content: String?
    public let tool_calls: [ToolCall]?
    public let tool_call_id: String?
    public let reasoning_content: String?

    /// Typed multimodal content blocks for vision LLMs (text + image). When set,
    /// the service layer uses these instead of plain `content`.
    public var contentBlocks: [ContentBlock]?

    public init(
        role: String,
        content: String?,
        tool_calls: [ToolCall]? = nil,
        tool_call_id: String? = nil,
        reasoning_content: String? = nil,
        contentBlocks: [ContentBlock]? = nil
    ) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.reasoning_content = reasoning_content
        self.contentBlocks = contentBlocks
    }

    /// Convenience constructor for vision user messages with mixed text + images.
    public static func userMessage(text: String, images: [MediaSource]) -> ChatMessage {
        let blocks: [ContentBlock] = [.text(text)] + images.map { .image($0) }
        return ChatMessage(role: "user", content: nil, contentBlocks: blocks)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
        tool_calls = try? container.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
        tool_call_id = try? container.decodeIfPresent(String.self, forKey: .tool_call_id)
        reasoning_content = try? container.decodeIfPresent(String.self, forKey: .reasoning_content)
        contentBlocks = try? container.decodeIfPresent([ContentBlock].self, forKey: .contentBlocks)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        try container.encodeIfPresent(reasoning_content, forKey: .reasoning_content)
        try container.encodeIfPresent(contentBlocks, forKey: .contentBlocks)
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id, reasoning_content, contentBlocks
    }
}

// MARK: - Tool Call

/// A single tool invocation emitted by the LLM.
public struct ToolCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let function: FunctionCall

    public struct FunctionCall: Codable, Sendable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        type = (try? container.decode(String.self, forKey: .type)) ?? "function"
        function = try container.decode(FunctionCall.self, forKey: .function)
    }

    public init(id: String, type: String, function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, function
    }
}

// MARK: - Requests / Responses

public struct ChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let tools: [[String: AnyCodable]]?
    public let tool_choice: String?
    public let max_tokens: Int?
    public let stream: Bool?

    public init(
        model: String,
        messages: [ChatMessage],
        tools: [[String: AnyCodable]]? = nil,
        tool_choice: String? = nil,
        max_tokens: Int? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.tool_choice = tool_choice
        self.max_tokens = max_tokens
        self.stream = stream
    }
}

public struct ChatCompletionResponse: Sendable {
    public let id: String?
    public let choices: [Choice]
    public let usage: Usage?
    /// DeepSeek (and occasionally other providers) will return HTTP 200 with
    /// `{ "error": { "message": "..." } }` in the body when they drop a
    /// request mid-flight. The caller should surface this as an API error
    /// rather than the generic "no response choices" string.
    public let topLevelError: String?

    public init(
        id: String? = nil,
        choices: [Choice] = [],
        usage: Usage? = nil,
        topLevelError: String? = nil
    ) {
        self.id = id
        self.choices = choices
        self.usage = usage
        self.topLevelError = topLevelError
    }

    public struct Choice: Codable, Sendable {
        public let index: Int
        public let message: ChatMessage
        public let finish_reason: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = (try? container.decodeIfPresent(Int.self, forKey: .index)) ?? 0
            // Be lenient: if `message` is absent or malformed (known
            // DeepSeek behavior under load — truncated responses, null
            // role fields, etc.), fall back to an empty assistant message
            // rather than aborting the whole decode. The AgentLoop treats
            // a no-content / no-tool-calls response as "done", so the
            // degraded message terminates the loop cleanly.
            if let decoded = try? container.decodeIfPresent(ChatMessage.self, forKey: .message) {
                message = decoded
            } else {
                if let raw = try? container.decodeIfPresent(AnyCodable.self, forKey: .message) {
                    print("[API] Choice.message malformed — raw: \(String(describing: raw.value).prefix(300))")
                } else {
                    print("[API] Choice.message missing or unreadable")
                }
                message = ChatMessage(role: "assistant", content: nil)
            }
            finish_reason = try? container.decodeIfPresent(String.self, forKey: .finish_reason)
        }

        public init(index: Int, message: ChatMessage, finish_reason: String?) {
            self.index = index
            self.message = message
            self.finish_reason = finish_reason
        }
        private enum CodingKeys: String, CodingKey { case index, message, finish_reason }
    }

    public struct Usage: Codable, Sendable {
        public let prompt_tokens: Int
        public let completion_tokens: Int
        public let total_tokens: Int

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prompt_tokens = (try? container.decode(Int.self, forKey: .prompt_tokens)) ?? 0
            completion_tokens = (try? container.decode(Int.self, forKey: .completion_tokens)) ?? 0
            total_tokens = (try? container.decode(Int.self, forKey: .total_tokens)) ?? 0
        }
        private enum CodingKeys: String, CodingKey { case prompt_tokens, completion_tokens, total_tokens }
    }
}

extension ChatCompletionResponse: Decodable {
    // Custom decoder so that (a) `choices` being absent or null doesn't abort
    // the whole request, and (b) a DeepSeek-style `{ "error": { "message":
    // ... } }` envelope is captured and surfaced through `topLevelError`
    // instead of falling through to a generic DecodingError.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        choices = (try? container.decodeIfPresent([Choice].self, forKey: .choices)) ?? []
        usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)

        if let errorContainer = try? container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error),
           let message = try? errorContainer.decode(String.self, forKey: .message) {
            topLevelError = message
        } else if let errorString = try? container.decodeIfPresent(String.self, forKey: .error) {
            topLevelError = errorString
        } else {
            topLevelError = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, choices, usage, error
    }
    private enum ErrorKeys: String, CodingKey {
        case message, code, type
    }
}

/// Normalized LLM response handed back to the agent loop.
public struct LLMResponse: @unchecked Sendable {
    public let text: String?
    public let toolCalls: [ToolCall]?
    public let rawMessage: ChatMessage

    public init(text: String?, toolCalls: [ToolCall]?, rawMessage: ChatMessage) {
        self.text = text
        self.toolCalls = toolCalls
        self.rawMessage = rawMessage
    }
}
