import Foundation

/// A single text transformation offered by the AI tools surface (Writing Tools,
/// Summarize Anything, Smart Reply). Each case carries the instruction sent to
/// the LLM plus the presentation metadata the UI needs.
public enum AIAction: String, CaseIterable, Identifiable, Sendable {
    case proofread
    case rewriteFriendly
    case rewriteProfessional
    case rewriteConcise
    case summarize
    case keyPoints
    case makeTable
    case makeList
    case smartReply

    public var id: String { rawValue }

    /// Short, user-facing label.
    public var title: String {
        switch self {
        case .proofread: return "Proofread"
        case .rewriteFriendly: return "Friendly"
        case .rewriteProfessional: return "Professional"
        case .rewriteConcise: return "Concise"
        case .summarize: return "Summary"
        case .keyPoints: return "Key Points"
        case .makeTable: return "Table"
        case .makeList: return "List"
        case .smartReply: return "Reply"
        }
    }

    /// SF Symbol used to represent the action in menus and toolbars.
    public var systemImage: String {
        switch self {
        case .proofread: return "checkmark.circle"
        case .rewriteFriendly: return "face.smiling"
        case .rewriteProfessional: return "briefcase"
        case .rewriteConcise: return "scissors"
        case .summarize: return "text.append"
        case .keyPoints: return "list.star"
        case .makeTable: return "tablecells"
        case .makeList: return "list.bullet"
        case .smartReply: return "arrowshape.turn.up.left"
        }
    }

    /// Whether the result should overwrite the user's current selection in place.
    /// Proofread and the rewrite variants edit the text the user picked; the rest
    /// produce new derived content that is inserted or copied instead.
    public var replacesSelection: Bool {
        switch self {
        case .proofread, .rewriteFriendly, .rewriteProfessional, .rewriteConcise:
            return true
        case .summarize, .keyPoints, .makeTable, .makeList, .smartReply:
            return false
        }
    }

    /// The instruction handed to the model as the system message. Every prompt
    /// ends by demanding raw output only — no preamble, no surrounding quotes,
    /// no explanation — so the result can be dropped straight back into the
    /// user's document.
    var systemPrompt: String {
        let outputOnly = "Output only the resulting text. Do not add any preamble, "
            + "explanation, commentary, or surrounding quotation marks."

        switch self {
        case .proofread:
            return """
            You are a meticulous proofreader. Correct spelling, grammar, and \
            punctuation in the user's text. Preserve the original meaning, tone, \
            voice, and formatting; do not rewrite, shorten, or embellish. If the \
            text is already correct, return it unchanged. \(outputOnly)
            """
        case .rewriteFriendly:
            return """
            Rewrite the user's text in a warm, friendly, approachable tone while \
            keeping its meaning and key information intact. Keep it natural and \
            roughly the same length. \(outputOnly)
            """
        case .rewriteProfessional:
            return """
            Rewrite the user's text in a clear, polished, professional tone \
            suitable for business communication. Preserve the meaning and key \
            information; fix any awkward phrasing. \(outputOnly)
            """
        case .rewriteConcise:
            return """
            Rewrite the user's text to be as concise as possible without losing \
            essential meaning or important details. Remove redundancy and filler. \
            \(outputOnly)
            """
        case .summarize:
            return """
            Summarize the user's text into a brief, faithful summary that captures \
            the main ideas. Write in clear prose of one short paragraph. Do not add \
            information that is not in the source. \(outputOnly)
            """
        case .keyPoints:
            return """
            Extract the key points from the user's text as a concise markdown \
            bulleted list, one point per bullet using "- " markers. Each point \
            should be self-contained and faithful to the source. \(outputOnly)
            """
        case .makeTable:
            return """
            Organize the information in the user's text into a single GitHub-\
            flavored markdown table with a clear header row and a separator row of \
            dashes. Choose sensible column headers from the content. \(outputOnly)
            """
        case .makeList:
            return """
            Reformat the information in the user's text as a markdown bulleted \
            list using "- " markers, one item per line. Preserve the original \
            wording where reasonable and do not invent new items. \(outputOnly)
            """
        case .smartReply:
            return """
            You are drafting a reply on the user's behalf to the message provided. \
            Write a concise, natural, and appropriately polite response that \
            directly addresses the message. If additional context is provided, use \
            it to make the reply relevant and accurate. Write only the reply body, \
            with no greeting placeholders like "[Name]" unless clearly warranted. \
            \(outputOnly)
            """
        }
    }
}
