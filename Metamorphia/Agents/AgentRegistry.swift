import Foundation

public final class AgentRegistry {
    public static let shared = AgentRegistry()
    private static let activeAgentDefaultsKey = "Metamorphia.currentAgentId"
    private let profilesById: [String: AgentProfile]
    private let orderedProfiles: [AgentProfile]

    private init() {
        let all: [AgentProfile] = [
            .general,
            AgentProfile(
                id: "research",
                displayName: "Research",
                systemPromptFragment: """
                You are Metamorphia's research-mode agent. Prioritize accuracy \
                and provenance over speed. Cite sources inline as [1], [2], … \
                with a trailing references list. Prefer structured summaries \
                (bullet points, short sections) over prose walls. When uncertain, \
                say so explicitly rather than guessing.
                """,
                colorHex: "#4CAF50",
                iconSymbol: "magnifyingglass.circle.fill"
            ),
            AgentProfile(
                id: "code",
                displayName: "Code",
                systemPromptFragment: """
                You are Metamorphia's coding assistant. Be terse and code-first — \
                show the code before the explanation, not after. Use fenced \
                code blocks with a language tag. Prefer idiomatic patterns for \
                the language in question. When suggesting a change, show the \
                diff, not the whole file.
                """,
                colorHex: "#2196F3",
                iconSymbol: "chevron.left.forwardslash.chevron.right"
            ),
            AgentProfile(
                id: "writing",
                displayName: "Writing",
                systemPromptFragment: """
                You are Metamorphia's writing assistant. Focus on clarity, \
                cadence, and voice. When editing, preserve the author's tone \
                unless asked to change it. Prefer active voice and concrete \
                nouns. If you rewrite, show the rewrite first and the rationale \
                second.
                """,
                colorHex: "#E91E63",
                iconSymbol: "pencil.line"
            ),
            AgentProfile(
                id: "design",
                displayName: "Design",
                systemPromptFragment: """
                You are Metamorphia's design-mode agent. Think in terms of \
                hierarchy, rhythm, and restraint. Describe layouts with explicit \
                spacing, type scale, and color tokens. When giving feedback, \
                lead with the single highest-impact change before listing \
                smaller refinements.
                """,
                colorHex: "#FF9800",
                iconSymbol: "paintpalette.fill"
            )
        ]
        self.orderedProfiles = all
        self.profilesById = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }

    public func allProfiles() -> [AgentProfile] { orderedProfiles }
    public func profile(for id: String) -> AgentProfile {
        profilesById[id] ?? .general
    }
    public func loadPersistedActive() -> AgentProfile {
        let id = UserDefaults.standard.string(forKey: Self.activeAgentDefaultsKey) ?? AgentProfile.general.id
        return profile(for: id)
    }
    public func persistActive(_ profile: AgentProfile) {
        UserDefaults.standard.set(profile.id, forKey: Self.activeAgentDefaultsKey)
    }
}
