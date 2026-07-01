import Foundation

/// Claude Messages API adapter.
///
/// Accepts OpenAI-shape `ChatMessage`s, converts them to Anthropic's message/content-block
/// shape on send, and converts the response back to a `LLMResponse` the agent loop expects.
///
/// Implements Anthropic's prompt caching (ephemeral) for both the system prompt (when ≥ 4096
/// chars) and the tools block (cache-control on the last tool). This materially reduces
/// per-iteration token cost for multi-turn agent tasks.
public final class AnthropicService: LLMServiceProtocol, @unchecked Sendable {
    private let model: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let anthropicVersion = "2023-06-01"
    private let urlSession: URLSession
    private weak var costTracker: LLMCostTracker?

    public init(
        model: String,
        urlSession: URLSession = .shared,
        costTracker: LLMCostTracker? = nil
    ) {
        self.model = model
        self.urlSession = urlSession
        self.costTracker = costTracker
    }

    public func sendChatRequest(
        messages: [ChatMessage],
        tools: [[String: AnyCodable]]?,
        maxTokens: Int = 2048
    ) async throws -> LLMResponse {
        // Log this call at its boundary (covers Claude's default streaming shim,
        // which routes through here). `defer` guarantees one entry on any exit.
        let logStartedAt = Date()
        let logInputChars = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        var logOutputChars = 0
        var logPromptTokens: Int? = nil
        var logCompletionTokens: Int? = nil
        var logSucceeded = false
        defer {
            APICallLog.shared.record(APICallLogEntry(
                date: logStartedAt,
                provider: LLMProvider.claude.rawValue,
                model: model,
                streaming: false,
                inputChars: logInputChars,
                outputChars: logOutputChars,
                promptTokens: logPromptTokens,
                completionTokens: logCompletionTokens,
                durationMs: Int(Date().timeIntervalSince(logStartedAt) * 1000),
                success: logSucceeded,
                error: nil
            ))
        }

        guard let apiKey = APIKeyManager.shared.getKey(for: .claude) else {
            throw MetamorphiaError.apiError("No API key configured. Open Settings to enter your Claude API key.")
        }

        guard let url = URL(string: baseURL) else {
            throw MetamorphiaError.apiError("Invalid Anthropic API URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // AUDIT (LOW): the Anthropic API key is sent in the standard `x-api-key`
        // request header over TLS — this is the provider-mandated auth mechanism,
        // not a query param, so there is no log/proxy leakage beyond what any HTTPS
        // header carries. No action required.
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let (systemPrompt, anthropicMessages) = convertMessages(messages)

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": anthropicMessages
        ]

        // Prompt caching: wrap system prompt in content-blocks array with cache_control
        // ephemeral when it exceeds the minimum cacheable size (~4K chars for Sonnet).
        if let system = systemPrompt {
            if system.count >= 4096 {
                body["system"] = [[
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"]
                ]]
            } else {
                body["system"] = system
            }
        }

        // Tools cache: apply cache_control to the LAST tool so everything before it
        // rolls into one cached block.
        if let tools = tools {
            var anthropicTools = convertToolDefinitions(tools)
            if var lastTool = anthropicTools.last, !anthropicTools.isEmpty {
                lastTool["cache_control"] = ["type": "ephemeral"]
                anthropicTools[anthropicTools.count - 1] = lastTool
            }
            body["tools"] = anthropicTools
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try await urlSession.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw MetamorphiaError.apiError("Invalid response")
        }

        guard http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw MetamorphiaError.apiError("Claude error: \(message)")
            }
            if errorText.contains("<html") || errorText.contains("<!DOCTYPE") {
                throw MetamorphiaError.apiError("Claude returned HTTP \(http.statusCode). The API endpoint may be down or unreachable.")
            }
            throw MetamorphiaError.apiError("Claude HTTP \(http.statusCode): \(String(errorText.prefix(200)))")
        }

        // Cost tracking if available.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usage = json["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            logPromptTokens = input
            logCompletionTokens = output
            costTracker?.record(
                provider: LLMProvider.claude.rawValue,
                inputTokens: input,
                outputTokens: output,
                agentId: costTracker?.activeAgentId
            )
        }

        let response = try parseResponse(data)
        logOutputChars = response.text?.count ?? 0
        logSucceeded = true
        return response
    }

    // MARK: - Message Conversion (OpenAI → Anthropic)

    private func convertMessages(_ messages: [ChatMessage]) -> (system: String?, messages: [[String: Any]]) {
        var systemPrompt: String?
        var anthropicMessages: [[String: Any]] = []

        var i = 0
        while i < messages.count {
            let msg = messages[i]

            if msg.role == "system" {
                if let content = msg.content {
                    if let existing = systemPrompt {
                        systemPrompt = existing + "\n\n" + content
                    } else {
                        systemPrompt = content
                    }
                }
                i += 1
                continue
            }

            if msg.role == "assistant" {
                if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                    var contentArray: [[String: Any]] = []
                    if let text = msg.content, !text.isEmpty {
                        contentArray.append(["type": "text", "text": text])
                    }
                    for call in toolCalls {
                        var input: Any = [String: Any]()
                        if let data = call.function.arguments.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: data) {
                            input = parsed
                        }
                        contentArray.append([
                            "type": "tool_use",
                            "id": call.id,
                            "name": call.function.name,
                            "input": input
                        ])
                    }
                    anthropicMessages.append(["role": "assistant", "content": contentArray])
                } else {
                    anthropicMessages.append(["role": "assistant", "content": msg.content ?? ""])
                }
                i += 1
                continue
            }

            if msg.role == "tool" {
                // Batch consecutive tool messages into one user message with tool_result blocks.
                var toolResults: [[String: Any]] = []
                while i < messages.count && messages[i].role == "tool" {
                    let toolMsg = messages[i]
                    toolResults.append([
                        "type": "tool_result",
                        "tool_use_id": toolMsg.tool_call_id ?? "",
                        "content": toolMsg.content ?? ""
                    ])
                    i += 1
                }
                anthropicMessages.append(["role": "user", "content": toolResults])
                continue
            }

            if let blocks = msg.contentBlocks, !blocks.isEmpty {
                let serialized = blocks.map { serializeContentBlock($0) }
                anthropicMessages.append(["role": msg.role, "content": serialized])
            } else {
                anthropicMessages.append(["role": msg.role, "content": msg.content ?? ""])
            }
            i += 1
        }

        return (systemPrompt, anthropicMessages)
    }

    // MARK: - Content Block Serialization

    /// Converts a typed ContentBlock into the Anthropic wire shape.
    /// Internal so tests can verify the wire shape directly.
    func serializeContentBlock(_ block: ContentBlock) -> [String: Any] {
        switch block {
        case .text(let str):
            return ["type": "text", "text": str]
        case .image(let source):
            switch source.kind {
            case .base64:
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": source.mediaType,
                        "data": source.data
                    ] as [String: Any]
                ]
            case .url:
                return [
                    "type": "image",
                    "source": [
                        "type": "url",
                        "url": source.data
                    ] as [String: Any]
                ]
            }
        }
    }

    // MARK: - Tool Definition Conversion (OpenAI → Anthropic)

    private func convertToolDefinitions(_ tools: [[String: AnyCodable]]) -> [[String: Any]] {
        return tools.compactMap { tool -> [String: Any]? in
            guard let funcWrapper = tool["function"],
                  let funcDict = funcWrapper.value as? [String: AnyCodable] else {
                return nil
            }

            let name = (funcDict["name"]?.value as? String) ?? ""
            let description = (funcDict["description"]?.value as? String) ?? ""
            let parameters = unwrapAnyCodable(funcDict["parameters"]?.value)

            var anthropicTool: [String: Any] = [
                "name": name,
                "description": description
            ]

            if let params = parameters as? [String: Any] {
                anthropicTool["input_schema"] = params
            } else {
                anthropicTool["input_schema"] = ["type": "object", "properties": [String: Any]()]
            }

            return anthropicTool
        }
    }

    private func unwrapAnyCodable(_ value: Any?) -> Any? {
        guard let value = value else { return nil }
        if let codable = value as? AnyCodable {
            return unwrapAnyCodable(codable.value)
        }
        if let dict = value as? [String: AnyCodable] {
            return dict.mapValues { unwrapAnyCodable($0.value) ?? NSNull() }
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { unwrapAnyCodable($0) ?? NSNull() }
        }
        if let arr = value as? [AnyCodable] {
            return arr.map { unwrapAnyCodable($0.value) ?? NSNull() }
        }
        if let arr = value as? [Any] {
            return arr.map { unwrapAnyCodable($0) ?? NSNull() }
        }
        return value
    }

    // MARK: - Response Parsing (Anthropic → LLMResponse)

    /// Layered response parser with fallbacks so a truncated or slightly malformed
    /// body still yields usable text rather than dropping the entire iteration.
    private func parseResponse(_ data: Data) throws -> LLMResponse {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let contentArray = json["content"] as? [[String: Any]] {
                return buildResponse(fromContent: contentArray)
            }
            if let errObj = json["error"] as? [String: Any] {
                let type = errObj["type"] as? String ?? "api_error"
                let msg = errObj["message"] as? String ?? "unknown"
                throw MetamorphiaError.apiError("Anthropic \(type): \(msg)")
            }
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        if !raw.isEmpty {
            let stripped = stripCodeFences(raw)
            if let fixed = stripped.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: fixed) as? [String: Any],
               let contentArray = json["content"] as? [[String: Any]] {
                return buildResponse(fromContent: contentArray)
            }

            let recoveredText = extractTextBlocks(from: raw)
            if !recoveredText.isEmpty {
                print("[Anthropic] parseResponse: falling back to regex-extracted text (\(recoveredText.count) chars)")
                let rawMessage = ChatMessage(role: "assistant", content: recoveredText, tool_calls: nil)
                return LLMResponse(text: recoveredText, toolCalls: nil, rawMessage: rawMessage)
            }
        }

        let preview = String(raw.prefix(200))
        throw MetamorphiaError.apiError("Invalid Anthropic response format (could not parse body, preview: '\(preview)')")
    }

    private func buildResponse(fromContent contentArray: [[String: Any]]) -> LLMResponse {
        var text: String?
        var toolCalls: [ToolCall] = []

        for block in contentArray {
            guard let type = block["type"] as? String else { continue }

            if type == "text", let t = block["text"] as? String {
                text = (text ?? "") + t
            } else if type == "tool_use" {
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                var arguments = "{}"
                if let input = block["input"] {
                    if let inputData = try? JSONSerialization.data(withJSONObject: input),
                       let inputStr = String(data: inputData, encoding: .utf8) {
                        arguments = inputStr
                    }
                }
                toolCalls.append(ToolCall(
                    id: id,
                    type: "function",
                    function: ToolCall.FunctionCall(name: name, arguments: arguments)
                ))
            }
        }

        let rawMessage = ChatMessage(
            role: "assistant",
            content: text,
            tool_calls: toolCalls.isEmpty ? nil : toolCalls
        )

        return LLMResponse(
            text: text,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            rawMessage: rawMessage
        )
    }

    private func stripCodeFences(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("```") {
            if let firstNewline = out.firstIndex(of: "\n") {
                out = String(out[out.index(after: firstNewline)...])
            }
        }
        if out.hasSuffix("```") {
            out = String(out.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    /// Extract every "text": "..." value we can find, concatenating them.
    /// Last-resort recovery when JSON is truncated or malformed.
    private func extractTextBlocks(from raw: String) -> String {
        let pattern = #""text"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "" }
        let range = NSRange(raw.startIndex..., in: raw)
        var pieces: [String] = []
        regex.enumerateMatches(in: raw, options: [], range: range) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: raw) else { return }
            let captured = String(raw[r])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\\", with: "\\")
            pieces.append(captured)
        }
        return pieces.joined(separator: "\n")
    }
}
