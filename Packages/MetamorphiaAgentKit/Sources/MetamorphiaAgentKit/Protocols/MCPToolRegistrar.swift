import Foundation

/// Facade the app target provides so `MCPServerManager` can publish discovered
/// MCP tools without importing `ToolRegistry` directly.
///
/// Executer's original implementation called `ToolRegistry.shared.registerMCPTools(...)`
/// inside `@MainActor.run { ... }` blocks. The package now invokes this protocol
/// asynchronously and the app's concrete registrar decides where to hop main.
public protocol MCPToolRegistrar: AnyObject, Sendable {
    /// Register newly-discovered MCP tools with the app's tool registry.
    func registerMCPTools(_ tools: [MCPToolWrapper]) async

    /// Remove all tools whose name starts with `"mcp__<name>__"`.
    func unregisterMCPTools(forServer name: String) async
}

/// A registrar that drops every registration/unregistration on the floor. Useful
/// for tests and headless contexts.
public final class NullMCPToolRegistrar: MCPToolRegistrar, @unchecked Sendable {
    public init() {}
    public func registerMCPTools(_ tools: [MCPToolWrapper]) async {}
    public func unregisterMCPTools(forServer name: String) async {}
}
