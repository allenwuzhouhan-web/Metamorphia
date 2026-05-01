import Foundation

/// Optional fast-path for answering status queries without running the full agent loop.
///
/// Executer's `DirectResponseHandler` reads `NSWorkspace.shared.frontmostApplication`,
/// runs AppleScript (`output volume of (get volume settings)`), shells out to
/// `pmset -g batt`, queries the Focus state service, etc. All of that is impure and
/// app-target-specific, so `MetamorphiaAgentKit` sees only this protocol.
///
/// The app target wires up a concrete handler that knows about `SystemContext`,
/// `AppleScriptRunner`, and `FocusStateService`. Returning `nil` from `handle(...)`
/// means "no fast-path match — run the agent loop."
public protocol DirectResponseProvider: Sendable {
    func handle(category: String, command: String) async -> String?
}

/// A provider that never intercepts — all queries fall through to the agent loop.
public struct NullDirectResponseProvider: DirectResponseProvider {
    public init() {}
    public func handle(category: String, command: String) async -> String? { nil }
}
