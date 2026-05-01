import Foundation

// MARK: - Streaming Event

public enum StreamEvent: Sendable {
    case textDelta(String)
    case toolCallStart(id: String, name: String)
    case toolCallDelta(id: String, argumentsDelta: String)
    case toolCallComplete(ToolCall)
    case done(LLMResponse)
}

// MARK: - Service Protocol

/// Abstract interface that every LLM transport (Claude, OpenAI-compatible, Ollama, etc.)
/// conforms to. The agent loop and middleware chain only see this protocol — swapping
/// providers is a matter of constructing a different conforming instance.
public protocol LLMServiceProtocol: Sendable {
    func sendChatRequest(
        messages: [ChatMessage],
        tools: [[String: AnyCodable]]?,
        maxTokens: Int
    ) async throws -> LLMResponse

    func streamChatRequest(
        messages: [ChatMessage],
        tools: [[String: AnyCodable]]?,
        maxTokens: Int
    ) -> AsyncThrowingStream<StreamEvent, Error>
}

public extension LLMServiceProtocol {
    /// Default streaming shim for providers that only implement `sendChatRequest`.
    /// Emits one `textDelta` and a terminal `done` event from the non-streaming response.
    func streamChatRequest(
        messages: [ChatMessage],
        tools: [[String: AnyCodable]]?,
        maxTokens: Int
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.sendChatRequest(
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens
                    )
                    if let text = response.text {
                        continuation.yield(.textDelta(text))
                    }
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Cost Tracker Protocol

/// Optional hook for recording token usage per LLM call. The app target wires
/// a concrete implementation (backed by a cost-budget counter) at service-
/// manager construction time; when `nil`, services skip cost tracking.
public protocol LLMCostTracker: AnyObject, Sendable {
    func record(provider: String, inputTokens: Int, outputTokens: Int, agentId: String?)
    /// Currently-active agent id used for cost attribution. May return `nil`.
    var activeAgentId: String? { get }
}

/// Read-only view of the cost tracker used by ``AgentLoop`` to enforce
/// per-task cost ceilings. Kept separate from ``LLMCostTracker`` so the loop
/// doesn't need write access — it just samples a cumulative USD figure.
///
/// The concrete ``CostTracker`` in MetamorphiaAgentKit already conforms by exposing
/// `currentDailyCostUSD`; the shim below adapts that property name to the
/// protocol's `currentSpendUSD`.
public protocol AgentLoopCostReader: AnyObject, Sendable {
    /// Monotonically non-decreasing cumulative spend in USD. The loop diffs
    /// this against a snapshot captured at task start to determine per-task
    /// spend.
    var currentSpendUSD: Double { get }
}
