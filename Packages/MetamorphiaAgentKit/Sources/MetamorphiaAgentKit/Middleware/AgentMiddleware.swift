import Foundation

// MARK: - Middleware Protocol

/// A composable hook into the agent loop's execution cycle.
///
/// Middlewares run in registration order at three points per iteration:
///   1. **beforeModelCall** — inspect/modify messages and tools before the LLM sees them
///   2. **afterModelCall** — inspect the LLM response before tool execution begins
///   3. **afterToolExecution** — inspect tool results before the next iteration
///
/// Each hook returns a ``MiddlewareSignal`` that controls flow. Default implementations
/// return `.continue` so middlewares only override the hooks they care about.
public protocol AgentMiddleware: AnyObject, Sendable {
    /// Unique identifier for logging and keyed storage.
    var name: String { get }

    /// Runs before each LLM API call. Can modify messages/tools in the context.
    func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal

    /// Runs after each LLM response arrives, before tool execution.
    func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal

    /// Runs after all tool calls in an iteration complete.
    func afterToolExecution(_ ctx: MiddlewareContext, toolCalls: [ToolCall], results: [ToolResult]) -> MiddlewareSignal
}

// Defaults — middlewares only implement hooks they need.
public extension AgentMiddleware {
    func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal { .continue }
    func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal { .continue }
    func afterToolExecution(_ ctx: MiddlewareContext, toolCalls: [ToolCall], results: [ToolResult]) -> MiddlewareSignal { .continue }
}

// MARK: - Signal

/// What a middleware tells the chain to do after it runs.
public enum MiddlewareSignal: Sendable {
    /// Proceed normally.
    case `continue`
    /// Append these messages before the next LLM call (e.g., a loop-detection warning).
    case injectMessages([ChatMessage])
    /// Halt the agent loop immediately (e.g., runaway loop detected).
    case stop(reason: String)
}

// MARK: - Context

/// Shared mutable state passed through every middleware in an iteration.
///
/// Reference type so mutations are visible to all middlewares and the caller.
/// `@unchecked Sendable` because the storage dictionary holds `Any` values;
/// callers are responsible for keeping stored values thread-safe when accessed
/// across middleware invocations.
public final class MiddlewareContext: @unchecked Sendable {
    /// Full conversation history — middlewares may append (never remove).
    public var messages: [ChatMessage]
    /// Active tool schemas sent to the LLM — middlewares may expand.
    public var tools: [[String: AnyCodable]]
    /// Current iteration index (0-based).
    public let iteration: Int
    /// Maximum iterations for this task.
    public let maxIterations: Int
    /// Execution trace for observability.
    public let trace: AgentTrace?
    /// Original user command.
    public let command: String
    /// Keyed storage that persists across iterations within a single task execution.
    /// Middlewares store private state here using their `name` as key prefix.
    public var storage: [String: Any]

    public init(
        messages: [ChatMessage],
        tools: [[String: AnyCodable]],
        iteration: Int,
        maxIterations: Int,
        trace: AgentTrace?,
        command: String,
        storage: [String: Any] = [:]
    ) {
        self.messages = messages
        self.tools = tools
        self.iteration = iteration
        self.maxIterations = maxIterations
        self.trace = trace
        self.command = command
        self.storage = storage
    }
}

// MARK: - Chain

/// Runs an ordered list of middlewares, short-circuiting on `.stop`.
public final class MiddlewareChain: @unchecked Sendable {
    public private(set) var middlewares: [AgentMiddleware] = []

    /// Storage that persists across iterations for the lifetime of one task execution.
    /// Passed into each ``MiddlewareContext`` so middlewares can maintain state.
    public var persistentStorage: [String: Any] = [:]

    public init() {}

    public func add(_ middleware: AgentMiddleware) {
        middlewares.append(middleware)
    }

    /// Run all middlewares' beforeModelCall hooks in order.
    public func runBeforeModel(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        for mw in middlewares {
            let signal = mw.beforeModelCall(ctx)
            switch signal {
            case .continue:
                continue
            case .injectMessages(let msgs):
                ctx.messages.append(contentsOf: msgs)
            case .stop:
                print("[Middleware/\(mw.name)] Signalled stop before model call")
                return signal
            }
        }
        return .continue
    }

    /// Run all middlewares' afterModelCall hooks in order.
    public func runAfterModel(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal {
        for mw in middlewares {
            let signal = mw.afterModelCall(ctx, response: response)
            switch signal {
            case .continue:
                continue
            case .injectMessages(let msgs):
                ctx.messages.append(contentsOf: msgs)
            case .stop:
                print("[Middleware/\(mw.name)] Signalled stop after model call")
                return signal
            }
        }
        return .continue
    }

    /// Run all middlewares' afterToolExecution hooks in order.
    public func runAfterToolExecution(_ ctx: MiddlewareContext, toolCalls: [ToolCall], results: [ToolResult]) -> MiddlewareSignal {
        for mw in middlewares {
            let signal = mw.afterToolExecution(ctx, toolCalls: toolCalls, results: results)
            switch signal {
            case .continue:
                continue
            case .injectMessages(let msgs):
                ctx.messages.append(contentsOf: msgs)
            case .stop:
                print("[Middleware/\(mw.name)] Signalled stop after tool execution")
                return signal
            }
        }
        return .continue
    }

    /// Create a fresh context for this iteration, carrying forward persistent storage.
    public func makeContext(
        messages: [ChatMessage],
        tools: [[String: AnyCodable]],
        iteration: Int,
        maxIterations: Int,
        trace: AgentTrace?,
        command: String
    ) -> MiddlewareContext {
        MiddlewareContext(
            messages: messages,
            tools: tools,
            iteration: iteration,
            maxIterations: maxIterations,
            trace: trace,
            command: command,
            storage: persistentStorage
        )
    }

    /// Sync context storage back to persistent storage after each iteration.
    public func syncStorage(from ctx: MiddlewareContext) {
        persistentStorage = ctx.storage
    }

    /// Reset all state for a new task execution.
    public func reset() {
        persistentStorage.removeAll()
    }
}
