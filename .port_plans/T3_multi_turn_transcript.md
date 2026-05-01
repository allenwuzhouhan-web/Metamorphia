# T3 — Multi-Turn Transcript Plan

## Executive Summary

Convert the command bar from "single live bubble" to "scrollable transcript." The FSM stays authoritative for the **live** turn only; past turns render purely from their own stored `Turn` data so they survive FSM resets.

1. Add `isError: Bool` to `Turn`. Codable field added to `PersistedTurn` with a default decoder so old `conversation.json` files load cleanly.
2. VM sets `isError = true` on the last turn inside the display sink's `.error` branch.
3. Refactor `ResultBubbleView` + `ErrorBubbleView` to new init: `(message, agentTree:, isLive:, autoDismiss:, onDismiss:)`. Auto-dismiss becomes opt-in via `autoDismiss`; trace button only rendered when `isLive`.
4. New `TranscriptView` iterates `viewModel.conversation`. Each row = `promptLabel` + body. Body chooses: live+streaming → `StreamingResponseText` (word-fade); live+terminal → `ResultBubbleView(isLive: true)` / `ErrorBubbleView(isLive: true)`; past → `ResultBubbleView(isLive: false)` / `ErrorBubbleView(isLive: false)`.
5. `ScrollViewReader` + `.scrollTo(turn.id, anchor: .bottom)` on count-change and on streaming tail growth.
6. `NotchCommandBarView` replaces its terminal-state bubble block with `TranscriptView(viewModel: viewModel)`. Dynamic height / `CommandBarContentHeightKey` stays at the outer VStack.
7. `isResponseCompacted` becomes a `frame(maxHeight:)` modifier on the transcript (44pt when compacted, 440pt otherwise).
8. "Clear" text-button top-right when `conversation.count >= 2`, calls `viewModel.clearConversation()`.
9. Auto-dismiss only fires for live turn when `conversation.count == 1` (disabled once a transcript exists).
10. **Critical `isLive` computation**: `isLive = isLast && hasActiveFSM` where `hasActiveFSM = !(inputBarState == .ready)`. Prevents hydrated-on-launch past turns from rendering with rainbow glow as if live.

---

## 1. File list

### Create
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/TranscriptView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/StreamingResponseText.swift` — extract private streaming structs from `NotchCommandBarView.swift`, promote to `internal`.

### Edit
- `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/services/ConversationPersistenceService.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResultBubbleView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ErrorBubbleView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift`

---

## 2. `Turn` struct changes

File: `AICommandViewModel.swift`

Add `isError: Bool = false` to `Turn`:

```swift
public struct Turn: Identifiable {
    public let id: UUID
    public let prompt: String
    public var result: String
    public var toolPills: [ToolCallPill]
    public var isStreaming: Bool
    public var richContent: RichTurnContent?
    public var isStaged: Bool
    /// True when the agent run for this turn terminated in `.error`.
    /// Drives per-turn bubble selection in the transcript so past error
    /// turns keep rendering as errors after the FSM has returned to `.ready`.
    public var isError: Bool

    public init(
        id: UUID = UUID(),
        prompt: String,
        result: String,
        toolPills: [ToolCallPill],
        isStreaming: Bool,
        richContent: RichTurnContent? = nil,
        isStaged: Bool = false,
        isError: Bool = false
    ) {
        self.id = id
        self.prompt = prompt
        self.result = result
        self.toolPills = toolPills
        self.isStreaming = isStreaming
        self.richContent = richContent
        self.isStaged = isStaged
        self.isError = isError
    }
}
```

Existing `submit(...)` and `consumeStagedResponse()` call sites take the default — no edits needed.

### Persistence — `PersistedTurn`

File: `ConversationPersistenceService.swift`

Add `isError` with a custom `init(from:)` defaulting to `false`:

```swift
public struct PersistedTurn: Codable, Sendable, Potentiated {
    public let id: UUID
    public let prompt: String
    public var result: String
    public var toolPills: [PersistedPill]
    public var isError: Bool
    public var strength: SynapticStrength
    public var lastAccessed: Date
    public var accessCount: Int
    public let createdAt: Date

    public static var decayTau: TimeInterval { SynapseDefaults.tauEpisodic }

    private enum CodingKeys: String, CodingKey {
        case id, prompt, result, toolPills, isError,
             strength, lastAccessed, accessCount, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.result = try c.decode(String.self, forKey: .result)
        self.toolPills = try c.decode([PersistedPill].self, forKey: .toolPills)
        // Default `false` so files written before T3 decode cleanly.
        self.isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        self.strength = try c.decode(SynapticStrength.self, forKey: .strength)
        self.lastAccessed = try c.decode(Date.self, forKey: .lastAccessed)
        self.accessCount = try c.decode(Int.self, forKey: .accessCount)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public init(
        id: UUID, prompt: String, result: String,
        toolPills: [PersistedPill], isError: Bool = false,
        strength: SynapticStrength, lastAccessed: Date,
        accessCount: Int, createdAt: Date
    ) {
        self.id = id; self.prompt = prompt; self.result = result
        self.toolPills = toolPills; self.isError = isError
        self.strength = strength; self.lastAccessed = lastAccessed
        self.accessCount = accessCount; self.createdAt = createdAt
    }
}
```

In `record(turns:)` propagate `isError`:
```swift
// Update branch:
existing.isError = live.isError

// Insert branch:
return PersistedTurn(
    id: live.id, prompt: live.prompt, result: live.result,
    toolPills: pills, isError: live.isError,
    strength: SynapticStrength(SynapseDefaults.baseline),
    lastAccessed: now, accessCount: 0, createdAt: now
)
```

In `AICommandViewModel.init(...)` hydration `map`:
```swift
.map { stored in
    Turn(
        id: stored.id,
        prompt: stored.prompt,
        result: stored.result,
        toolPills: stored.toolPills.map { p in
            ToolCallPill(
                id: p.id, toolName: p.toolName,
                stepIndex: p.stepIndex, totalSteps: p.totalSteps,
                isComplete: p.isComplete, isSuccess: p.isSuccess
            )
        },
        isStreaming: false,
        isError: stored.isError
    )
}
```

---

## 3. VM sink changes

File: `AICommandViewModel.swift`, display sink:

```swift
case .error(let msg):
    self.errorMessage = msg
    if let idx = self.conversation.indices.last {
        self.conversation[idx].isError = true
        self.conversation[idx].isStreaming = false
        if self.conversation[idx].result.isEmpty {
            self.conversation[idx].result = msg
        }
    }
    self.inputBarState = .error(message: msg)
    self.streamingBuffer = ""

case .result(let text):
    if let idx = self.conversation.indices.last {
        self.conversation[idx].result = text
        self.conversation[idx].isStreaming = false
        self.conversation[idx].isError = false   // defensively clear
    }
    self.inputBarState = .result(message: text)
    self.streamingBuffer = ""
```

`.cancelled` stays untouched.

---

## 4. Refactor `ResultBubbleView` + `ErrorBubbleView`

### `ResultBubbleView`

Widen init:

```swift
struct ResultBubbleView: View {
    let message: String
    let agentTree: AgentTreeSnapshot?
    let isLive: Bool
    let autoDismiss: Bool
    let onDismiss: () -> Void

    init(
        message: String,
        agentTree: AgentTreeSnapshot?,
        isLive: Bool = true,
        autoDismiss: Bool = true,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.agentTree = agentTree
        self.isLive = isLive
        self.autoDismiss = autoDismiss
        self.onDismiss = onDismiss
    }
    // body unchanged except gates below
}
```

Gates:

```swift
// Glow — live only
.overlay {
    if isLive {
        ResponseGlowView(cornerRadius: 12).allowsHitTesting(false)
    }
}

// Haptic + typewriter — live only
.onAppear {
    if isLive {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if message.count < 100 { startTypewriter(message) }
    } else {
        typewriterText = message  // full text immediately
    }
}

// Dismiss button — live only
if isLive {
    Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") ... }
}
// Trace button — live only
if isLive, agentTree != nil {
    Button { showTraceSheet = true } label: { Image(systemName: "info.circle") ... }
}

// Auto-dismiss
.task(id: AutoDismissKey(message: message, isHovering: isHoveringResult)) {
    guard isLive, autoDismiss else { return }
    guard message.count < 30 else { return }
    guard !isHoveringResult else { return }
    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
    if !Task.isCancelled, !isHoveringResult {
        onDismiss()
    }
}
```

### `ErrorBubbleView`

```swift
struct ErrorBubbleView: View {
    let message: String
    let agentTree: AgentTreeSnapshot?
    let isLive: Bool
    let onDismiss: () -> Void

    init(
        message: String,
        agentTree: AgentTreeSnapshot?,
        isLive: Bool = true,
        onDismiss: @escaping () -> Void
    ) { /* … */ }
    // dismiss/trace/haptic gated on isLive; copy button stays for all
}
```

---

## 5. New `TranscriptView`

File: `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/TranscriptView.swift`

```swift
import SwiftUI

struct TranscriptView: View {
    @ObservedObject var viewModel: AICommandViewModel

    /// FSM is in any non-ready state = the last turn is "live".
    private var hasActiveFSM: Bool {
        switch viewModel.inputBarState {
        case .ready: return false
        default: return true
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.conversation.count >= 2 {
                    clearHeader
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(viewModel.conversation.enumerated()), id: \.element.id) { idx, turn in
                            turnRow(turn: turn, isLast: idx == viewModel.conversation.count - 1)
                                .id(turn.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: viewModel.isResponseCompacted ? 44 : 440)
            }
            .onChange(of: viewModel.conversation.count) { _, _ in
                if let last = viewModel.conversation.last {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.conversation.last?.result ?? "") { _, _ in
                guard let last = viewModel.conversation.last, last.isStreaming else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.conversation.last?.isStreaming ?? false) { _, stillStreaming in
                if !stillStreaming, let last = viewModel.conversation.last {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var clearHeader: some View {
        HStack {
            Spacer()
            Button {
                viewModel.clearConversation()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .medium))
                    Text("Clear")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Clear conversation")
        }
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    @ViewBuilder
    private func turnRow(turn: AICommandViewModel.Turn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            promptLabel(turn.prompt)
            bubble(turn: turn, isLast: isLast)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func promptLabel(_ prompt: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "text.bubble")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 2)
            Text(prompt)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func bubble(turn: AICommandViewModel.Turn, isLast: Bool) -> some View {
        let isLive = isLast && hasActiveFSM
        let isErrorTurn = turn.isError ||
            (isLive && { if case .error = viewModel.inputBarState { return true } else { return false } }())

        if isLive && turn.isStreaming {
            liveStreamingBody(turn: turn)
        } else if isErrorTurn {
            let message: String = {
                if isLive, case .error(let m) = viewModel.inputBarState { return m }
                return turn.result
            }()
            ErrorBubbleView(
                message: message,
                agentTree: isLive ? viewModel.agentTree : nil,
                isLive: isLive,
                onDismiss: { viewModel.clearConversation() }
            )
        } else {
            let message: String = {
                if isLive, case .result(let m) = viewModel.inputBarState { return m }
                return turn.result
            }()
            if message.isEmpty, !isLive {
                EmptyView()
            } else {
                ResultBubbleView(
                    message: message,
                    agentTree: isLive ? viewModel.agentTree : nil,
                    isLive: isLive,
                    autoDismiss: isLive && viewModel.conversation.count == 1,
                    onDismiss: { viewModel.clearConversation() }
                )
            }
        }
    }

    @ViewBuilder
    private func liveStreamingBody(turn: AICommandViewModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turn.result.isEmpty {
                StreamingResponseText(text: turn.result)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !turn.toolPills.isEmpty {
                toolPillStack(turn.toolPills)
            }
            if let content = turn.richContent, case .functionGraph(let spec) = content {
                FunctionGraphView(spec: spec)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func toolPillStack(_ pills: [AICommandViewModel.ToolCallPill]) -> some View {
        HStack(spacing: 6) {
            ForEach(pills) { pill in
                ToolPillView(pill: pill)
            }
        }
    }
}
```

**Coder note:** `ToolPillView`, `StreamingResponseText`, and `CommandBarFlowLayout` currently live as private structs in `NotchCommandBarView.swift`. Move them to `StreamingResponseText.swift` and promote to `internal`. If the existing naming differs (e.g., `toolPill(_:)` is a function, not a struct), move that function too.

---

## 6. Edits to `NotchCommandBarView.swift`

Delete the current response-zone block (the `if let turn = viewModel.conversation.last { responseBody(turn:) }` and the subsequent `switch viewModel.inputBarState` that gates `ResultBubbleView` / `ErrorBubbleView`).

Replace with:

```swift
if !viewModel.conversation.isEmpty {
    TranscriptView(viewModel: viewModel)
        .padding(.top, 10)
        .transition(.opacity)
}
```

Delete:
- `responseBody(turn:)` function.
- `handleResponseScrollOffset(_:turn:)` function.
- `ResponseScrollOffsetKey` preference key.
- `StreamingResponseText` + `CommandBarFlowLayout` structs (move to new file).
- `ToolPillView` or `toolPill(_:)` (move).
- The `errorMessage` legacy footer inside the old `responseBody` (dropped entirely).

Keep:
- `inputRow`, `slashSuggestions`, `stateDrivenSection`
- `CommandBarContentHeightKey` + height measurement
- `stubWarning`, `trailingControl`, `isEditable`, `submit`, `systemPromptForContext`
- `.animation(Self.fluidSpring, value: viewModel.inputBarState)`

---

## 7. Clear button

Inside `TranscriptView.clearHeader`:
- `trash` SF Symbol + "Clear" text, pill-shaped
- `Color.white.opacity(0.05)` background, white 0.45 foreground
- `.help("Clear conversation")`
- Hidden when `conversation.count < 2`
- No confirmation

---

## 8. Scroll tests

1. Open bar. Submit prompt A. Wait for completion.
2. Submit prompt B. Transcript auto-scrolls; A remains scroll-up accessible.
3. Submit long prompt C. During streaming, auto-scrolls to keep latest tokens visible.
4. Click "Clear". Transcript empties; persisted JSON flushed.
5. Restart app with hydrated history. Past turns render, NO rainbow glow on any turn (FSM = `.ready` → `isLive = false`).
6. Induce error on last turn. ErrorBubbleView; later successful turns show ResultBubbleView chronologically.

---

## 9. Out of scope

- No new agent-loop events.
- No attachments, voice, rich result cards.
- No trace persistence for past turns.
- No user-gesture `isResponseCompacted`; offset-driven auto-compact is dropped.
- No per-turn Save-as-Skill banner.

---

## 10. Risks & open questions

**(a) Persistence migration.** `decodeIfPresent` default `false` handles legacy files. Forward-compat (old binary reading new file) is not a concern.

**(b) ScrollView inside dynamic-height notch.** `.frame(maxHeight: 440)` is a max. SwiftUI reports natural height through `CommandBarContentHeightKey`. Validate with 1 short turn that the notch stays compact.

**(c) `stateDrivenSection` placement.** Stays above the transcript.

**(d) Hydrated-on-launch glow bug.** Solved by `isLive = isLast && hasActiveFSM`.

**(e) Legacy `errorMessage` footer.** Dropped.

**(f) Auto-dismiss during transcript growth.** Adding a second turn unmounts the first bubble (`isLive: true → false`) — task cancels cleanly.

**(g) SwiftUI identity.** `id: \.element.id` (UUID) stable across mutations.

**(h) `isResponseCompacted`.** Honored at `frame(maxHeight:)`; offset-driven auto-compact dropped (intentional simplification).

---

## 11. Implementation order

1. `AICommandViewModel.swift` — add `isError` to `Turn`; update hydration; set/clear in sinks.
2. `ConversationPersistenceService.swift` — add `isError` to `PersistedTurn`; custom decoder; thread through `record(turns:)`.
3. `ResultBubbleView.swift` + `ErrorBubbleView.swift` — widen inits; gate on `isLive`.
4. Create `StreamingResponseText.swift` — move private structs; promote to `internal`.
5. Create `TranscriptView.swift`.
6. Edit `NotchCommandBarView.swift` — remove response-zone block; call `TranscriptView`; delete moved helpers.
7. Build and run scroll tests.
