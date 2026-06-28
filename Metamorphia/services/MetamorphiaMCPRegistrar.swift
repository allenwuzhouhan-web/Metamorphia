import Foundation
import MetamorphiaAgentKit

/// Concrete `MCPToolRegistrar` that bridges MCP-discovered tools into the
/// app's shared `ToolRegistry`. `MCPServerManager` (the package actor) holds
/// this via the protocol; the app owns the registry instance so there is
/// exactly one write path to MCP registrations.
///
/// Tools land as DEFERRED on registration (tier inferred by `ToolRegistry`).
/// The user can promote them via the Capabilities view or the `search_tools`
/// agent command.
final class MetamorphiaMCPRegistrar: MCPToolRegistrar, @unchecked Sendable {

    private let registry: ToolRegistry

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    func registerMCPTools(_ tools: [MCPToolWrapper]) async {
        registry.registerMCPTools(tools)
    }

    func unregisterMCPTools(forServer name: String) async {
        registry.unregisterMCPTools(forServer: name)
    }
}
