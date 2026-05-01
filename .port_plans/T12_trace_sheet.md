# T12 — Trace Sheet Port

## Executive Summary

**Surprise finding**: `AgentTrace`, `TraceEntry`, `TraceEntryKind`, `TraceRedactor` all already exist in `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/Core/AgentTrace.swift` — AND `AgentLoop.submit` already accepts a `trace: AgentTrace?` parameter that it populates with `.llmCall`, `.toolCall`, `.error`, and terminal `finalOutcome`. `AgentLoop.Outcome.trace` returns the populated snapshot.

So T12 collapses to three concrete app-side changes:

1. Build `AgentTrace` in `AICommandViewModel.submit`, pass to `loop.submit(..., trace:)`, snapshot `outcome.trace` onto the completing `Turn`.
2. Build `AgentTraceCard.swift` — SwiftUI modal replacing `BubbleTracePlaceholderView`. Flat Metamorphia styling (no `liquidGlass`), inline timeline row (no `TraceTimelineRow` dep), copy-as-markdown + copy-as-JSON.
3. Widen `ResultBubbleView`/`ErrorBubbleView` inits to accept `trace: AgentTrace?`. Gate trace button on `trace != nil` (drop the mid-run agentTree-only path). Wire through `TranscriptView`. Delete `BubbleTracePlaceholderView.swift`.

**Non-goals:** persistence (trace stays in-memory on Turn; not added to `PersistedTurn`), export to file, filtering UI, live mid-run refresh.

## 1. File list

**Create:**
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/AgentTraceCard.swift`

**Edit:**
- `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResultBubbleView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ErrorBubbleView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/TranscriptView.swift`

**Delete:**
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/BubbleTracePlaceholderView.swift` (after swapping both callsites)

**Untouched:** `ConversationPersistenceService.swift` (no persistence), `Packages/MetamorphiaAgentKit/.../AgentTrace.swift` (already complete), `AgentTreeView.swift` (tree remains live-run-only).

## 2. `AgentTrace` already done

Existing `AgentTrace` in the package satisfies everything:
- All 11 `TraceEntryKind` cases
- `Outcome.success / .failure(String) / .cancelled`
- Thread-safe append via `NSLock`
- `formattedString()` for markdown copy (uses TraceRedactor)
- Computed helpers: `duration`, `toolCallCount`, `formattedDuration`, `llmCallCount`, `errorEntries`
- `public final class ... @unchecked Sendable`
- No Codable (intentional)

**Only 4 of 11 kinds fire today** from AgentLoop (`.llmCall`, `.toolCall`, `.error`, terminal `finalOutcome`). Others will populate as Metamorphia's loop grows. Card gracefully hides empty sections.

## 3. `AgentTraceCard.swift` — new file

Full file body: see planner output. Key design deltas from Executer:
- No `liquidGlass` — use `RoundedRectangle` + strokeBorder
- Inline timeline row (colored dot + relative timestamp + summary) — no `TraceTimelineRow` dep
- Two copy buttons: `doc.on.doc` = markdown via `trace.formattedString()`, `curlybraces` = JSON via hand-rolled `traceAsJSON(...)` (since trace isn't Codable)
- Sections: outcome badge header, summary stat badges, Plan (if any), Tool Calls (expandable rows with args/result), LLM Reasoning (if any), Errors, Full Timeline
- 440×540 sheet size, dark background (Color.black.opacity(0.86)), accent-tinted stroke (red for failed, blue otherwise)
- TraceRedactor wrapped around all user-visible strings

Full source reproduced in planner output (§3). Coder to copy verbatim.

## 4. VM changes

### 4.1 Extend `Turn`

```swift
public var trace: AgentTrace?

public init(
    id: UUID = UUID(),
    prompt: String,
    result: String,
    toolPills: [ToolCallPill],
    isStreaming: Bool,
    richContent: RichTurnContent? = nil,
    isStaged: Bool = false,
    isError: Bool = false,
    trace: AgentTrace? = nil
) {
    // ... set each including self.trace = trace
}
```

### 4.2 Construct trace + pass to loop + capture outcome

In `submit(...)`, replace the `loop.submit(command:systemPrompt:previousMessages:)` call:

```swift
let runTrace = AgentTrace(goal: commandWithAttachments)

let outcome = await loop.submit(
    command: commandWithAttachments,
    systemPrompt: primedPrompt,
    previousMessages: priorMessages,
    trace: runTrace
)
```

**NOTE TO CODER:** Verify `AgentLoop.submit` signature in `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/Core/AgentLoop.swift` — the planner confirms it accepts `trace: AgentTrace?` today. If the signature differs, match it.

After the loop returns, where `conversation[idx].result = outcome.text` etc., also set:

```swift
conversation[idx].trace = outcome.trace
```

### 4.3 Hydration — leave trace nil

In the `Turn(...)` construction from `PersistedTurn` during init, do NOT pass `trace:`. Hydrated turns stay `trace: nil`, which correctly disables the trace button for pre-restart turns.

### 4.4 No changes needed in

- `submitSilent` (staged responses correctly trace-less)
- `cancel()` (loop assigns `.cancelled` to trace automatically; partial trace flows through normal capture path)
- `clearConversation` (traces live on Turn; cleared automatically)

## 5. `ResultBubbleView` changes

Add `trace: AgentTrace?` property + init param. Gate trace button strictly on `trace != nil` (drop the mid-run `agentTree`-only path — the live tree is already visible in the notch).

```swift
let trace: AgentTrace?

init(
    message: String,
    trace: AgentTrace?,
    agentTree: AgentTreeSnapshot?,
    isLive: Bool = true,
    autoDismiss: Bool = true,
    onDismiss: @escaping () -> Void
) { /* ... */ }
```

Button guard:
```swift
if trace != nil {
    Button { showTraceSheet = true } label: { /* existing icon */ }
}
```

Sheet body replaces placeholder:
```swift
.sheet(isPresented: $showTraceSheet) {
    if let trace {
        AgentTraceCard(trace: trace, onDismiss: { showTraceSheet = false })
    }
}
```

## 6. `ErrorBubbleView` changes

Mirror ResultBubbleView:
- Add `trace: AgentTrace?` property + init param
- Replace `if isLive, agentTree != nil` with `if trace != nil`
- Replace `BubbleTracePlaceholderView` sheet content with `AgentTraceCard`

## 7. `TranscriptView` changes

Pass `trace: turn.trace` through to both bubbles (plus existing `agentTree: isLive ? viewModel.agentTree : nil`).

```swift
ResultBubbleView(
    message: message,
    trace: turn.trace,
    agentTree: isLive ? viewModel.agentTree : nil,
    isLive: isLive,
    autoDismiss: isLive && viewModel.conversation.count == 1,
    onDismiss: { viewModel.clearConversation() }
)

ErrorBubbleView(
    message: message,
    trace: turn.trace,
    agentTree: isLive ? viewModel.agentTree : nil,
    isLive: isLive,
    onDismiss: { viewModel.clearConversation() }
)
```

## 8. Delete `BubbleTracePlaceholderView.swift`

After the two callsites are swapped, grep to confirm no other refs, then delete the file.

## 9. Risks & mitigations

a. **Which events fire?** Only `.llmCall`, `.toolCall`, `.error`, and terminal `finalOutcome`. Card gracefully handles empty sections (e.g., `if trace.planOutput != nil { planSection }`).
b. **Memory cost of long runs.** No cap today. 500 entries at ~1KB = 500KB, acceptable. Add cap in follow-up if field reports show OOM.
c. **Mid-run trace.** Gate strictly on `trace != nil`. Past-turns always have it; live turns use the notch tree instead. No partial trace view.
d. **Sheet size.** 440×540 against ~640pt notch width — fits centered.
e. **Sendable.** `AgentTrace` is `final class @unchecked Sendable` + internal lock. Safe across Task.detached.
f. **Staged response.** `consumeStagedResponse` inserts Turn with no trace. Button hidden. Correct.

## 10. Out of scope

- Persistence across relaunch
- File export
- Filtering UI
- Wiring additional `TraceEntryKind` events beyond what AgentLoop emits

## 11. Test plan

- **Simple no-tool prompt**: 1 `.llmCall`, `.success`. Card renders summary + empty Tool Calls (collapsed).
- **Tool-heavy prompt**: Multiple `.llmCall` + `.toolCall`. Expand Tool Calls, verify args/result pretty-print, TraceRedactor scrubs secrets.
- **Failed tool**: Red X icon, Errors section, red outcome badge.
- **Cancel mid-run**: `.cancelled` outcome, partial trace preserved on Turn.
- **Past-turn trace**: Send 3 prompts, open trace on turn 1 — correct per-turn trace (not last-trace-wins).
- **Past-turn across restart**: Force-quit + relaunch. Hydrated turn has `trace == nil`, button absent.
- **Copy JSON**: Valid JSON, ISO 8601 timestamps, redactions applied.
- **Copy markdown**: `formattedString()` output with timeline.

## 12. Implementation order

1. Extend `Turn` with `trace: AgentTrace?`.
2. Construct `AgentTrace` in `submit(...)`, pass to `loop.submit`, capture `outcome.trace`.
3. Create `AgentTraceCard.swift`.
4. Widen `ResultBubbleView` and `ErrorBubbleView` inits; swap sheet content.
5. Pass `turn.trace` in `TranscriptView`.
6. Delete `BubbleTracePlaceholderView.swift`.
7. Build + manual test.

Full `AgentTraceCard.swift` body (see planner output) — copy verbatim with any `@available` guards needed for the platform.
