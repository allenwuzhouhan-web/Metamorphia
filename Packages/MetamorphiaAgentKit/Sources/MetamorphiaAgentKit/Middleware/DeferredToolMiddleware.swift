import Foundation

/// Injects a compact list of deferred (not-yet-loaded) tool names into the conversation
/// so the LLM knows they exist. When the LLM calls `search_tools`, matching deferred
/// tools are promoted to active and their full schemas appear in subsequent iterations.
///
/// This solves the "too many tools" problem: instead of binding 200+ tool schemas to
/// every LLM call (~60K tokens), we send only the relevant ~40 plus a one-line manifest
/// of everything else. The LLM can pull in what it needs on demand.
///
/// All registry interactions go through the injected ``ToolCatalog`` protocol rather
/// than `ToolRegistry.shared` directly, keeping the package AppKit-free.
public final class DeferredToolMiddleware: AgentMiddleware {
    public let name = "DeferredTools"

    private let catalog: ToolCatalog

    public init(catalog: ToolCatalog) {
        self.catalog = catalog
    }

    private static let injectedKey = "DeferredTools.injected"

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        let alreadyInjected = ctx.storage[Self.injectedKey] as? Bool ?? false
        guard !alreadyInjected, ctx.iteration == 0 else { return .continue }

        let deferred = catalog.deferredToolSummaries()
        guard !deferred.isEmpty else { return .continue }

        var manifest = "\n[Available additional tools — call `search_tools` with a keyword to load any of these]\n"
        for item in deferred {
            manifest += "• \(item.name): \(item.description)\n"
        }

        if let firstIdx = ctx.messages.indices.first, ctx.messages[firstIdx].role == "system" {
            let current = ctx.messages[firstIdx].content ?? ""
            ctx.messages[firstIdx] = ChatMessage(
                role: "system",
                content: current + manifest
            )
        }

        ctx.storage[Self.injectedKey] = true
        print("[Middleware/DeferredTools] Injected manifest of \(deferred.count) deferred tools")
        return .continue
    }

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        for call in toolCalls where call.function.name == "search_tools" {
            guard let result = results.first(where: { $0.toolCallId == call.id }) else { continue }
            if result.result.contains("Loaded tools:") || result.result.contains("Available tools matching") {
                refreshPromotedTools(in: ctx)
            }
        }

        // Legacy support for request_tools (older Executer builds).
        for call in toolCalls where call.function.name == "request_tools" {
            guard let result = results.first(where: { $0.toolCallId == call.id }) else { continue }
            if result.result.contains("Available tools matching") {
                refreshPromotedTools(in: ctx)
            }
        }

        return .continue
    }

    /// Pull any newly-promoted tools from the catalog into the context's active tool set.
    /// Also rewrites the deferred-tool manifest in the system prompt so the LLM's view
    /// of "what's still deferred" stays in sync.
    private func refreshPromotedTools(in ctx: MiddlewareContext) {
        let currentNames = Set(ctx.tools.compactMap { schema -> String? in
            guard let fn = schema["function"]?.value as? [String: AnyCodable],
                  let name = fn["name"]?.value as? String else { return nil }
            return name
        })

        let allActive = catalog.activeToolNames()
        var added = 0
        for toolName in allActive where !currentNames.contains(toolName) {
            if let schemaArray = catalog.singleToolSchema(toolName),
               let schema = schemaArray.first {
                ctx.tools.append(schema)
                added += 1
            }
        }

        rebuildManifest(in: ctx)

        if added > 0 {
            print("[Middleware/DeferredTools] Promoted \(added) tools to active set")
        }
    }

    /// Replace the previously-injected deferred-tool manifest (if any) with a
    /// fresh copy reflecting the current catalog state.
    private func rebuildManifest(in ctx: MiddlewareContext) {
        guard let firstIdx = ctx.messages.indices.first,
              ctx.messages[firstIdx].role == "system",
              let current = ctx.messages[firstIdx].content else { return }

        let sentinel = "\n[Available additional tools"
        let base: String
        if let range = current.range(of: sentinel) {
            base = String(current[..<range.lowerBound])
        } else {
            base = current
        }

        let deferred = catalog.deferredToolSummaries()
        var newContent = base
        if !deferred.isEmpty {
            var manifest = "\n[Available additional tools — call `search_tools` with a keyword to load any of these]\n"
            for item in deferred {
                manifest += "• \(item.name): \(item.description)\n"
            }
            newContent += manifest
        }

        ctx.messages[firstIdx] = ChatMessage(role: "system", content: newContent)
    }
}

// MARK: - SearchToolsTool

/// Replaces the basic `request_tools` with a smarter search that also promotes deferred tools.
/// Searches both active and deferred tools by name and description keywords.
/// Matching deferred tools are automatically promoted to active so the LLM can call them.
public struct SearchToolsTool: ToolDefinition {
    public let name = "search_tools"
    public let description = "Search for and load additional tools. Use when you need a capability not in your current tool set. Describe what you need and matching tools will be loaded automatically."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "What capability you need (e.g., 'send email', 'edit video', 'notion database'). Can also be an exact tool name."),
        ], required: ["query"])
    }

    private let catalog: ToolCatalog

    public init(catalog: ToolCatalog) {
        self.catalog = catalog
    }

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args).lowercased()

        let deferredMatches = catalog.searchDeferredTools(query: query)

        if !deferredMatches.isEmpty {
            let names = Set(deferredMatches.map(\.name))
            catalog.promoteDeferred(names: names)
        }

        let activeMatches = catalog.searchActiveTools(query: query)

        var allMatches: [(name: String, description: String, wasDeferred: Bool)] = []
        var seen = Set<String>()

        for match in deferredMatches {
            if seen.insert(match.name).inserted {
                allMatches.append((match.name, match.description, true))
            }
        }
        for match in activeMatches {
            if seen.insert(match.name).inserted {
                allMatches.append((match.name, match.description, false))
            }
        }

        guard !allMatches.isEmpty else {
            return "No tools found matching '\(query)'. Try a different keyword."
        }

        var result = ""
        let promoted = allMatches.filter(\.wasDeferred)
        if !promoted.isEmpty {
            result += "Loaded tools:\n"
            for m in promoted.prefix(15) {
                result += "• **\(m.name)**: \(m.description)\n"
            }
            result += "\n"
        }

        let existing = allMatches.filter { !$0.wasDeferred }
        if !existing.isEmpty {
            result += "Already available:\n"
            for m in existing.prefix(10) {
                result += "• **\(m.name)**: \(m.description)\n"
            }
        }

        result += "\nYou can now call any of these tools directly."
        return result
    }
}

// MARK: - UndoLastActionTool

/// LLM-callable tool that undoes the last reversible action.
/// Invokes the inverse action via the injected ``ToolCatalog``.
public struct UndoLastActionTool: ToolDefinition {
    public let name = "undo_last_action"
    public let description = "Undo the last reversible action performed in this session. Shows what can be undone and executes the inverse operation. Use when the user wants to revert a recent change."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "confirm": JSONSchema.boolean(description: "Set to true to execute the undo. If false, just shows what would be undone."),
        ], required: [])
    }

    public var storageProvider: (@Sendable () -> [String: Any])?
    private let catalog: ToolCatalog

    public init(catalog: ToolCatalog, storageProvider: (@Sendable () -> [String: Any])? = nil) {
        self.catalog = catalog
        self.storageProvider = storageProvider
    }

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let confirm = optionalBool("confirm", from: args) ?? false

        guard let storage = storageProvider?() else {
            return "No undo history available."
        }

        guard let lastAction = ConversationBranchManager.lastUndoableAction(from: storage) else {
            let stack = ConversationBranchManager.undoStack(from: storage)
            if stack.isEmpty {
                return "No actions have been performed yet."
            }
            let recent = stack.suffix(5).map { "- \($0.toolName): \(String($0.result.prefix(80)))" }
            return "Recent actions (none directly reversible):\n\(recent.joined(separator: "\n"))"
        }

        guard let inverse = lastAction.inverseAction else {
            return "Last action (\(lastAction.toolName)) is not reversible."
        }

        if !confirm {
            return "Can undo: \(inverse.description)\nOriginal action: \(lastAction.toolName)\nCall undo_last_action with confirm=true to execute."
        }

        let result = try await catalog.execute(
            toolName: inverse.toolName,
            arguments: inverse.arguments
        )
        return "Undone: \(inverse.description)\nResult: \(result)"
    }
}
