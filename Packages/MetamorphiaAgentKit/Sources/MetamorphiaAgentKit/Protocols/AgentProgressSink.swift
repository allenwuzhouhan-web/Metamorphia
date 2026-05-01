import Foundation

/// A sink for progress events emitted by the agent loop and its middleware.
///
/// Replaces direct `NotificationCenter.default.post(name: .agentProgressUpdate, ...)`
/// from Executer. The app target injects a concrete sink (e.g., an `AICommandViewModel`
/// that is also an `ObservableObject`) when constructing the agent loop.
///
/// Implementations should be thread-safe — events may arrive from detached Tasks.
public protocol AgentProgressSink: AnyObject, Sendable {
    func publish(_ event: AgentProgressEvent)
}

/// A single progress event from the agent loop.
///
/// Modelled after `StreamingProgressMiddleware.ProgressEvent` but
/// decoupled from `NotificationCenter` and any UI concerns.
public struct AgentProgressEvent: Sendable {
    public let timestamp: Date
    public let kind: Kind
    public let message: String
    public let detail: String?
    /// 0.0...1.0 when known; `nil` for events that don't carry a fraction.
    public let progress: Double?

    public enum Kind: Sendable, Equatable {
        case started
        case toolStarted(name: String)
        case toolCompleted(name: String, success: Bool)
        case thinking
        case milestone(step: Int, total: Int)
        case completed
        case cancelled
        case error
        /// Cost budget was exceeded — payload is the dollar amount consumed so far.
        case costBudgetExceeded(spent: Double)
        /// A short, mutating status label displayable verbatim in the UI.
        /// Kept ≤32 chars so a single line of the notch can hold it without
        /// truncation. Replaces the static "Thinking…" string.
        case status(label: String)
        /// A single streaming text chunk from the LLM response.
        case streamingToken(String)
    }

    public init(
        timestamp: Date = Date(),
        kind: Kind,
        message: String,
        detail: String? = nil,
        progress: Double? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.detail = detail
        self.progress = progress
    }
}

/// A no-op sink for tests and contexts where progress events are ignored.
public final class NullProgressSink: AgentProgressSink, @unchecked Sendable {
    public init() {}
    public func publish(_ event: AgentProgressEvent) { /* intentionally empty */ }
}
