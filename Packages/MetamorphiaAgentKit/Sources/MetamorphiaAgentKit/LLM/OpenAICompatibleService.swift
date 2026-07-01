import Foundation

// Cached JSON coders — avoid re-creating per API call.
private let sharedJSONEncoder = JSONEncoder()
private let sharedJSONDecoder = JSONDecoder()

/// OpenAI-compatible LLM service for DeepSeek, Gemini, Kimi, MiniMax, OpenAI.
///
/// Uses `URLSession.shared` for HTTP. Executer shipped a `PinnedURLSession` with
/// certificate pinning; that's a future addition — the app target can inject a
/// custom `URLSession` via a `URLSessionProvider` protocol when we need it.
public final class OpenAICompatibleService: LLMServiceProtocol, @unchecked Sendable {
    private let provider: LLMProvider
    private let model: String
    private let urlSession: URLSession
    private weak var costTracker: LLMCostTracker?

    public init(
        provider: LLMProvider,
        model: String,
        urlSession: URLSession = .shared,
        costTracker: LLMCostTracker? = nil
    ) {
        self.provider = provider
        self.model = model
        self.urlSession = urlSession
        self.costTracker = costTracker
    }

    public func sendChatRequest(
        messages: [ChatMessage],
        tools: [[String: AnyCodable]]?,
        maxTokens: Int = 2048
    ) async throws -> LLMResponse {
        // Log this call at its boundary. `defer` guarantees one entry whether the
        // request returns or throws; the success/token fields are filled in below.
        let logStartedAt = Date()
        let logInputChars = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        var logOutputChars = 0
        var logPromptTokens: Int? = nil
        var logCompletionTokens: Int? = nil
        var logSucceeded = false
        defer {
            APICallLog.shared.record(APICallLogEntry(
                date: logStartedAt,
                provider: provider.rawValue,
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

        guard let apiKey = APIKeyManager.shared.getKey(for: provider) else {
            throw MetamorphiaError.apiError("No API key configured. Open Settings to enter your \(provider.config.displayName) API key.")
        }

        guard let url = URL(string: provider.config.baseURL) else {
            throw MetamorphiaError.apiError("Invalid API URL for \(provider.config.displayName).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if provider == .kimiCN || provider == .kimi {
            request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
        }

        // Use vision-aware serialization when any message carries image blocks.
        if messages.contains(where: { $0.contentBlocks != nil }) {
            request.httpBody = try buildVisionRequestBody(
                model: model,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                stream: false
            )
        } else {
            let body = ChatCompletionRequest(
                model: model,
                messages: messages,
                tools: tools,
                tool_choice: tools != nil ? "auto" : nil,
                max_tokens: maxTokens,
                stream: false
            )
            request.httpBody = try sharedJSONEncoder.encode(body)
        }

        let (data, httpResponse) = try await urlSession.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw MetamorphiaError.apiError("Invalid response")
        }

        guard http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                var hint = ""
                if (provider == .kimi || provider == .kimiCN) && (http.statusCode == 401 || http.statusCode == 403) {
                    hint = " (Note: Kimi keys from platform.moonshot.cn won't work with the .ai endpoint, and vice versa. Use the matching provider.)"
                }
                throw MetamorphiaError.apiError("\(provider.config.displayName) error: \(message)\(hint)")
            }
            if errorText.contains("<html") || errorText.contains("<!DOCTYPE") || errorText.contains("<HTML") {
                throw MetamorphiaError.apiError("\(provider.config.displayName) returned HTTP \(http.statusCode). The API endpoint may be down or unreachable. Check your API key and try again.")
            }
            throw MetamorphiaError.apiError("\(provider.config.displayName) HTTP \(http.statusCode): \(String(errorText.prefix(200)))")
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try sharedJSONDecoder.decode(ChatCompletionResponse.self, from: data)
        } catch let decodingError as DecodingError {
            let preview = String(data: data, encoding: .utf8)?.prefix(500) ?? "unreadable"
            if preview.contains("<html") || preview.contains("<!DOCTYPE") {
                throw MetamorphiaError.apiError("\(provider.config.displayName) returned HTML instead of JSON. The API endpoint may be misconfigured or down.")
            }
            let pathHint = Self.describe(decodingError)
            print("[API] \(provider.config.displayName) parse failure at \(pathHint). Raw: \(preview)")
            print("[API] Decode error: \(decodingError)")
            throw MetamorphiaError.apiError(
                "\(provider.config.displayName) returned an unexpected format at \(pathHint). "
                + "Try a different model or check provider status."
            )
        } catch {
            print("[API] \(provider.config.displayName) unexpected decode error: \(error)")
            throw MetamorphiaError.apiError(
                "\(provider.config.displayName) response error: \(error.localizedDescription)"
            )
        }

        // DeepSeek returns HTTP 200 with a `{ "error": { "message": ... } }`
        // body under load. Our lenient decoder captures that into
        // `topLevelError`; surface it as a specific API error instead of
        // silently falling through to the "no choices" branch.
        if let topLevelError = decoded.topLevelError {
            throw MetamorphiaError.apiError("\(provider.config.displayName): \(topLevelError)")
        }

        guard let choice = decoded.choices.first else {
            throw MetamorphiaError.apiError("\(provider.config.displayName) returned no response choices.")
        }

        if let usage = decoded.usage {
            logPromptTokens = usage.prompt_tokens
            logCompletionTokens = usage.completion_tokens
            costTracker?.record(
                provider: provider.rawValue,
                inputTokens: usage.prompt_tokens,
                outputTokens: usage.completion_tokens,
                agentId: costTracker?.activeAgentId
            )
        }

        // Use content if available; fall back to reasoning_content for thinking models.
        let text = (choice.message.content?.isEmpty == false ? choice.message.content : nil)
            ?? choice.message.reasoning_content

        logOutputChars = text?.count ?? 0
        logSucceeded = true
        return LLMResponse(
            text: text,
            toolCalls: choice.message.tool_calls,
            rawMessage: choice.message
        )
    }

    // MARK: - Vision Request Body

    /// Serializes a request with potential image content into OpenAI's vision format,
    /// where messages with contentBlocks get a `content` array instead of a string.
    private func buildVisionRequestBody(
        model: String,
        messages: [ChatMessage],
        tools: [[String: AnyCodable]]?,
        maxTokens: Int,
        stream: Bool
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream
        ]

        if let tools = tools, !tools.isEmpty {
            body["tool_choice"] = "auto"
            // Re-use the shared encoder to serialize tools via AnyCodable.
            if let toolsData = try? sharedJSONEncoder.encode(tools),
               let toolsJson = try? JSONSerialization.jsonObject(with: toolsData) {
                body["tools"] = toolsJson
            }
        }

        body["messages"] = messages.map { serializeOpenAIMessage($0) }

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Converts a ChatMessage to OpenAI's wire shape, using vision content array when needed.
    private func serializeOpenAIMessage(_ msg: ChatMessage) -> [String: Any] {
        var out: [String: Any] = ["role": msg.role]

        if let blocks = msg.contentBlocks, !blocks.isEmpty {
            out["content"] = blocks.map { serializeOpenAIContentBlock($0) }
        } else if let content = msg.content {
            out["content"] = content
        }

        if let toolCalls = msg.tool_calls {
            out["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                [
                    "id": tc.id,
                    "type": tc.type,
                    "function": ["name": tc.function.name, "arguments": tc.function.arguments]
                ]
            }
        }
        if let toolCallId = msg.tool_call_id {
            out["tool_call_id"] = toolCallId
        }

        return out
    }

    /// Converts a ContentBlock to OpenAI's vision content-part shape.
    /// Internal so tests can verify the wire shape directly.
    func serializeOpenAIContentBlock(_ block: ContentBlock) -> [String: Any] {
        switch block {
        case .text(let str):
            return ["type": "text", "text": str]
        case .image(let source):
            let urlString: String
            switch source.kind {
            case .base64:
                urlString = "data:\(source.mediaType);base64,\(source.data)"
            case .url:
                urlString = source.data
            }
            return ["type": "image_url", "image_url": ["url": urlString] as [String: Any]]
        }
    }

    /// Join the coding-path of a `DecodingError` into a human-readable
    /// dotted string like `choices[0].message.role`. Used to surface
    /// actionable parse failures instead of Swift's opaque
    /// `DecodingError.localizedDescription`.
    private static func describe(_ err: DecodingError) -> String {
        func format(_ path: [CodingKey]) -> String {
            guard !path.isEmpty else { return "<root>" }
            return path.map { key in
                if let intVal = key.intValue { return "[\(intVal)]" }
                return key.stringValue
            }.joined(separator: ".")
                .replacingOccurrences(of: ".[", with: "[")
        }
        switch err {
        case .keyNotFound(let key, let ctx):
            return format(ctx.codingPath) + (ctx.codingPath.isEmpty ? "" : ".") + "<missing:\(key.stringValue)>"
        case .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx),
             .dataCorrupted(let ctx):
            return format(ctx.codingPath)
        @unknown default:
            return "<unknown>"
        }
    }

    public func streamChatRequest(
        messages: [ChatMessage],
        tools: [[String: AnyCodable]]?,
        maxTokens: Int
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { [self] continuation in
            let logStartedAt = Date()
            let logInputChars = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }
            let producer = Task {
                do {
                    guard let apiKey = APIKeyManager.shared.getKey(for: provider) else {
                        continuation.finish(throwing: MetamorphiaError.apiError("No API key configured for \(provider.config.displayName)."))
                        return
                    }
                    guard let url = URL(string: provider.config.baseURL) else {
                        continuation.finish(throwing: MetamorphiaError.apiError("Invalid API URL for \(provider.config.displayName)."))
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 120
                    if provider == .kimiCN || provider == .kimi {
                        request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
                    }

                    // Use vision-aware serialization when any message carries image blocks.
                    if messages.contains(where: { $0.contentBlocks != nil }) {
                        request.httpBody = try buildVisionRequestBody(
                            model: model,
                            messages: messages,
                            tools: (tools?.isEmpty ?? true) ? nil : tools,
                            maxTokens: maxTokens,
                            stream: true
                        )
                    } else {
                        let body = ChatCompletionRequest(
                            model: model,
                            messages: messages,
                            tools: (tools?.isEmpty ?? true) ? nil : tools,
                            tool_choice: tools != nil ? "auto" : nil,
                            max_tokens: maxTokens,
                            stream: true
                        )
                        request.httpBody = try sharedJSONEncoder.encode(body)
                    }

                    let (bytes, httpResponse) = try await urlSession.bytes(for: request)

                    guard let http = httpResponse as? HTTPURLResponse, http.statusCode == 200 else {
                        throw MetamorphiaError.apiError("Stream request failed with HTTP \((httpResponse as? HTTPURLResponse)?.statusCode ?? 0)")
                    }

                    var accumulatedText = ""
                    var toolCallAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]

                    for try await line in bytes.lines {
                        // Unwind the byte stream and close the HTTP connection
                        // promptly when the consumer abandons the stream.
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if json == "[DONE]" { break }

                        guard let data = json.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = chunk["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }

                        if let content = delta["content"] as? String {
                            accumulatedText += content
                            continuation.yield(.textDelta(content))
                        }

                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for tc in toolCalls {
                                guard let index = tc["index"] as? Int else { continue }
                                let function = tc["function"] as? [String: Any]

                                if let id = tc["id"] as? String, let name = function?["name"] as? String {
                                    // Preserve any argument bytes that arrived before the
                                    // start frame for this index (some providers stream a
                                    // partial arguments delta ahead of the id/name frame).
                                    let existingArgs = toolCallAccumulators[index]?.arguments ?? ""
                                    toolCallAccumulators[index] = (id: id, name: name, arguments: existingArgs)
                                    continuation.yield(.toolCallStart(id: id, name: name))
                                }

                                if let argDelta = function?["arguments"] as? String {
                                    // Lazily create the accumulator if an argument delta
                                    // precedes the start frame, so early arg bytes aren't
                                    // silently dropped. The id is backfilled when the start
                                    // frame arrives above.
                                    if toolCallAccumulators[index] == nil {
                                        toolCallAccumulators[index] = (id: "", name: "", arguments: "")
                                    }
                                    toolCallAccumulators[index]?.arguments += argDelta
                                    if let id = toolCallAccumulators[index]?.id, !id.isEmpty {
                                        continuation.yield(.toolCallDelta(id: id, argumentsDelta: argDelta))
                                    }
                                }
                            }
                        }
                    }

                    let finalToolCalls: [ToolCall]? = toolCallAccumulators.isEmpty ? nil :
                        toolCallAccumulators.sorted(by: { $0.key < $1.key }).map { (_, acc) in
                            ToolCall(id: acc.id, type: "function", function: ToolCall.FunctionCall(name: acc.name, arguments: acc.arguments))
                        }

                    let rawMessage = ChatMessage(
                        role: "assistant",
                        content: accumulatedText.isEmpty ? nil : accumulatedText,
                        tool_calls: finalToolCalls
                    )
                    let response = LLMResponse(
                        text: accumulatedText.isEmpty ? nil : accumulatedText,
                        toolCalls: finalToolCalls,
                        rawMessage: rawMessage
                    )
                    APICallLog.shared.record(APICallLogEntry(
                        date: logStartedAt,
                        provider: provider.rawValue,
                        model: model,
                        streaming: true,
                        inputChars: logInputChars,
                        outputChars: accumulatedText.count,
                        promptTokens: nil,
                        completionTokens: nil,
                        durationMs: Int(Date().timeIntervalSince(logStartedAt) * 1000),
                        success: true,
                        error: nil
                    ))
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    APICallLog.shared.record(APICallLogEntry(
                        date: logStartedAt,
                        provider: provider.rawValue,
                        model: model,
                        streaming: true,
                        inputChars: logInputChars,
                        outputChars: 0,
                        promptTokens: nil,
                        completionTokens: nil,
                        durationMs: Int(Date().timeIntervalSince(logStartedAt) * 1000),
                        success: false,
                        error: (error as? MetamorphiaError)?.errorDescription ?? error.localizedDescription
                    ))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
