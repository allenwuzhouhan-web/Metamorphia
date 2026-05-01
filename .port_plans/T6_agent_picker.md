# T6 — Agent Picker Port Plan

## Executive Summary

Port Executer's agent picker pill into Metamorphia's notch command bar. Introduces a minimal `AgentProfile` struct and a lightweight `AgentRegistry` with 5 hardcoded built-ins (general, research, code, writing, design). No filesystem persistence for profiles — only the active agent id survives via `UserDefaults`. The picker renders as a small capsule between the leading status icon and the `AttachmentBadgeView` inside `inputRow`; tapping opens a native `Menu`. When the active agent is non-general, a 5pt colored dot overlays the leading icon. On `submit`, `AICommandViewModel` composes `systemPrompt = base + profile.systemPromptFragment`. No per-agent tool gating, no custom user profiles, no transcript colorization — Executer-style `AgentRouter` auto-routing is out of scope.

## 1. File List

**New (3):**
- `/Users/allenwu/claude/metamorphia/Metamorphia/Agents/AgentProfile.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/Agents/AgentRegistry.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/AgentPickerView.swift`

**Edit (2):**
- `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift`

## 2. `AgentProfile.swift`

```swift
import SwiftUI

public struct AgentProfile: Identifiable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let systemPromptFragment: String
    public let colorHex: String
    public let iconSymbol: String

    public init(
        id: String, displayName: String, systemPromptFragment: String,
        colorHex: String, iconSymbol: String
    ) {
        self.id = id
        self.displayName = displayName
        self.systemPromptFragment = systemPromptFragment
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
    }

    public var color: Color {
        Color(agentHex: colorHex) ?? .white
    }

    public static let general = AgentProfile(
        id: "general",
        displayName: "General",
        systemPromptFragment: "",
        colorHex: "#FFFFFF",
        iconSymbol: "sparkle"
    )
}

extension Color {
    init?(agentHex: String) {
        var hex = agentHex.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgb) else { return nil }
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((rgb & 0xFF0000) >> 16) / 255.0
            g = Double((rgb & 0x00FF00) >> 8) / 255.0
            b = Double(rgb & 0x0000FF) / 255.0
        case 8:
            r = Double((rgb & 0xFF000000) >> 24) / 255.0
            g = Double((rgb & 0x00FF0000) >> 16) / 255.0
            b = Double((rgb & 0x0000FF00) >> 8) / 255.0
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b)
    }
}
```

## 3. `AgentRegistry.swift`

```swift
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
```

## 4. `AgentPickerView.swift`

```swift
import SwiftUI

struct AgentPickerView: View {
    let activeAgent: AgentProfile
    let profiles: [AgentProfile]
    let onSelect: (AgentProfile) -> Void

    var body: some View {
        Menu {
            ForEach(profiles, id: \.id) { profile in
                Button {
                    onSelect(profile)
                } label: {
                    HStack {
                        Image(systemName: profile.iconSymbol)
                        Text(profile.displayName)
                        Spacer()
                        if profile.id == activeAgent.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(activeAgent.color)
                    .frame(width: 6, height: 6)
                Text(activeAgent.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch agent")
    }
}
```

## 5. `AICommandViewModel.swift` edits

### 5a. Replace `currentAgentName` declaration

```swift
/// Hydrated from UserDefaults on init. Written only via setActiveAgent.
@Published public private(set) var currentAgent: AgentProfile = .general

/// Back-compat shim for any stray reader of the old property name.
public var currentAgentName: String { currentAgent.id }
```

### 5b. Hydrate on init (both AgentKit path and stub path)

After the existing init setup, add:
```swift
self.currentAgent = AgentRegistry.shared.loadPersistedActive()
```

### 5c. Add setter (near `cancel()`)

```swift
public func setActiveAgent(_ profile: AgentProfile) {
    guard profile.id != currentAgent.id else { return }
    currentAgent = profile
    AgentRegistry.shared.persistActive(profile)
}
```

### 5d. Inject fragment in `submit(...)`

After `let chainedSystemPrompt = injectSkillBodies(base: systemPrompt, skillIds: resolved.skillIds)`:

```swift
let agentShapedPrompt = injectAgentFragment(
    base: chainedSystemPrompt,
    agent: currentAgent
)
var primedPrompt = primedSystemPrompt(base: agentShapedPrompt, query: agentPrompt)
```

### 5e. Add helper

```swift
private func injectAgentFragment(base: String, agent: AgentProfile) -> String {
    let fragment = agent.systemPromptFragment
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fragment.isEmpty else { return base }
    return """
    \(base)

    ## Active Agent — \(agent.displayName)

    \(fragment)
    """
}
```

### 5f. Apply to `submitSilent` and the voice-final path

Wrap their hardcoded system prompts with `injectAgentFragment(base:, agent: currentAgent)`.

## 6. `NotchCommandBarView.swift` edits

### 6a. Modify `inputRow` — wrap icon in ZStack with dot overlay, insert picker

```swift
HStack(alignment: .center, spacing: 12) {
    ZStack(alignment: .topTrailing) {
        Image(systemName: CommandBarStateHelpers.icon(for: viewModel.inputBarState))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(CommandBarStateHelpers.iconColor(for: viewModel.inputBarState))
            .animation(.spring(response: 0.3), value: viewModel.inputBarState)

        if viewModel.currentAgent.id != AgentProfile.general.id {
            Circle()
                .fill(viewModel.currentAgent.color)
                .frame(width: 5, height: 5)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5))
                .offset(x: 2, y: -2)
                .transition(.scale.combined(with: .opacity))
        }
    }
    .frame(width: 18, height: 18)

    AgentPickerView(
        activeAgent: viewModel.currentAgent,
        profiles: AgentRegistry.shared.allProfiles(),
        onSelect: { viewModel.setActiveAgent($0) }
    )
    .transition(.opacity)

    if !viewModel.attachedFiles.isEmpty {
        AttachmentBadgeView(
            count: viewModel.attachedFiles.count,
            onClear: { viewModel.clearAttachments() }
        )
        .transition(.scale.combined(with: .opacity))
    }

    // ... rest of inputRow unchanged (TextField or Text branch + trailing control)
}
// ... existing .background(ShimmerOverlay...) + .onDrop stays
```

### 6b. Add animation-value binding

```swift
.animation(Self.fluidSpring, value: viewModel.currentAgent.id)
```

## 7. Risks

1. UserDefaults orphaning: if an agent id is renamed in a future version, persisted id silently falls back to `.general`. Intended behavior.
2. Shimmer + Menu: Menu opens as a platform popover, independent of shimmer draw tree. Low risk.
3. Mid-turn agent swap doesn't restream: `systemPrompt` is fixed at `submit(...)` time. Intentional.
4. Picker width: longest name "Research"/"Writing" at 8 chars; `.fixedSize()` keeps it tight.
5. `currentAgentName` back-compat shim keeps any stray reference compiling.

## 8. Out of Scope

- Per-agent tool allow-lists
- Custom user-created agents
- `AgentRouter` keyword-based auto-routing
- Per-agent transcript coloring
- Per-agent cost/token budgets
- Session-scoped agent changes

## 9. Test Plan

1. Cold start → picker reads "● General", no overlay dot.
2. Switch to Research → pill shows "● Research" green, overlay dot appears. Submit: reply cites sources.
3. Mid-conversation switch to Code → icon dot blue, reply is code-first.
4. Restart app → picker persists.
5. Switch back to General → overlay dot fades.
6. During streaming, open menu → menu opens cleanly; switch doesn't cancel in-flight.
7. Stale persisted id → silent fallback to General.
