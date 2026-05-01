import Foundation

/// Argument-aware safety inspector that can override a tool's static risk tier
/// based on the specific arguments being passed.
///
/// The gate consults registered inspectors *before* the static tier lookup.
/// Any inspector returning a non-nil `ToolRiskTier` wins — the first-matching
/// inspector's decision is used. This is how, for example, a click on an
/// element labeled "Delete Account" can be auto-escalated to `.critical`
/// (forcing a user prompt) even though the underlying `click_element` tool
/// would otherwise be categorized as `.elevated`.
///
/// Phase 3 introduces `PerceptionSafetyInspector` in the main Metamorphia app
/// target as the first real implementation; it parses `ref` parameters from
/// gesture tools and resolves them via `DefaultComputerPerception.shared`.
public protocol ToolArgumentSafetyInspector: Sendable {
    /// Inspect a pending tool invocation. Return `nil` to defer to the static
    /// tier table; return a `ToolRiskTier` to override it.
    ///
    /// - Parameter toolName: The fully-qualified registered tool name (e.g.
    ///   `click_element`, `mcp__notion__notion-create-comment`).
    /// - Parameter arguments: The raw JSON argument string as supplied by the
    ///   LLM. Inspectors are expected to tolerate malformed JSON gracefully.
    func inspect(toolName: String, arguments: String) async -> ToolRiskTier?
}
