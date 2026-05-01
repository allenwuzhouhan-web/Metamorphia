# T7 — Research & Browser Choice Inline Cards

## Executive Summary

Port Executer's research- and browser-choice inline cards. The feature intercepts prompts like "deep research ..." or "book a flight on expedia.com" between Return and the agent loop, showing two buttons. The chosen button re-submits with a bracketed prefix (`[deep research] ...`, `[browser visible] ...`).

**Detection strategy:** lift Executer's heuristics as pure static helpers in `Metamorphia/Services/` (`ResearchDetector.swift`, `BrowserTaskDetector.swift`).

**VM flow:** `submit(prompt:systemPrompt:)` gains a preamble: (a) fast-path exit if prompt starts with one of the bracketed prefixes (means re-entry from a choice button → skip detection); (b) otherwise run both detectors; (c) on match, set `inputBarState = .researchChoice(query:)` or `.browserChoice(query:)` and `return` before agent-loop call.

**Methods:** `submitResearch(query:mode:)` and `submitBrowserTask(query:visible:)` prepend the prefix and re-enter `submit(...)`. `cancelChoice()` returns to `.ready`.

**UI:** `ChoiceCardView.swift` with `ResearchChoiceCard` and `BrowserChoiceCard` sibling views. Two side-by-side pill buttons + "Cancel (Esc)" link. Native SwiftUI shapes, no liquidGlass (Metamorphia idiom).

**Cancel:** Escape + visible link both call `cancelChoice()`. `currentInput` remains populated (deferred clear happens post-detection) so the user can tweak and re-submit.

---

## 1. File list

**Create:**
- `/Users/allenwu/claude/metamorphia/Metamorphia/Services/ResearchDetector.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/Services/BrowserTaskDetector.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ChoiceCardView.swift`

**Edit:**
- `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift`

## 2. Detectors

### `ResearchDetector.swift`

```swift
import Foundation

enum ResearchDetector {
    static let prefixes: [String] = [
        "research ", "deep dive ", "investigate ", "deep research ",
    ]

    static func matches(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefixes.contains { lower.hasPrefix($0) }
    }
}
```

### `BrowserTaskDetector.swift`

```swift
import Foundation

enum BrowserTaskDetector {
    static let lookupKeywords: [String] = [
        "look up", "search for", "find out", "find information",
        "find reviews", "find the best", "find prices", "compare",
        "check availability", "check the price", "research",
        "fill form", "fill out", "log in to", "login to",
        "sign up on", "sign in to", "book a", "book on",
        "order from", "order on", "purchase", "checkout",
        "add to cart", "submit form", "automate web",
        "on the website", "on the site", "using the browser",
    ]

    static let simpleNavPrefixes: [String] = [
        "go to ", "navigate to ", "browse to ", "open ",
    ]

    static let siteReferenceTokens: [String] = [
        ".com", ".org", ".net", "http", "website", "site",
        "browser", "online",
    ]

    static let complexIndicators: [String] = [
        "fill", "submit", "log in", "login", "sign in", "sign up", "register",
        "checkout", "check out", "purchase", "buy", "add to cart", "payment",
        "book ", "booking", "automate", "form", "multi-page", "multiple pages",
        "download", "upload",
    ]

    static func matches(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if simpleNavPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return false
        }

        let hasLookup = lookupKeywords.contains { lower.contains($0) }
        let hasSite = siteReferenceTokens.contains { lower.contains($0) }
        guard hasLookup && hasSite else { return false }

        return complexIndicators.contains { lower.contains($0) }
    }
}
```

## 3. VM changes

### 3.1 Prefix sentinel constants + helper (fileprivate, near top of class)

```swift
fileprivate static let choicePrefixes: [String] = [
    "[deep research] ",
    "[light research] ",
    "[browser visible] ",
    "[browser background] ",
]

fileprivate static func hasChoicePrefix(_ prompt: String) -> Bool {
    choicePrefixes.contains { prompt.hasPrefix($0) }
}
```

### 3.2 ResearchMode enum

```swift
public enum ResearchMode: String {
    case deep = "deep"
    case light = "light"
}
```

### 3.3 Detection preamble in `submit(...)`

Insert **immediately after** the empty-input guard and **before** `QueryPatternLearner.shared.observe(...)`:

```swift
// T7: Research / browser-task detection.
if !Self.hasChoicePrefix(prompt) {
    if ResearchDetector.matches(prompt) {
        inputBarState = .researchChoice(query: prompt)
        return
    }
    if BrowserTaskDetector.matches(prompt) {
        inputBarState = .browserChoice(query: prompt)
        return
    }
}
```

Note: `currentInput` is cleared several lines later in `submit`. Returning before that clear means cancel restores the user's text for free.

### 3.4 New public methods

```swift
public func submitResearch(query: String, mode: ResearchMode) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let prefixed = "[\(mode.rawValue) research] \(query)"
    inputBarState = .processing
    Task { [weak self] in
        guard let self else { return }
        await self.submit(
            prompt: prefixed,
            systemPrompt: Self.defaultSystemPrompt
        )
    }
}

public func submitBrowserTask(query: String, visible: Bool) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let prefix = visible ? "[browser visible]" : "[browser background]"
    let prefixed = "\(prefix) \(query)"
    inputBarState = .processing
    Task { [weak self] in
        guard let self else { return }
        await self.submit(
            prompt: prefixed,
            systemPrompt: Self.defaultSystemPrompt
        )
    }
}

public func cancelChoice() {
    switch inputBarState {
    case .researchChoice, .browserChoice:
        inputBarState = .ready
    default:
        break
    }
}

fileprivate static let defaultSystemPrompt =
    "You are Metamorphia, an AI assistant on macOS. Use the available tools to fulfill the user's request. Be concise — the user sees your reply in a compact bar."
```

**NOTE TO CODER:** If a `defaultSystemPrompt` equivalent already exists in the VM (voice-final path uses a hardcoded string), consider consolidating. Otherwise this new static gives one source of truth for future re-submit paths.

## 4. UI — `ChoiceCardView.swift`

```swift
import SwiftUI

struct ResearchChoiceCard: View {
    let query: String
    let onPickDeep: () -> Void
    let onPickLight: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ChoicePillButton(
                    systemImage: "magnifyingglass.circle.fill",
                    title: "Deep Research",
                    tint: .accentColor,
                    isPrimary: true,
                    action: onPickDeep
                )
                ChoicePillButton(
                    systemImage: "bolt.circle.fill",
                    title: "Quick Lookup",
                    tint: .secondary,
                    isPrimary: false,
                    action: onPickLight
                )
            }
            CancelLink(action: onCancel)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct BrowserChoiceCard: View {
    let query: String
    let onPickVisible: () -> Void
    let onPickBackground: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ChoicePillButton(
                    systemImage: "eye.circle.fill",
                    title: "Watch",
                    tint: .blue,
                    isPrimary: true,
                    action: onPickVisible
                )
                ChoicePillButton(
                    systemImage: "eye.slash.circle.fill",
                    title: "Background",
                    tint: .secondary,
                    isPrimary: false,
                    action: onPickBackground
                )
            }
            CancelLink(action: onCancel)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct ChoicePillButton: View {
    let systemImage: String
    let title: String
    let tint: Color
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(isPrimary ? tint : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPrimary
                          ? tint.opacity(0.15)
                          : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isPrimary ? tint.opacity(0.30) : Color.white.opacity(0.08),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CancelLink: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                Text("Cancel (Esc)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel choice, return to editor")
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}
```

## 5. `NotchCommandBarView` edits

### 5.1 Replace the two T7 TODO branches in `stateDrivenSection`

```swift
case .researchChoice(let query):
    ResearchChoiceCard(
        query: query,
        onPickDeep: { viewModel.submitResearch(query: query, mode: .deep) },
        onPickLight: { viewModel.submitResearch(query: query, mode: .light) },
        onCancel: { viewModel.cancelChoice() }
    )

case .browserChoice(let query):
    BrowserChoiceCard(
        query: query,
        onPickVisible: { viewModel.submitBrowserTask(query: query, visible: true) },
        onPickBackground: { viewModel.submitBrowserTask(query: query, visible: false) },
        onCancel: { viewModel.cancelChoice() }
    )
```

### 5.2 Extend `.onExitCommand`

```swift
.onExitCommand {
    if case .voiceListening = viewModel.inputBarState {
        // Voice cancel path already wired in T5 — preserve existing.
        // (NOTE TO CODER: use whatever path you wired in T5.)
    } else if case .researchChoice = viewModel.inputBarState {
        viewModel.cancelChoice()
    } else if case .browserChoice = viewModel.inputBarState {
        viewModel.cancelChoice()
    } else {
        CommandBarCoordinator.shared.dismiss()
    }
}
```

### 5.3 `isEditable` — no change needed

`.researchChoice` and `.browserChoice` are not in `isEditable`, so the TextField is hidden and the status label renders (already defined in `CommandBarStateHelpers.statusText` — "What kind of research?" / "Watch or run in background?"). Correct.

## 6. Risks

1. **False-positive browser classification** — mitigated by Escape cancel.
2. **Research prefix collisions** — "research paper due tomorrow" triggers card. Accepted per Executer.
3. **Agent may not honor the prefix** — model reads it as a hint; harmless noise if unrecognized.
4. **User types while card up** — TextField not rendered; keystrokes have no target. Natural lock.
5. **Re-entry infinite loop** — single source of truth in `choicePrefixes`. Safe if constants match.
6. **Empty-query submit** — guarded with `trimmingCharacters` check in both methods.

## 7. Out of scope

- Downstream agent mode-dispatch (prefix is noise if unhandled).
- BrowserTrailCard.
- Heuristic learning / calibration.
- Telemetry.
- Settings toggle to disable the card.

## 8. Test plan

### Manual

| Prompt | Expected |
|---|---|
| `deep research quantum tunneling` | Research card. Deep → `[deep research] ...` |
| `research the best laptops under $2000` | Research card. Quick Lookup → `[light research] ...` |
| `book a flight on united.com for next Friday` | Browser card. Watch → `[browser visible] ...` |
| `fill out the contact form on acme.com` | Browser card. Background → `[browser background] ...` |
| `look up best Italian restaurants on yelp.com` | Browser card. |
| `look up best Italian restaurants in SF` | Immediate submit (no site ref → card doesn't fire). |
| `what time is it` | Immediate submit. |
| `open github.com` | Immediate submit (simple nav). |
| Escape while card visible | Card dismisses; TextField reappears with original text. |
| Voice "research the best electric cars" | VoiceListening → silence → card fires via voice-final path. |

## 9. Implementation order

1. Create `ResearchDetector.swift` + `BrowserTaskDetector.swift`. Quick sanity test via grep/print.
2. Add `ResearchMode`, prefix sentinel, `cancelChoice`, `submitResearch`, `submitBrowserTask` to the VM. Don't wire into `submit` yet.
3. Add detection preamble to `submit(...)`.
4. Create `ChoiceCardView.swift`.
5. Wire the two cards into `stateDrivenSection` + extend `.onExitCommand`.
6. Build + manual test per §8.
