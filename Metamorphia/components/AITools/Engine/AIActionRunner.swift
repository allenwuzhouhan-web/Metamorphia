import Foundation
import MetamorphiaAgentKit

/// Errors surfaced by ``AIActionRunner`` when a transform cannot run or produces
/// nothing usable. These are readable enough to show directly to the user.
public enum AIActionError: LocalizedError {
    /// The input to transform was empty or only whitespace.
    case emptyInput
    /// The LLM completed but returned no text (e.g. an empty/filtered response).
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "There is no text to work with."
        case .emptyResult:
            return "The model did not return any text. Please try again."
        }
    }
}

/// Runs an ``AIAction`` against the app's configured LLM service as a single,
/// focused chat completion — no agent loop and no tools. Used by Writing Tools,
/// Summarize Anything, and Smart Reply.
public enum AIActionRunner {
    /// Upper bound on generated tokens. Generous enough for full rewrites of a
    /// reasonable selection while keeping latency and cost bounded.
    private static let maxTokens = 2048

    /// Streams the transformed text incrementally as the model produces it.
    ///
    /// - Parameters:
    ///   - action: The transformation to apply.
    ///   - input: The user's text (the selection to rewrite, the block to
    ///     summarize, or — for `.smartReply` — the message to reply to).
    ///   - context: Optional extra information appended to the request, such as
    ///     surrounding on-screen text for `.smartReply`.
    /// - Returns: A stream that yields partial text chunks and finishes when the
    ///   model is done. The stream finishes with an error if the input is empty
    ///   or the LLM call fails.
    public static func stream(
        action: AIAction,
        input: String,
        context: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continuation.finish(throwing: AIActionError.emptyInput)
                return
            }

            let messages = buildMessages(action: action, input: input, context: context)
            let service = LLMServiceManager.shared.currentService

            let task = Task {
                do {
                    let events = service.streamChatRequest(
                        messages: messages,
                        tools: nil,
                        maxTokens: maxTokens
                    )
                    for try await event in events {
                        switch event {
                        case .textDelta(let delta):
                            if !delta.isEmpty {
                                continuation.yield(delta)
                            }
                        case .done:
                            // Terminal event: text already streamed via deltas.
                            continuation.finish()
                            return
                        case .toolCallStart, .toolCallDelta, .toolCallComplete:
                            // No tools are offered for these transforms; ignore.
                            continue
                        }
                    }
                    // Stream ended without an explicit `.done` event.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Convenience one-shot wrapper that awaits the full transformed result by
    /// accumulating the stream.
    ///
    /// - Throws: ``AIActionError/emptyInput`` or ``AIActionError/emptyResult`` for
    ///   empty input/output, or the underlying LLM error on failure.
    public static func run(
        action: AIAction,
        input: String,
        context: String?
    ) async throws -> String {
        var accumulated = ""
        for try await chunk in stream(action: action, input: input, context: context) {
            accumulated += chunk
        }
        let result = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw AIActionError.emptyResult
        }
        return result
    }

    // MARK: - Message Construction

    /// Builds the `[system, user]` message array for an action. The optional
    /// context is attached to the user message so the model treats the input as
    /// the primary subject and the context as supporting reference material.
    private static func buildMessages(
        action: AIAction,
        input: String,
        context: String?
    ) -> [ChatMessage] {
        let userContent: String
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch action {
            case .smartReply:
                userContent = """
                Message to reply to:
                \(input)

                Additional context (for reference only — do not reply to it directly):
                \(context)
                """
            default:
                userContent = """
                Text:
                \(input)

                Additional context (for reference only):
                \(context)
                """
            }
        } else {
            userContent = input
        }

        return [
            ChatMessage(role: "system", content: action.systemPrompt),
            ChatMessage(role: "user", content: userContent)
        ]
    }
}
