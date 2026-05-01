import Foundation

/// Root module marker for MetamorphiaAgentKit.
///
/// MetamorphiaAgentKit is a pure-Swift package (no AppKit, SwiftUI, UIKit) that hosts the
/// agent loop, middleware chain, tool registry, LLM services, and MCP client.
/// The Metamorphia app target and the `MetamorphiaExecutors` framework depend on it.
///
/// Sever-point protocols live in `Protocols/`:
/// - ``AgentProgressSink`` — replaces `NotificationCenter.default.post(name: .agentProgressUpdate, ...)`
/// - ``SystemContextProvider`` — replaces direct `NSWorkspace.shared.frontmostApplication` reads
/// - ``AgentDisplayState`` — lets the app's UI state enum be used by the agent loop without being moved
///
/// This file is intentionally minimal; it exists so `swift build` has a non-empty
/// compilation unit while the extraction of AgentLoop / MiddlewareChain / tool registry
/// lands in subsequent phases.
public enum MetamorphiaAgentKit {
    /// Package semantic version. Bumped when the public protocol surface changes.
    public static let version = "0.1.0"
}
