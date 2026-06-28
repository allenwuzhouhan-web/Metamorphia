import AppKit
import AppIntents
import Foundation
#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

/// Shared entrypoint for agent runs fired from AppIntents / Services menu.
/// Uses `AICommandViewModel.submit` when the command bar is idle so the run
/// is visible in the notch; falls back to a headless `AgentLoop.submit` if
/// the view model isn't reachable (early-launch, stub build, or VM busy
/// with a user-initiated turn we don't want to clobber).
@MainActor
enum MetamorphiaIntentEngine {

    static let defaultSystemPrompt = """
    You are Metamorphia, a macOS-native AI assistant embedded in the notch. \
    Respond concisely — 1–3 short paragraphs unless the task demands more. \
    When analyzing files, prefer direct observation via available tools over \
    guessing from the filename. Do not answer time-sensitive facts from \
    memory; for current/latest/recent/today/now facts, live office holders, \
    prices, schedules, news, laws, or other changing facts, call `search_web` \
    first when available. If a live-data tool is unavailable, say you cannot \
    verify the current answer instead of guessing.
    """

    /// Fire an agent run and return the final text. If `showNotch` is true,
    /// the command bar is summoned so the user sees the turn stream live.
    /// `sessionID` — when non-nil, threads the phone's CloudKit session id
    /// into the run so interim + final TurnResult writes correlate to one
    /// thread. Nil for local/AppIntent-originated turns.
    static func run(
        prompt: String,
        systemPrompt: String = defaultSystemPrompt,
        sessionID: String? = nil,
        showNotch: Bool = true
    ) async -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

#if canImport(MetamorphiaAgentKit)
        let vm = MetamorphiaBootstrap.viewModel

        if showNotch, let vm, !vm.isProcessing {
            CommandBarCoordinator.shared.summon()
            await vm.submit(prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID)
            return vm.conversation.last?.result ?? ""
        }

        if let loop = MetamorphiaBootstrap.loop {
            // M9: bind this run's thread to the phone's sessionID so the agent
            // loop persists it under ConversationStore(sessionId:). Best-effort:
            // the singleton loop's default sessionId is nil, so we set the
            // per-run override before submit and clear it after.
            // FileConversationStore is injected at MetamorphiaBootstrap:~578.
            await loop.setRunSessionId(sessionID)
            // Load the session's persisted history so phone turns continue the
            // same thread rather than starting from scratch each time.
            let previousMessages: [ChatMessage]
            if let sid = sessionID {
                previousMessages = await loop.loadMessages(sessionId: sid)
            } else {
                previousMessages = []
            }
            let outcome = await loop.submit(
                command: prompt,
                systemPrompt: systemPrompt,
                previousMessages: previousMessages
            )
            await loop.setRunSessionId(nil)
            return outcome.text
        }
#endif
        return "Metamorphia AI is not configured."
    }

    /// Builds the prompt used for the "analyze this file" flow. Agent tools
    /// (shell / AppleScript) read the file directly — we just hand over the
    /// path plus the user's question.
    static func analyzeFilePrompt(paths: [String], question: String?) -> String {
        let header: String
        switch paths.count {
        case 0: header = "(no file)"
        case 1: header = "File: \(paths[0])"
        default:
            let list = paths.map { "- \($0)" }.joined(separator: "\n")
            header = "Files:\n\(list)"
        }
        let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ask = trimmed.isEmpty
            ? "Analyze the file(s) above and summarize what they contain, any notable findings, and anything the user should know."
            : trimmed
        return "\(header)\n\n\(ask)"
    }
}
