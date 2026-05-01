import Foundation

/// Risk tier for a single tool — decides which permission gate it must pass.
///
/// Ordering:
/// - `.safe` — no side effects (read-only queries, pure computation).
/// - `.elevated` — writes to user state (file ops, app launches, clipboard writes).
/// - `.critical` — destructive or credential-sensitive (delete, shell exec, secrets).
public enum ToolRiskTier: String, Sendable, Codable {
    case safe
    case elevated
    case critical
}

/// The outcome of a permission check. `.deny` carries a human-readable reason
/// that is surfaced to the LLM as the tool result so the agent can re-plan.
public enum ToolPermissionDecision: Sendable {
    case allow
    case deny(reason: String)
}

/// Optional facade the app target supplies so the package can register risk tiers
/// for discovered tools (primarily MCP tools whose names are known at runtime)
/// and gate each tool call before dispatch.
///
/// Two roles:
/// 1. **Tier registration.** `register(toolName:tier:)` lets the registry tell the
///    gate about a new tool (used mainly for MCP tools whose names are discovered
///    at runtime). The gate persists the mapping into its policy store.
/// 2. **Pre-call gating.** `checkPermission(toolName:arguments:)` is called by
///    ``ToolRegistry.execute`` before every tool dispatch. The concrete gate
///    decides whether to allow, deny, or prompt the user. For backward compat
///    with existing callers, a default implementation returns `.allow` for every
///    call — so a gate that only wants to record tiers doesn't need to opt into
///    gating.
///
/// If `nil` is passed to ``ToolRegistry``, safety gating is skipped entirely.
public protocol ToolSafetyGate: AnyObject, Sendable {
    func register(toolName: String, tier: ToolRiskTier)

    /// Check whether the given tool call should be allowed. Called once per
    /// tool invocation, before the tool runs. The gate may block inline (e.g.,
    /// to prompt the user via an `NSAlert`); the call is `async` so the gate
    /// can suspend while awaiting a UI decision.
    func checkPermission(toolName: String, arguments: String) async -> ToolPermissionDecision
}

public extension ToolSafetyGate {
    /// Default: permit every call. Gates that only record tier metadata (e.g.,
    /// the built-in ``NullToolSafetyGate``) get this for free — existing tests
    /// and callers that don't supply `checkPermission` continue to work.
    func checkPermission(toolName: String, arguments: String) async -> ToolPermissionDecision {
        .allow
    }
}

/// A null gate that records nothing and allows everything. Used in tests and
/// when the caller has decided all tools are trusted (e.g., a fully scripted
/// CI environment).
public final class NullToolSafetyGate: ToolSafetyGate, @unchecked Sendable {
    public init() {}
    public func register(toolName: String, tier: ToolRiskTier) {}
}
