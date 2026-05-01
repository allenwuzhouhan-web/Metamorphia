import Foundation

/// A concrete event enum the agent loop publishes so the app's UI state enum
/// (e.g., Executer's `InputBarState`) can be updated without the package
/// knowing about that enum.
///
/// The app target supplies a concrete ``AgentDisplayStateSink`` that maps
/// each event to its own `InputBarState` case. Cleaner than a protocol with
/// static requirements because Swift doesn't allow calling `.result(x)` on
/// a protocol metatype.
public enum AgentDisplayEvent: Sendable {
    /// Idle / ready-for-input. Emitted on submission start and after reset.
    case ready

    /// Model is thinking (no tool calls yet this iteration).
    case processing

    /// Model is streaming partial text content.
    case streaming(String)

    /// A tool is currently executing.
    case executing(toolName: String, step: Int, total: Int)

    /// Terminal success with a final message.
    case result(String)

    /// Terminal failure with an error message.
    case error(String)

    /// Run was cancelled by the user or a fresh submission.
    case cancelled
}

/// The app target implements this to translate agent events into its own
/// UI state enum (e.g., `InputBarState`). `async` because impls typically
/// hop `@MainActor` to mutate observable state.
public protocol AgentDisplayStateSink: AnyObject, Sendable {
    func emit(_ event: AgentDisplayEvent) async
}

/// A null sink that drops every event. Useful for tests and headless runs.
public final class NullAgentDisplayStateSink: AgentDisplayStateSink, @unchecked Sendable {
    public init() {}
    public func emit(_ event: AgentDisplayEvent) async {}
}
