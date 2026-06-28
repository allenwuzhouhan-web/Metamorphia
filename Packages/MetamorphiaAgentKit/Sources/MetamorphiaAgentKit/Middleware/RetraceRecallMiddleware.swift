import Foundation

/// Injects a pre-fetched temporal-recall block ("what you were doing before")
/// into the system message on iteration 0 only.
///
/// QueryRank is async but `beforeModelCall` is synchronous, so the recall block
/// is fetched ahead of time by the host (see AICommandViewModel.submit) and
/// stashed in `MiddlewareChain.persistentStorage` under `Self.recallBlockKey`.
/// This middleware only *reads* that string — it never blocks the loop.
///
/// The `recall` closure is retained for hosts that want the middleware to own
/// the fetch in future; the default is a null closure for tests. The sync hook
/// does not call it.
public final class RetraceRecallMiddleware: AgentMiddleware, @unchecked Sendable {
    public let name = "RetraceRecall"

    /// Storage key the host writes the pre-fetched, pre-formatted recall block to.
    /// Public so the app target's pre-fetch can populate it without guessing.
    public static let recallBlockKey = "RetraceRecall.block"
    /// Storage key the host sets to `true` when the focused field is sensitive,
    /// so the middleware suppresses injection even if a block leaked through.
    public static let suppressKey = "RetraceRecall.suppress"

    private static let injectedKey = "RetraceRecall.injected"

    private let recall: @Sendable (String) async -> String?

    public init(recall: @escaping @Sendable (String) async -> String? = { _ in nil }) {
        self.recall = recall
    }

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        // Iteration-0 only — mirrors ImplicitContextMiddleware's gate.
        let alreadyInjected = ctx.storage[Self.injectedKey] as? Bool ?? false
        guard !alreadyInjected else { return .continue }
        ctx.storage[Self.injectedKey] = true

        // Privacy: hard-suppress when a sensitive field is focused.
        if ctx.storage[Self.suppressKey] as? Bool == true { return .continue }

        guard let block = ctx.storage[Self.recallBlockKey] as? String,
              !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .continue }

        // Token discipline — cap defensively (~80 tokens ≈ 360 chars).
        let capped = String(block.prefix(360))

        let section = "## Earlier context (temporal recall)\n" +
                      "(May or may not be relevant.)\n" + capped

        if let sysIdx = ctx.messages.firstIndex(where: { $0.role == "system" }),
           let existing = ctx.messages[sysIdx].content {
            ctx.messages[sysIdx] = ChatMessage(role: "system", content: existing + "\n\n" + section)
        }
        return .continue
    }
}
