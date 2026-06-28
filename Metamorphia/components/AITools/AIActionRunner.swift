/*
 * Metamorphia – Intelligence Glass
 *
 * Central dispatch for Writing Tools verb execution.
 *
 * Two entry points:
 *   • `run(verb:)`                   — AX capture → generate → write back (headless).
 *   • `generate(verb:)`              — AX capture → generate, returns (capture, result)
 *                                      so the panel can offer Replace / Copy.
 *   • `runFromPasteboardText(verb:text:)` — used by the NSServices path, where
 *                                           the OS has already serialized the selection
 *                                           onto the pasteboard before invoking us.
 *                                           Shows the notch so the user sees the result.
 */

import AppKit
import Foundation
#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

// MARK: - AIActionRunner

@MainActor
enum AIActionRunner {

    // MARK: - WritingVerb

    enum WritingVerb: String, CaseIterable, Identifiable {
        case proofread
        case rewrite
        case summarize
        case reply

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .proofread: return "Proofread"
            case .rewrite:   return "Rewrite"
            case .summarize: return "Summarize"
            case .reply:     return "Reply"
            }
        }

        /// SF Symbol name. Proportional weight; never monospaced.
        var iconSymbol: String {
            switch self {
            case .proofread: return "text.badge.checkmark"
            case .rewrite:   return "arrow.triangle.2.circlepath"
            case .summarize: return "text.alignleft"
            case .reply:     return "arrowshape.turn.up.left"
            }
        }
    }

    // MARK: - Prompts

    private static func prompt(for verb: WritingVerb, text: String) -> String {
        switch verb {
        case .proofread:
            return """
            Correct grammar, spelling, and punctuation in the text below. \
            Return ONLY the corrected text — no commentary, no explanation.

            \"\"\"
            \(text)
            \"\"\"
            """
        case .rewrite:
            return """
            Rewrite the text below for clarity and flow, preserving the \
            original meaning and tone. Return ONLY the rewrite — no preamble, \
            no explanation.

            \"\"\"
            \(text)
            \"\"\"
            """
        case .summarize:
            return """
            Summarize the text below concisely. Return ONLY the summary — \
            no preamble, no explanation.

            \"\"\"
            \(text)
            \"\"\"
            """
        case .reply:
            return """
            Draft a concise, professional reply to the message below. \
            Return ONLY the reply text — no preamble, no explanation.

            \"\"\"
            \(text)
            \"\"\"
            """
        }
    }

    // MARK: - System prompt

    private static var writingSystemPrompt: String {
        AgentRegistry.shared.profile(for: "writing").systemPromptFragment
    }

    // MARK: - AX-capture entry points (panel + hotkey)

    /// Capture selection → run model → write back. Used by hotkey and other
    /// zero-UI callers. Returns the generated text (empty on any failure).
    @discardableResult
    static func run(verb: WritingVerb) async -> String {
        guard let capture = try? TextFieldAccess.captureSelection(),
              !capture.text.isEmpty else { return "" }

        let result = await MetamorphiaIntentEngine.run(
            prompt: prompt(for: verb, text: capture.text),
            systemPrompt: writingSystemPrompt,
            showNotch: false
        )
        guard !result.isEmpty else { return "" }

        TextFieldAccess.writeBack(result, to: capture)
        return result
    }

    /// Capture selection → run model → return (capture, result) WITHOUT
    /// auto write-back. The panel shows the result and lets the user choose
    /// Replace or Copy.
    static func generate(verb: WritingVerb) async -> (TextFieldAccess.Capture, String)? {
        guard let capture = try? TextFieldAccess.captureSelection(),
              !capture.text.isEmpty else { return nil }

        let result = await MetamorphiaIntentEngine.run(
            prompt: prompt(for: verb, text: capture.text),
            systemPrompt: writingSystemPrompt,
            showNotch: false
        )
        guard !result.isEmpty else { return nil }

        return (capture, result)
    }

    // MARK: - Pasteboard entry point (NSServices)

    /// Used by the NSServices path. The OS hands us the selection as plain text
    /// via the pasteboard (no AX capture needed). Shows the notch so the result
    /// is visible to the user.
    @discardableResult
    static func runFromPasteboardText(verb: WritingVerb, text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let result = await MetamorphiaIntentEngine.run(
            prompt: prompt(for: verb, text: trimmed),
            systemPrompt: writingSystemPrompt,
            showNotch: true
        )
        return result
    }
}
