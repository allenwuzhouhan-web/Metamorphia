import Foundation

/// Finite-state machine for the AI Command Bar.
///
/// Ported from Executer's `InputBarState`. Only the cases actively used by
/// T1 are fully wired (`ready / processing / planning / executing / streaming
/// / result / error`). The remaining cases (`voiceListening / researchChoice /
/// browserChoice / thoughtRecall / newsBriefing / coworkingSuggestion /
/// healthCard`) are declared now so later tasks can flip the matching UI on
/// without touching the enum or sink plumbing again.
///
/// Associated values use only types that exist in the Metamorphia module today
/// (String / Int). Executer's `AgentTrace`, `RichResult`, `ThoughtRecall`,
/// `NewsBriefingArticle`, `CoworkingSuggestion` are intentionally NOT ported
/// in T1 — their payloads are reduced to placeholder `String` / `[String]`
/// until the card tasks (T7/T8/…) port the full models.
public enum InputBarState: Equatable {
    case ready
    case processing
    case planning(summary: String)
    case executing(toolName: String, step: Int, total: Int)
    case streaming(partialText: String)
    case result(message: String)
    case error(message: String)

    // Later-task placeholders — declared so the ViewModel + helpers can
    // already switch exhaustively over the enum. The payload shapes are
    // intentionally minimal; richer models land with T7/T8/…
    case voiceListening(partial: String)
    case researchChoice(query: String)
    case browserChoice(query: String)
    /// Awaiting the user's one-line answer to "what is this document for?" before
    /// running a proofread. `originalPrompt` is replayed once the answer arrives.
    case purposeQuestion(question: String, originalPrompt: String)
    case thoughtRecall(summary: String)
    case newsBriefing(headlines: [String])
    case coworkingSuggestion(title: String)
    case healthCard(message: String)

    /// A coarse identity for driving `.animation(value:)` that ignores the
    /// rapidly-changing payloads of `streaming`/`voiceListening`. Keying a spring
    /// on the full state re-armed the animation across the whole command-bar
    /// subtree on every streamed token, saturating the main thread. Animations
    /// should fire on *transitions between* states, not on each token within one.
    public var animationPhase: Int {
        switch self {
        case .ready: return 0
        case .processing: return 1
        case .planning: return 2
        case .executing: return 3
        case .streaming: return 4
        case .result: return 5
        case .error: return 6
        case .voiceListening: return 7
        case .researchChoice: return 8
        case .browserChoice: return 9
        case .purposeQuestion: return 10
        case .thoughtRecall: return 11
        case .newsBriefing: return 12
        case .coworkingSuggestion: return 13
        case .healthCard: return 14
        }
    }
}
