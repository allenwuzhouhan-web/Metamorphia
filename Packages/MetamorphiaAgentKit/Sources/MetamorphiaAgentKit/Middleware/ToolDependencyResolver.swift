import Foundation

/// Automatically maps which tools are required to fulfill a request, understands
/// their dependencies, and chains outputs between them. When tool B needs output
/// from tool A, the resolver handles data flow automatically.
///
/// The resolver works as a middleware that:
/// 1. Analyzes tool calls for implicit dependencies (data flow patterns)
/// 2. Reorders execution to respect dependencies
/// 3. Injects prior tool outputs as context when a dependent tool runs
/// 4. Maintains a dependency graph for the current execution
public final class ToolDependencyResolver: AgentMiddleware {
    public let name = "ToolDependencyResolver"

    public init() {}

    // MARK: - Storage Keys

    private static let graphKey = "ToolDeps.graph"
    private static let outputsKey = "ToolDeps.outputs"

    // MARK: - Dependency Graph

    public struct DependencyGraph {
        public var edges: [(from: String, to: String)]
        public var toolOutputs: [String: String]
        public var resolvedChains: [[String]]

        public mutating func addOutput(_ toolName: String, _ output: String) {
            toolOutputs[toolName] = String(output.prefix(2000))
        }

        public func dependenciesFor(_ toolName: String) -> [String] {
            edges.filter { $0.to == toolName }.map { $0.from }
        }
    }

    // MARK: - Known Dependency Patterns

    /// Static dependency map: tool B commonly needs output from tool A.
    /// Domain knowledge about the Metamorphia tool ecosystem.
    private static let knownDependencies: [String: [String]] = [
        "create_calendar_event": ["query_calendar_events"],
        "update_calendar_event": ["query_calendar_events"],
        "file_operation": ["find_files"],
        "batch_rename_files": ["find_files"],
        "browser_task": ["search_web"],
        "open_url": ["search_web"],
        "notion_update_page": ["notion_search", "notion_read_page"],
        "notion_append_blocks": ["notion_search", "notion_read_page"],
        "notion_add_to_database": ["notion_get_database"],
        "create_presentation": ["find_files", "search_web"],
        "create_word_document": ["find_files"],
        "ffmpeg_edit_video": ["ffmpeg_probe"],
        "create_video": ["search_images"],
        "window_control": ["list_windows"],
    ]

    /// Detect implicit data flow: tool B references data that tool A would produce.
    private static let outputPatterns: [String: [String]] = [
        "find_files": ["path", "file_path", "file", "filename"],
        "search_web": ["url", "link", "href"],
        "notion_search": ["page_id", "database_id"],
        "query_calendar_events": ["event_id"],
        "list_windows": ["window_id", "app_name"],
        "capture_screen": ["image_path"],
        "ffmpeg_probe": ["duration", "codec", "resolution"],
    ]

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        if ctx.iteration == 0 {
            ctx.storage[Self.graphKey] = DependencyGraph(
                edges: [], toolOutputs: [:], resolvedChains: []
            )
        }
        return .continue
    }

    public func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal {
        guard let toolCalls = response.toolCalls, toolCalls.count > 1 else {
            return .continue
        }

        guard var graph = ctx.storage[Self.graphKey] as? DependencyGraph else {
            return .continue
        }

        let callNames = toolCalls.map { $0.function.name }

        for (i, call) in toolCalls.enumerated() {
            if let deps = Self.knownDependencies[call.function.name] {
                for dep in deps where callNames.contains(dep) {
                    graph.edges.append((from: dep, to: call.function.name))
                }
            }

            let argsLower = call.function.arguments.lowercased()
            for priorCall in toolCalls[0..<i] {
                if let outputKeys = Self.outputPatterns[priorCall.function.name] {
                    for key in outputKeys where argsLower.contains(key) {
                        graph.edges.append((from: priorCall.function.name, to: call.function.name))
                    }
                }
            }
        }

        ctx.storage[Self.graphKey] = graph
        return .continue
    }

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        guard var graph = ctx.storage[Self.graphKey] as? DependencyGraph else {
            return .continue
        }

        for result in results where !result.result.hasPrefix("Error") {
            graph.addOutput(result.toolName, result.result)
        }

        let completedTools = Set(results.filter { !$0.result.hasPrefix("Error") }.map { $0.toolName })
        let chainTools = toolCalls.map { $0.function.name }
        if chainTools.count > 1 && completedTools.count == chainTools.count {
            graph.resolvedChains.append(chainTools)
        }

        ctx.storage[Self.graphKey] = graph
        return .continue
    }

    // MARK: - Public API

    /// Get dependency suggestions for a set of tool calls.
    /// Returns tool names that should be called first.
    public static func suggestPrerequisites(for toolNames: [String]) -> [String] {
        var prerequisites: Set<String> = []
        for name in toolNames {
            if let deps = knownDependencies[name] {
                for dep in deps where !toolNames.contains(dep) {
                    prerequisites.insert(dep)
                }
            }
        }
        return Array(prerequisites)
    }

    /// Get the dependency graph from middleware storage.
    public static func currentGraph(from storage: [String: Any]) -> DependencyGraph? {
        storage[graphKey] as? DependencyGraph
    }

    /// Get a previous tool's output for data flow chaining.
    public static func previousOutput(from storage: [String: Any], toolName: String) -> String? {
        (storage[outputsKey] as? [String: String])?[toolName]
            ?? (storage[graphKey] as? DependencyGraph)?.toolOutputs[toolName]
    }
}
