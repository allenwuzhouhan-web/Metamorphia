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
    static func run(
        prompt: String,
        systemPrompt: String = defaultSystemPrompt,
        showNotch: Bool = true
    ) async -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

#if canImport(MetamorphiaAgentKit)
        let vm = MetamorphiaBootstrap.viewModel

        if showNotch, let vm, !vm.isProcessing {
            CommandBarCoordinator.shared.summon()
            await vm.submit(prompt: prompt, systemPrompt: systemPrompt)
            return vm.conversation.last?.result ?? ""
        }

        if let loop = MetamorphiaBootstrap.loop {
            let outcome = await loop.submit(command: prompt, systemPrompt: systemPrompt)
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
