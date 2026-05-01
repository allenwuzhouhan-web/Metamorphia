import XCTest
@testable import MetamorphiaAgentKit

final class MiddlewareChainTests: XCTestCase {

    // A recording middleware that appends its name to a shared buffer on each hook.
    final class RecordingMiddleware: AgentMiddleware, @unchecked Sendable {
        let name: String
        var calls: [String] = []

        init(name: String) { self.name = name }

        func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
            calls.append("\(name).before")
            return .continue
        }

        func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal {
            calls.append("\(name).afterModel")
            return .continue
        }

        func afterToolExecution(_ ctx: MiddlewareContext, toolCalls: [ToolCall], results: [ToolResult]) -> MiddlewareSignal {
            calls.append("\(name).afterTools")
            return .continue
        }
    }

    // Middleware that injects a message via the signal.
    final class InjectingMiddleware: AgentMiddleware, @unchecked Sendable {
        let name = "Injector"

        func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
            .injectMessages([ChatMessage(role: "system", content: "Injected note.")])
        }
    }

    // Middleware that halts the chain on afterModel.
    final class HaltingMiddleware: AgentMiddleware, @unchecked Sendable {
        let name = "Halter"

        func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal {
            .stop(reason: "runaway loop")
        }
    }

    private func makeCtx(chain: MiddlewareChain) -> MiddlewareContext {
        chain.makeContext(
            messages: [ChatMessage(role: "user", content: "hi")],
            tools: [],
            iteration: 0,
            maxIterations: 10,
            trace: nil,
            command: "hi"
        )
    }

    private func makeResponse() -> LLMResponse {
        LLMResponse(
            text: "hello",
            toolCalls: nil,
            rawMessage: ChatMessage(role: "assistant", content: "hello")
        )
    }

    func testMiddlewaresRunInRegistrationOrder() {
        let chain = MiddlewareChain()
        let a = RecordingMiddleware(name: "A")
        let b = RecordingMiddleware(name: "B")
        chain.add(a)
        chain.add(b)

        let ctx = makeCtx(chain: chain)
        _ = chain.runBeforeModel(ctx)
        _ = chain.runAfterModel(ctx, response: makeResponse())
        _ = chain.runAfterToolExecution(ctx, toolCalls: [], results: [])

        XCTAssertEqual(a.calls, ["A.before", "A.afterModel", "A.afterTools"])
        XCTAssertEqual(b.calls, ["B.before", "B.afterModel", "B.afterTools"])
    }

    func testInjectMessagesAppendsToContext() {
        let chain = MiddlewareChain()
        chain.add(InjectingMiddleware())

        let ctx = makeCtx(chain: chain)
        XCTAssertEqual(ctx.messages.count, 1)

        _ = chain.runBeforeModel(ctx)

        XCTAssertEqual(ctx.messages.count, 2)
        XCTAssertEqual(ctx.messages.last?.role, "system")
        XCTAssertEqual(ctx.messages.last?.content, "Injected note.")
    }

    func testStopSignalShortCircuitsChain() {
        let chain = MiddlewareChain()
        let before = RecordingMiddleware(name: "Before")
        let after = RecordingMiddleware(name: "After")
        chain.add(before)
        chain.add(HaltingMiddleware())
        chain.add(after)

        let ctx = makeCtx(chain: chain)
        let signal = chain.runAfterModel(ctx, response: makeResponse())

        // Halter fired between Before and After — After should not have been called.
        XCTAssertEqual(before.calls, ["Before.afterModel"])
        XCTAssertEqual(after.calls, [])

        guard case .stop(let reason) = signal else {
            XCTFail("expected .stop signal, got \(signal)")
            return
        }
        XCTAssertEqual(reason, "runaway loop")
    }

    func testPersistentStorageCarriesAcrossContexts() {
        let chain = MiddlewareChain()
        let ctx1 = chain.makeContext(
            messages: [], tools: [], iteration: 0, maxIterations: 10, trace: nil, command: "t"
        )
        ctx1.storage["counter"] = 1
        chain.syncStorage(from: ctx1)

        let ctx2 = chain.makeContext(
            messages: [], tools: [], iteration: 1, maxIterations: 10, trace: nil, command: "t"
        )
        XCTAssertEqual(ctx2.storage["counter"] as? Int, 1)

        chain.reset()
        let ctx3 = chain.makeContext(
            messages: [], tools: [], iteration: 0, maxIterations: 10, trace: nil, command: "t"
        )
        XCTAssertNil(ctx3.storage["counter"])
    }

    func testAgentTraceAppendIsThreadSafe() async {
        let trace = AgentTrace(goal: "concurrent appends")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    trace.append(TraceEntry(kind: .toolCall(
                        name: "tool\(i)", arguments: "", result: "", durationMs: 0, success: true
                    )))
                }
            }
        }
        XCTAssertEqual(trace.entries.count, 100)
    }

    func testTraceRedactorMasksApiKeys() {
        let input = "here is my key: sk-abcdef1234567890abcdef1234 and a Bearer xyz1234567890abcdefghij token"
        let out = TraceRedactor.redact(input)
        XCTAssertFalse(out.contains("abcdef1234567890abcdef1234"))
        XCTAssertTrue(out.contains("[REDACTED]"))
    }

    func testToolDefinitionArgumentParsing() throws {
        struct DemoTool: ToolDefinition {
            let name = "demo"
            let description = "demo tool"
            let parameters: [String: Any] = [:]
            func execute(arguments: String) async throws -> String { "" }
        }

        let tool = DemoTool()
        let args = try tool.parseArguments(#"{"path": "/tmp/x", "count": 3, "keep": true}"#)
        XCTAssertEqual(try tool.requiredString("path", from: args), "/tmp/x")
        XCTAssertEqual(tool.optionalInt("count", from: args), 3)
        XCTAssertEqual(tool.optionalBool("keep", from: args), true)
        XCTAssertNil(tool.optionalString("missing", from: args))
    }
}
