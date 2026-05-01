import Foundation
#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

/// Parser for the slash-command syntax used by the command bar.
///
/// Two responsibilities:
/// 1. **Suggesting** — given the live input string, identify which `/token`
///    the caret is currently typing and surface the matching skills.
/// 2. **Resolving** — given a fully-typed input, extract the ordered list of
///    `/skill` tokens (and any free-form text), so the view model can compose
///    a chained system prompt and submit the cleaned query to the agent.
///
/// The parser is intentionally permissive: it doesn't fail on unknown tokens,
/// it just leaves them in the free-form remainder. The agent loop is the
/// arbiter of what gets executed.
@MainActor
public enum SlashCommandParser {

    // MARK: - Suggesting

    /// What the user is in the middle of typing. Drives the dropdown.
    public struct ActiveToken: Equatable {
        /// The substring after the leading `/`, used as the search query.
        public let query: String
        /// Range in the original string occupied by `/<query>` (inclusive of
        /// the slash). The view model uses this to splice in the chosen skill
        /// id when the user picks a suggestion.
        public let range: Range<String.Index>
    }

    /// Find the `/token` the caret is currently inside, if any. Returns nil
    /// when the caret isn't sitting on a slash token (e.g. plain prose, or
    /// just after a space).
    ///
    /// Caret position defaults to end-of-string when not provided — that
    /// matches the natural typing case.
    public static func activeToken(in input: String, caret: String.Index? = nil) -> ActiveToken? {
        let pos = caret ?? input.endIndex
        guard pos > input.startIndex else { return nil }

        // Walk backward from the caret until we hit whitespace or the start.
        // The slash must be at the start of the substring we collect for it
        // to count as a slash token (i.e. `foo/bar` is not a slash command —
        // only a `/` preceded by whitespace or string-start).
        var i = pos
        while i > input.startIndex {
            let prev = input.index(before: i)
            let ch = input[prev]
            if ch.isWhitespace { return nil }
            if ch == "/" {
                let isAtStart = prev == input.startIndex
                let prevIsBoundary = !isAtStart && input[input.index(before: prev)].isWhitespace
                guard isAtStart || prevIsBoundary else { return nil }
                let queryStart = input.index(after: prev)
                let query = String(input[queryStart..<pos])
                return ActiveToken(query: query, range: prev..<pos)
            }
            i = prev
        }
        return nil
    }

    // MARK: - Resolving

    public struct Resolved {
        /// Skill ids in submission order, in the order they appeared in the
        /// input (left-to-right). May be empty.
        public let skillIds: [String]
        /// Whatever free-form text the user typed alongside the slashes —
        /// arguments, prose, the actual question. May be empty if the input
        /// was nothing but `/skill /skill /skill`.
        public let freeText: String
    }

    /// Pull every `/<id>` token out of the input, leaving the rest as
    /// free-form text. Tokens are matched against the supplied `knownIds`
    /// set — unknown tokens are left in place (treated as plain text) so the
    /// LLM can interpret them however it wants. This avoids surprising users
    /// who type `/foo/bar` URL-style and don't expect either to vanish.
    public static func resolve(input: String, knownIds: Set<String>) -> Resolved {
        var skills: [String] = []
        var remainder: [String] = []

        for raw in input.split(separator: " ", omittingEmptySubsequences: true) {
            let token = String(raw)
            if token.hasPrefix("/"), token.count > 1 {
                let id = String(token.dropFirst())
                if knownIds.contains(id) {
                    skills.append(id)
                    continue
                }
            }
            remainder.append(token)
        }

        return Resolved(
            skillIds: skills,
            freeText: remainder.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// A skill rendered for the dropdown. The struct itself is unconditional so
/// the view model can publish `[SkillSuggestion]` regardless of whether
/// `MetamorphiaAgentKit` is linked (stub-mode builds still compile). The
/// `Skill`-based convenience init is gated.
public struct SkillSuggestion: Identifiable, Equatable {
    public let id: String
    public let description: String
    public let emoji: String?
    public let isStub: Bool

    public init(id: String, description: String, emoji: String?, isStub: Bool) {
        self.id = id
        self.description = description
        self.emoji = emoji
        self.isStub = isStub
    }
}

#if canImport(MetamorphiaAgentKit)
extension SkillSuggestion {
    /// Wrap a `Skill` for display. Pulls the `emoji` and `status` keys out
    /// of frontmatter so the dropdown can render an icon and an optional
    /// "stub" badge.
    public init(skill: Skill) {
        self.init(
            id: skill.id,
            description: skill.description,
            emoji: skill.frontmatter["emoji"],
            isStub: skill.frontmatter["status"]?.lowercased() == "stub"
        )
    }
}
#endif
