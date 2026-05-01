# T1 — Port InputBarState + shimmer overlay into Metamorphia

## Executive summary

**Create:**
- `Metamorphia/ViewModels/InputBarState.swift` — the enum
- `Metamorphia/components/AICommand/CommandBarStateHelpers.swift` — icon / statusText / shimmer helpers
- `Metamorphia/components/AICommand/ShimmerOverlay.swift` — self-contained shimmer view (reduce-motion aware)

**Edit:**
- `Metamorphia/ViewModels/AICommandViewModel.swift` — add `@Published var inputBarState`, derive `isProcessing`, map sinks
- `Metamorphia/components/Notch/NotchCommandBarView.swift` — wire shimmer overlay, state-driven icon, status label; leave `EmptyView()` for later-task cards

**Biggest risks** (read §8 for full discussion):
1. AgentLoop never emits `AgentDisplayEvent.streaming(...)` today — synthesise `.streaming` from `progressSink.streamingToken` events.
2. AgentLoop never emits `.ready` — set it manually on `submit()` entry, `cancel()`, and post-loop safety net.
3. `isProcessing` is read from 6+ external sites — keep as a computed `var`, not `@Published`.
4. Step/total wiring: `toolStarted(name)` carries NO counts; the display sink's `.executing` DOES. Prefer the display sink as canonical; progress-sink `toolStarted` is a no-op at the FSM level.
5. No existing reduce-motion helper — use `@Environment(\.accessibilityReduceMotion)` directly.

---

## 1. File list

**Create:**

| Path | Purpose |
|---|---|
| `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/InputBarState.swift` | The enum, scoped alongside the VM that owns it. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/CommandBarStateHelpers.swift` | `icon(for:)`, `statusText(for:)`, `shimmerGradient(for:)`, `isShimmering(_:)` — pure functions over `InputBarState`. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ShimmerOverlay.swift` | Self-contained SwiftUI shimmer view (reduce-motion aware). |

**Edit:**

| Path | Reason |
|---|---|
| `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift` | Add `@Published var inputBarState`, retire `@Published` on `isProcessing` in favour of a derived accessor, map sinks. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift` | State-driven icon, shimmer overlay behind the pill, status label replaces `SiriOrbView`'s `isProcessing` feed, stub-rendered later-task cases. |

**No edits needed:**

- `CommandBarCoordinator.swift` — only reads `conversation.isEmpty` / `viewModel.isProcessing` via `notchVM`; neither changes meaning.
- `MetamorphiaAgentKit` package — we build richer state from existing sinks.
- All other `isProcessing` consumers (`MetamorphiaHeader`, `NotchMinimizedView`, `AgentRunningLiveActivity`, `MetamorphiaBootstrap`, `MetamorphiaIntentEngine`) — they continue to read `isProcessing` as a derived property.

---

## 2. Enum definition

**Name chosen: `InputBarState`.** Justification: keeps verbatim naming parity with Executer so future ports (ResultBubbleView, voice, cards) drop in with zero rename churn; no Metamorphia type of that name exists.

**Location:** `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/InputBarState.swift`

```swift
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
    case thoughtRecall(summary: String)
    case newsBriefing(headlines: [String])
    case coworkingSuggestion(title: String)
    case healthCard(message: String)
}
```

Access level `public` because `AICommandViewModel` is `public`.

---

## 3. ViewModel changes (`AICommandViewModel.swift`)

### 3a. Property changes

Replace the existing `@Published public private(set) var isProcessing: Bool = false` declaration with:

```swift
/// Current command-bar FSM state. Authoritative source of truth for the
/// command bar UI; `isProcessing` is now derived from this.
@Published public private(set) var inputBarState: InputBarState = .ready

/// Back-compat accessor. Six views outside the command bar read this — keep
/// it a plain computed var so SwiftUI republishes via `inputBarState`.
public var isProcessing: Bool {
    switch inputBarState {
    case .ready, .result, .error, .researchChoice, .browserChoice,
         .thoughtRecall, .newsBriefing, .coworkingSuggestion, .healthCard,
         .voiceListening:
        return false
    case .processing, .planning, .executing, .streaming:
        return true
    }
}
```

Rationale: `voiceListening` is treated as not-processing (matches Executer; listening is an input state, not work-in-progress).

### 3b. Internal scratch fields (private, near `currentlyRunningNodeId`)

```swift
/// Highest step/total seen for the currently-executing tool. `milestone`
/// events can arrive *before* the next `toolStarted` when tools are
/// parallel; we track them so we can re-emit `.executing` with fresh step
/// counts without losing the tool name.
private var lastExecutingToolName: String = ""
private var lastExecutingStep: Int = 0
private var lastExecutingTotal: Int = 0

/// Buffered streaming text for the active turn. Accumulated from
/// `streamingToken` events and used to drive `.streaming(partialText:)`
/// without reaching back into `conversation[idx].result` from the state
/// machine path.
private var streamingBuffer: String = ""
```

### 3c. `submit(...)` entry edits

At the top of the submit body, where the VM currently does:
```swift
currentInput = ""
errorMessage = nil
isProcessing = true
liveStatus = nil
agentTree = nil
slashSuggestions = []
```
replace with:
```swift
currentInput = ""
errorMessage = nil
inputBarState = .processing
liveStatus = nil
agentTree = nil
slashSuggestions = []
streamingBuffer = ""
lastExecutingToolName = ""
lastExecutingStep = 0
lastExecutingTotal = 0
```

After the loop returns, where the VM currently does:
```swift
isProcessing = false
liveStatus = nil
agentTree = nil
currentlyRunningNodeId = nil
```
replace with:
```swift
// Terminal transition already applied by the display sink (`.result` /
// `.error` / `.cancelled`) — but if the sink path never fired for some
// reason, fall back to `.ready` so the bar isn't stuck mid-state.
switch inputBarState {
case .processing, .streaming, .executing, .planning:
    inputBarState = .ready
default:
    break
}
liveStatus = nil
agentTree = nil
currentlyRunningNodeId = nil
streamingBuffer = ""
```

`cancel()`:
```swift
public func cancel() async {
    await loop.cancelInFlight()
    inputBarState = .ready
    liveStatus = nil
    agentTree = nil
    currentlyRunningNodeId = nil
    streamingBuffer = ""
}
```

`clearConversation()`: add `inputBarState = .ready` after `conversation.removeAll()`.

### 3d. Sink-to-state mapping

**`AgentProgressSink.publish(_:)`** — extend the `switch`:

```swift
switch event.kind {
case .toolStarted(let name):
    self.appendToolPill(name: name, step: 0, total: 0)
    // Adopt the tool name as the currently-executing tool; step/total
    // come in later from `milestone` or from the display-sink
    // .executing event (which carries real counts).
    self.lastExecutingToolName = name
    self.inputBarState = .executing(
        toolName: name,
        step: self.lastExecutingStep,
        total: self.lastExecutingTotal
    )

case .toolCompleted(let name, let success):
    self.completeToolPill(name: name, success: success)
    // No state transition here — the loop will either call `.processing`
    // again (next iteration) or emit a terminal event. Leaving the
    // `.executing` state in place keeps the shimmer alive across the
    // gap between tool_completed and the next toolStarted.

case .milestone(let step, let total):
    self.updateToolPillSteps(step: step, total: total)
    self.lastExecutingStep = step
    self.lastExecutingTotal = total
    if case .executing(let name, _, _) = self.inputBarState {
        self.inputBarState = .executing(toolName: name, step: step, total: total)
    }

case .status(let label):
    self.handleStatus(label)
    if label.lowercased().hasPrefix("planning") {
        self.inputBarState = .planning(summary: label)
    }
    // Any other status label: leave state alone; `liveStatus` carries
    // the label for UI.

case .streamingToken(let chunk):
    // AgentLoop emits only `streamingToken` on `progressSink` (never
    // `.streaming` on the display sink). Synthesise the display state
    // here. Guarded so a stray token after completion doesn't revive
    // `.streaming`.
    switch self.inputBarState {
    case .result, .error, .ready:
        break
    default:
        self.streamingBuffer += chunk
        self.inputBarState = .streaming(partialText: self.streamingBuffer)
    }

case .completed, .error, .cancelled:
    self.handleRunTerminated(event.kind)

case .started, .thinking, .costBudgetExceeded:
    break
}
```

**NOTE TO CODER:** map the above to whatever the real case names are on `AgentProgressSink`. Grep the Executer file for ground truth, then reconcile with `MetamorphiaAgentKit`'s actual sink event enum. If a case name differs (e.g. `.streamToken` instead of `.streamingToken`), use the real name. **Don't invent events — if a case doesn't exist, note it in the coder's final summary and ask.**

`handleRunTerminated` stays as-is — terminal state is applied by the display sink below.

**`AgentDisplayStateSink.emit(_:)`** — replace body:

```swift
public nonisolated func emit(_ event: AgentDisplayEvent) async {
    await MainActor.run {
        guard !self.isSilentRunInProgress else { return }
        switch event {
        case .ready:
            self.inputBarState = .ready

        case .processing:
            // Don't overwrite a more-specific state already set by a
            // progress event (e.g. `.executing`) with the coarse
            // `.processing` — AgentLoop emits `.processing` once at the
            // top of the run.
            if case .ready = self.inputBarState {
                self.inputBarState = .processing
            }

        case .streaming(let text):
            if let idx = self.conversation.indices.last {
                self.conversation[idx].result = text
            }
            self.streamingBuffer = text
            self.inputBarState = .streaming(partialText: text)

        case .executing(let toolName, let step, let total):
            self.lastExecutingToolName = toolName
            self.lastExecutingStep = step
            self.lastExecutingTotal = total
            self.inputBarState = .executing(
                toolName: toolName, step: step, total: total
            )

        case .result(let text):
            if let idx = self.conversation.indices.last {
                self.conversation[idx].result = text
                self.conversation[idx].isStreaming = false
            }
            self.inputBarState = .result(message: text)
            self.streamingBuffer = ""

        case .error(let msg):
            self.errorMessage = msg
            self.inputBarState = .error(message: msg)
            self.streamingBuffer = ""

        case .cancelled:
            if let idx = self.conversation.indices.last {
                self.conversation[idx].isStreaming = false
            }
            self.inputBarState = .ready
            self.streamingBuffer = ""
        }
    }
}
```

**NOTE TO CODER:** if `AgentDisplayEvent` doesn't have every case above (e.g. no `.ready` or no `.streaming`), just omit those arms. Use `@unknown default: break` if the enum is marked frozen-unfrozen.

### 3e. Race conditions called out

1. **`streamingToken` arrives before `toolStarted`.** Normal path — the LLM streams a prose reply before deciding to call a tool. The progress-sink switch transitions to `.streaming` first; a subsequent `toolStarted` overwrites it with `.executing`. Buffer is cleared on terminal events.
2. **`milestone` arrives before `toolStarted`** (rare). `lastExecutingStep`/`lastExecutingTotal` accumulate; the next `toolStarted` picks them up.
3. **Display sink `.processing` vs progress sink `.toolStarted` ordering.** AgentLoop always emits `.processing` once at run start before any iteration. Our guard (`.processing` only overrides `.ready`) prevents the `.processing` event from clobbering an `.executing`/`.streaming` state that arrives on a later iteration.
4. **Terminal events from two sinks.** Both `displayStateSink.emit(.result)` and `progressSink.publish(.completed)` fire at run end. The progress handler `handleRunTerminated` does NOT mutate `inputBarState` — the display sink is authoritative for terminal state.
5. **`.ready` on submit start.** `submit()` sets `.processing` synchronously; the display sink's `.processing` event arrives later and no-ops because our guard only upgrades `.ready`.

---

## 4. Helper file — `CommandBarStateHelpers.swift`

Path: `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/CommandBarStateHelpers.swift`

Full contents:

```swift
import SwiftUI

/// Pure functions mapping `InputBarState` to view concerns. Kept free of
/// SwiftUI state so both `NotchCommandBarView` and future surfaces can call
/// them without duplicating switch statements.
enum CommandBarStateHelpers {

    /// SF Symbol name for the leading icon.
    static func icon(for state: InputBarState) -> String {
        switch state {
        case .ready:                return "sparkle"
        case .processing:           return "brain"
        case .planning:             return "list.bullet.clipboard"
        case .executing:            return "gearshape.2"
        case .streaming:            return "text.bubble"
        case .voiceListening:       return "mic.fill"
        case .researchChoice:       return "magnifyingglass"
        case .browserChoice:        return "globe"
        case .thoughtRecall:        return "brain.fill"
        case .result:               return "checkmark.circle.fill"
        case .error:                return "xmark.circle.fill"
        case .healthCard:           return "heart.circle.fill"
        case .newsBriefing:         return "newspaper.fill"
        case .coworkingSuggestion:  return "person.2.fill"
        }
    }

    /// Accent color for the leading icon.
    static func iconColor(for state: InputBarState) -> Color {
        switch state {
        case .result:           return .green
        case .error:            return .red
        case .voiceListening:   return .purple
        case .thoughtRecall:    return .purple
        case .healthCard:       return .teal
        default:                return .accentColor
        }
    }

    /// Human-readable status label shown in the pill when the user is not
    /// actively editing. Empty string = "show placeholder / the TextField".
    static func statusText(for state: InputBarState) -> String {
        switch state {
        case .ready:
            return ""
        case .processing:
            return "Thinking…"
        case .planning(let summary):
            return summary.isEmpty ? "Planning…" : summary
        case .executing(let name, let step, let total):
            if total > 0 {
                return "Running \(name)… (\(step)/\(total))"
            }
            return "Running \(name)…"
        case .streaming(let partial):
            return partial.isEmpty ? "Responding…" : partial
        case .voiceListening(let partial):
            return partial.isEmpty ? "Listening…" : partial
        case .result(let msg):          return msg
        case .error(let msg):           return msg
        case .researchChoice:           return "What kind of research?"
        case .browserChoice:            return "Watch or run in background?"
        case .thoughtRecall(let s):     return s.isEmpty ? "Welcome back" : s
        case .newsBriefing:             return "Morning briefing"
        case .coworkingSuggestion(let t): return t
        case .healthCard(let m):        return m
        }
    }

    /// True while the pill should display the animated shimmer overlay.
    static func isShimmering(_ state: InputBarState) -> Bool {
        switch state {
        case .processing, .planning, .executing, .streaming, .voiceListening:
            return true
        default:
            return false
        }
    }

    /// Gradient colors for the shimmer overlay. Distinct palette per state
    /// so the user can read the phase without looking at the label.
    static func shimmerGradient(for state: InputBarState) -> [Color] {
        switch state {
        case .voiceListening:
            return [.clear,
                    Color(hue: 0.78, saturation: 0.30, brightness: 1.0).opacity(0.55),
                    Color(hue: 0.62, saturation: 0.30, brightness: 1.0).opacity(0.55),
                    .clear]
        case .executing:
            return [.clear,
                    Color(hue: 0.58, saturation: 0.25, brightness: 1.0).opacity(0.45),
                    Color(hue: 0.50, saturation: 0.25, brightness: 1.0).opacity(0.45),
                    .clear]
        case .planning:
            return [.clear,
                    Color(hue: 0.10, saturation: 0.28, brightness: 1.0).opacity(0.45),
                    Color(hue: 0.13, saturation: 0.28, brightness: 1.0).opacity(0.45),
                    .clear]
        default:
            // processing / streaming — the Apple-Intelligence rainbow.
            return [.clear,
                    Color(hue: 0.75, saturation: 0.25, brightness: 1.0).opacity(0.50),
                    Color(hue: 0.60, saturation: 0.25, brightness: 1.0).opacity(0.50),
                    Color(hue: 0.85, saturation: 0.25, brightness: 1.0).opacity(0.50),
                    Color(hue: 0.08, saturation: 0.25, brightness: 1.0).opacity(0.50),
                    .clear]
        }
    }
}
```

---

## 5. View changes (`NotchCommandBarView.swift`)

### 5a. Replace the `SiriOrbView` icon with a state-driven SF Symbol

Current:
```swift
SiriOrbView(
    isProcessing: viewModel.isProcessing,
    hasError: viewModel.errorMessage != nil,
    diameter: 18
)
```
Replace with:
```swift
Image(systemName: CommandBarStateHelpers.icon(for: viewModel.inputBarState))
    .font(.system(size: 14, weight: .medium))
    .foregroundStyle(CommandBarStateHelpers.iconColor(for: viewModel.inputBarState))
    .frame(width: 18, height: 18)
    .animation(.spring(response: 0.3), value: viewModel.inputBarState)
```

Rationale: matches Executer's `InputBarView.swift:25-29`. Keeps the same 18pt slot so layout doesn't shift. `SiriOrbView` is no longer referenced from this file but is left on disk for other callers.

### 5b. Add status label when not `.ready`

Restructure `inputRow` so the `TextField` is replaced by a status `Text` when the state is non-ready:

```swift
private var inputRow: some View {
    HStack(alignment: .center, spacing: 12) {
        Image(systemName: CommandBarStateHelpers.icon(for: viewModel.inputBarState))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(CommandBarStateHelpers.iconColor(for: viewModel.inputBarState))
            .frame(width: 18, height: 18)
            .animation(.spring(response: 0.3), value: viewModel.inputBarState)

        if isEditable(viewModel.inputBarState) {
            TextField("Ask Metamorphia", text: $viewModel.currentInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .tint(Color.accentColor)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { submit() }
                // KEEP the existing .onKeyPress modifiers verbatim
        } else {
            Text(CommandBarStateHelpers.statusText(for: viewModel.inputBarState))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }

        trailingControl
            .animation(Self.quickFade, value: viewModel.isProcessing)
            .animation(Self.quickFade, value: viewModel.currentInput.isEmpty)
    }
    .background(
        ShimmerOverlay(
            isActive: CommandBarStateHelpers.isShimmering(viewModel.inputBarState),
            colors: CommandBarStateHelpers.shimmerGradient(for: viewModel.inputBarState)
        )
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(0.35)
    )
}

/// The field is editable in `.ready` (user is composing) and in
/// `.thoughtRecall` (later task — user can type over the recall prompt).
/// Every other state shows the status label.
private func isEditable(_ state: InputBarState) -> Bool {
    switch state {
    case .ready, .thoughtRecall: return true
    default: return false
    }
}
```

**IMPORTANT:** The current file likely has the `TextField` and its modifiers (including `.onKeyPress` handlers for up/down/tab/return/escape for the slash dropdown). Preserve those modifiers verbatim — only the outer `if`/`else` branching is new.

### 5c. Later-task card section

Add, below the `slashSuggestions` block, above `if let turn = viewModel.conversation.last`:

```swift
// MARK: - State-driven cards (T7/T8/… placeholders)
stateDrivenSection
```

Then:

```swift
@ViewBuilder
private var stateDrivenSection: some View {
    switch viewModel.inputBarState {
    case .researchChoice:
        // TODO: T7 — research choice buttons (Executer:
        // InputBarView.researchChoiceButtons(query:))
        EmptyView()
    case .browserChoice:
        // TODO: T7 — browser visibility choice buttons.
        EmptyView()
    case .thoughtRecall:
        // TODO: T8 — ThoughtRecallCard.
        EmptyView()
    case .newsBriefing:
        // TODO: T9 — NewsBriefingCard.
        EmptyView()
    case .coworkingSuggestion:
        // TODO: T10 — CoworkingSuggestionCard.
        EmptyView()
    case .healthCard:
        // TODO: T11 — health check card.
        EmptyView()
    case .voiceListening:
        // TODO: T6 — voice listening indicator (partial transcript row).
        EmptyView()
    case .ready, .processing, .planning, .executing, .streaming,
         .result, .error:
        EmptyView()
    }
}
```

### 5d. Ride the existing spring for state transitions

On the top-level `.animation(Self.fluidSpring, value: …)` chain, add:
```swift
.animation(Self.fluidSpring, value: viewModel.inputBarState)
```

### 5e. Keep `trailingControl` as-is

`trailingControl` reads `viewModel.isProcessing` (now a computed var). Behaviour preserved because `isProcessing` still flips true for `.processing`/`.planning`/`.executing`/`.streaming`.

---

## 6. Shimmer overlay — `ShimmerOverlay.swift`

Path: `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ShimmerOverlay.swift`

```swift
import SwiftUI

/// Animated rainbow gradient sweeping across the command-bar pill.
///
/// Ported from Executer's `ShimmerView` with two changes:
///   1. Colors and activity are injected, not baked in — lets the caller
///      vary the palette per `InputBarState`.
///   2. Respects `@Environment(\.accessibilityReduceMotion)` — when
///      reduce-motion is on, we render a flat static gradient (still
///      visible so the shimmer-means-working affordance is preserved)
///      and skip the `repeatForever` animation.
struct ShimmerOverlay: View {
    /// Drives whether the sweep animates. When `false`, the view renders
    /// a transparent fallback. Flips at state-machine transitions;
    /// SwiftUI's structural identity gives us clean start/stop without
    /// manual teardown.
    var isActive: Bool
    var colors: [Color]
    var animationSpeed: Double = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1.0

    var body: some View {
        if isActive {
            GeometryReader { geo in
                LinearGradient(
                    colors: colors,
                    startPoint: UnitPoint(x: reduceMotion ? 0.2 : phase, y: 0.5),
                    endPoint: UnitPoint(x: reduceMotion ? 0.8 : phase + 0.6, y: 0.5)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .onAppear {
                guard !reduceMotion else { return }
                phase = -1.0
                let duration = max(0.5, 2.5 / animationSpeed)
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
            .onDisappear {
                phase = -1.0
            }
        } else {
            Color.clear
        }
    }
}
```

---

## 7. Deletion list

Nothing gets deleted in T1.

- `SiriOrbView.swift` — **keep**. It's no longer referenced from `NotchCommandBarView` but may be used elsewhere; removing it is a follow-up.
- Do **NOT** remove `viewModel.isProcessing` — it's read from 6+ external sites. Converting `@Published var` → computed `var` is the full change.

---

## 8. Risks & open questions

**ASK before guessing:**

1. **`AgentDisplayEvent.streaming(...)` is never emitted by AgentLoop today.** The loop only publishes `progressSink.streamingToken`. The plan wires BOTH paths — `streamingToken` synthesises `.streaming(partialText:)` in the progress-sink handler, AND the display-sink `.streaming` case is kept for future use. If the real enum lacks `.streaming`, omit that arm.

2. **`.ready` is never emitted by AgentLoop.** It exists in `AgentDisplayEvent` but the loop never calls `.emit(.ready)`. The plan sets `.ready` in two places in the VM instead.

3. **`toolStarted(name)` does not carry step/total.** The display sink's `.executing(toolName, step, total)` DOES. **Recommendation:** rely on the display-sink `.executing` as the authoritative source (it has real counts) and have the progress-sink `toolStarted` handler adopt the tool name only. The plan wires both; if a conflict emerges, prefer the display sink.

4. **No existing reduce-motion helper.** Use `@Environment(\.accessibilityReduceMotion)` directly.

5. **`isProcessing` as a computed var may break Combine subscribers.** If any code uses `viewModel.$isProcessing` (the Publisher), it BREAKS. Grep confirms no such usage exists in Metamorphia today. If found, rewrite to `$inputBarState.map { … }`.

6. **Terminal state race between progress sink and display sink.** The plan makes the display sink authoritative.

7. **No `HumorMode` / `PersonalityEngine`.** Plan emits plain strings. If localization or personality is wanted, flag it.

8. **Rounded corner radius of the pill.** Plan uses 14pt; if the existing pill background uses a different radius, match it.

---

## 9. Out of scope (must not touch)

- `ResultBubbleView` / any result bubble — later task.
- Voice listening UI (mic input row, partial transcript display) — T6.
- Research / browser choice cards — T7.
- Thought recall card — T8.
- News briefing card — T9.
- Coworking suggestion card — T10.
- Health card — T11.
- `RichResult`, `AgentTrace`, `ThoughtRecall`, `NewsBriefingArticle`, `CoworkingSuggestion` types — NOT ported; the enum uses `String`/`[String]` placeholder payloads.
- `HumorMode` / `PersonalityEngine` — not ported.
- `MetamorphiaAgentKit` sink protocols — no edits. Use existing events only.
- `SiriOrbView.swift` — no delete, no edit.
- `CommandBarCoordinator.swift` — no edits.
- All six external `isProcessing` readers — no edits; they keep working via the computed accessor.

---

## 10. Test / verification plan

**Build:**
- `xcodebuild -scheme Metamorphia -configuration Debug -destination 'platform=macOS' build`
- Expect zero errors, no new warnings.

**Manual smoke test:**
1. Launch, `⌘⇧Space`. Expect: `sparkle` icon, empty field, no shimmer.
2. Type `hello` — state = `.ready`, no shimmer.
3. Submit a prompt that does NOT call a tool. Expect: icon flips `brain` → `text.bubble` as tokens arrive, shimmer visible; terminal: green `checkmark.circle.fill`, shimmer stops.
4. Prompt that triggers a tool. Expect: `list.bullet.clipboard` (planning) briefly, then `gearshape.2` (executing) with "Running <tool>… (1/N)", shimmer visible.
5. Press stop mid-run. Expect: icon back to `sparkle`, shimmer stops, field editable.
6. Induce an error. Expect: `xmark.circle.fill` red, shimmer stops, error in status slot.
7. Toggle System Settings → Accessibility → Reduce Motion. Repeat step 3. Expect: static gradient, no sweep.
8. Verify external consumers: `NotchMinimizedView` pulse still flips blue during a run; `MetamorphiaHeader` still behaves; `AgentRunningLiveActivity` still starts.

**Unit-level sanity (optional):** tests for `statusText(for:)` and `isShimmering(_:)`.
