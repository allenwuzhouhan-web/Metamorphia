# T13 — Port Tiered Execution Pipeline into Metamorphia

## Executive Summary

Port tier-1 local command matchers + tier-2 SmartCalculator + tier-3 FormulaDatabase. Tier-4 SmartRouter skipped.

**Ported matchers (5):**
- `TimerLocalMatcher` — wires "set a timer for 5 minutes" → existing `TimerManager.shared.startTimer`
- `NoteLocalMatcher` — "note: buy milk" → `Defaults[.savedNotes].append(NoteItem(...))`
- `DictionaryLocalMatcher` — "define X" via macOS `DCSCopyTextDefinition`
- `WebNavigationLocalMatcher` — "go to github.com" / "open twitter" via `NSWorkspace.shared.open(URL)` (narrow slice only)
- `MusicLocalMatcher` — play/pause/next/previous/shuffle via AppleScript to Music.app

**Skipped matchers (5):** AppCommand, FileCommand, Cursor, Keyboard, Window — each needs platform integrations Metamorphia doesn't own.

**Ported knowledge tiers (2):**
- `SmartCalculator.swift` — full verbatim port from Executer.
- `FormulaDatabase.swift` — full verbatim port with storage path `~/Library/Application Support/Metamorphia/formulas.json`.

**Pipeline:** flat sequential dispatcher (not protocol/registry — too much machinery for 5 matchers).

**Integration:** runs in `AICommandViewModel.submit(...)` AFTER `ModeRouter.tryHandle` and BEFORE the agent loop. On hit, append a finalized Turn (non-streaming, `.result` state), record a synthetic trace entry for T12 sheet.

**Failure mode:** fall-through. A matcher that can't actually execute returns nil; next tier (and ultimately the agent loop) still gets a shot.

## 1. File list

**Create under `/Users/allenwu/claude/metamorphia/Metamorphia/LocalCommands/`:**
1. `LocalCommandHit.swift`
2. `LocalCommandPipeline.swift`
3. `LocalCommandHelpers.swift`
4. `Matchers/TimerLocalMatcher.swift`
5. `Matchers/NoteLocalMatcher.swift`
6. `Matchers/DictionaryLocalMatcher.swift`
7. `Matchers/WebNavigationLocalMatcher.swift`
8. `Matchers/MusicLocalMatcher.swift`
9. `SmartCalculator.swift` (verbatim from Executer)
10. `FormulaDatabase.swift` (verbatim + storage path edit)

**Edit:**
- `Metamorphia/ViewModels/AICommandViewModel.swift` — add pipeline call + `finalizeLocalTurn` helper.

No pbxproj edit needed (PBXFileSystemSynchronizedRootGroup).

## 2. `LocalCommandHit`

```swift
public struct LocalCommandHit: Equatable {
    public let matcherName: String
    public let message: String
    public let arguments: String
    public let elapsed: TimeInterval

    public init(matcherName: String, message: String, arguments: String, elapsed: TimeInterval) {
        self.matcherName = matcherName
        self.message = message
        self.arguments = arguments
        self.elapsed = elapsed
    }
}
```

## 3. `LocalCommandPipeline`

Sequential dispatcher. 40-word cap on input. Clock-measured elapsed. On hit, returns `LocalCommandHit?`; on miss returns nil.

```swift
public enum LocalCommandPipeline {
    private static let maxWordCount = 40

    public static func handle(prompt: String) async -> LocalCommandHit? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        let wordCount = normalized.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount <= maxWordCount else { return nil }

        // Tier 1 — pattern matchers (cheap/specific first).
        if let hit = await TimerLocalMatcher.handle(normalized) { return hit }
        if let hit = await NoteLocalMatcher.handle(normalized) { return hit }
        if let hit = await DictionaryLocalMatcher.handle(normalized) { return hit }
        if let hit = await MusicLocalMatcher.handle(normalized) { return hit }
        if let hit = await WebNavigationLocalMatcher.handle(normalized) { return hit }

        // Tier 2 — SmartCalculator.
        if let result = SmartCalculator.evaluate(normalized) {
            return LocalCommandHit(
                matcherName: "smart_calculator",
                message: result,
                arguments: "query=\"\(normalized)\"",
                elapsed: 0
            )
        }

        // Tier 3 — FormulaDatabase.
        if let result = FormulaDatabase.shared.lookup(normalized) {
            return LocalCommandHit(
                matcherName: "formula_database",
                message: result,
                arguments: "query=\"\(normalized)\"",
                elapsed: 0
            )
        }

        return nil
    }
}
```

## 4. `LocalCommandHelpers`

Shared helpers: duration parsing (`parseCompoundDuration` with word patterns + colon patterns), percent extraction, prefix trim, AppleScript wrapper (`runAppleScript` + `escapeAppleScript`). Full source in planner output; coder to copy verbatim.

## 5. Matcher full source

All 5 matchers have full Swift source in the planner output. Summaries:

### `TimerLocalMatcher`
- Triggers: "timer", "set a timer", "remind me ... in ..."
- Requires parseable duration
- Calls `TimerManager.shared.startTimer(duration:name:preset:)` on MainActor
- Label extraction for "timer X for Y" and "remind me to Y in X"

### `NoteLocalMatcher`
- Prefixes: "note: ", "note ", "take a note ", "make a note ", "quick note "
- Rejects body if it starts with timer trigger (avoid "note: set a timer for 5 min" saving as note)
- Appends to `Defaults[.savedNotes]` on MainActor
- Title = first 40 chars

### `DictionaryLocalMatcher`
- Prefixes: "define ", "definition of ", "what does X mean", "what's the meaning of X"
- Calls `DCSCopyTextDefinition` (CoreServices)
- 3-word cap on query
- Returns nil if DCS finds no entry → falls through to LLM

### `WebNavigationLocalMatcher`
- Prefixes: "go to ", "navigate to ", "open "
- Rejects: multi-word targets, app-like tokens (chrome, vscode, etc.), "and"/"then" compound workflows
- Curated shortcut dict (twitter → x.com, gmail → mail.google.com, etc.)
- Single-word domain with dot → prefix https://
- Calls `NSWorkspace.shared.open(URL)`

### `MusicLocalMatcher`
- Exact transport keywords: pause, play, next, previous, shuffle, "what's playing", music volume
- AppleScript via `LocalCommandHelpers.runAppleScript(...)`
- Returns nil on script failure (Music.app not running, permission denied) → falls through

## 6. `SmartCalculator`

**Copy verbatim from `/Users/allenwu/claude/executer/Executer/Knowledge/SmartCalculator.swift` (744 lines).** No edits. Zero dependencies. Public surface: `SmartCalculator.evaluate(_:) -> String?`.

## 7. `FormulaDatabase`

**Copy verbatim from `/Users/allenwu/claude/executer/Executer/Knowledge/FormulaDatabase.swift` (2135 lines) with two edits:**

Storage URL — change `"Executer"` → `"Metamorphia"`:
```swift
let dir = appSupport.appendingPathComponent("Metamorphia", isDirectory: true)
```

Log line:
```swift
print("[Metamorphia.FormulaDB] Loaded \(formulas.count) formulas")
```

Everything else (the ~1000-formula built-in library, index builder, scored lookup) is byte-for-byte identical.

## 8. VM integration

### 8.1 Insertion point in `submit(...)`

After `ModeRouter.tryHandle` (T14), before any state mutation or agent-loop work:

```swift
// T13 — local command pipeline
if let hit = await LocalCommandPipeline.handle(prompt: prompt) {
    finalizeLocalTurn(hit, prompt: prompt)
    return
}

// Normal agent path unchanged below...
```

### 8.2 `finalizeLocalTurn` helper

```swift
@MainActor
private func finalizeLocalTurn(_ hit: LocalCommandHit, prompt: String) {
    let turn = Turn(
        prompt: prompt,
        result: hit.message,
        toolPills: [
            ToolCallPill(
                toolName: "local:\(hit.matcherName)",
                stepIndex: 1,
                totalSteps: 1,
                isComplete: true,
                isSuccess: true
            )
        ],
        isStreaming: false
    )
    conversation.append(turn)
    inputBarState = .result(message: hit.message)

    if AppDelegate.shared?.vm.notchState == .minimized {
        hasUnseenCompletion = true
    }
}
```

**If T12 (trace sheet) has shipped by the time T13 lands**, also attach a synthetic `AgentTrace` to the Turn:

```swift
#if canImport(MetamorphiaAgentKit)
let trace = AgentTrace(goal: prompt)
// Record a .toolCall entry using whatever API exists on AgentTrace
// (check the real type — might be `append(...)` or `record(...)`).
// Synthetic entry: name = "local:\(hit.matcherName)", success = true,
// duration = hit.elapsed, etc.
var finalTurn = turn
finalTurn.trace = trace
conversation[conversation.count - 1] = finalTurn
#endif
```

**NOTE TO CODER:** Verify actual `AgentTrace` API from `Packages/MetamorphiaAgentKit/.../AgentTrace.swift`. The method might be `append(_:)` or `record(_:)`; entries might be `TraceEntry(kind:...)`. Use what's there; don't invent.

### 8.3 Silent pre-warm

`submitSilent(_:loop:)` gets a fast path too:

```swift
public func submitSilent(_ prompt: String, loop stagingLoop: AgentLoop? = nil) async -> String {
    if let hit = await LocalCommandPipeline.handle(prompt: prompt) {
        return hit.message
    }
    // ...existing full-loop path unchanged.
}
```

## 9. Risks

1. **False positives** — mitigated by word-count caps, denylists (app-like tokens), prefix specificity, calculator/formula relevance floors.
2. **Latency** — worst case pipeline miss ~50-150ms (cold). Acceptable vs 400-3000ms LLM.
3. **MainActor hops** — TimerLocalMatcher, NoteLocalMatcher wrap side-effects; Music can stay off MainActor (defensive `runAppleScript` already sync).
4. **DCSCopyTextDefinition entitlement** — unsandboxed works fine.
5. **AppleScript permission (Music)** — first run prompts; denied → matcher falls through.
6. **Storage dir** — verify `Metamorphia/` subdir is canonical.
7. **40-word cap** — prevents runaway pasted code.
8. **Slash + pipeline interaction** — `/timer 5 minutes` falls through ModeRouter (not registered) → pipeline sees it → timer matcher matches on "timer" substring. Acceptable; slight weirdness in Turn.prompt.

## 10. Out of scope

- SmartRouter tier 4 (secondary LLM single-tool router)
- AppCommand / FileCommand / Cursor / Keyboard / Window matchers
- Volume / brightness / dark-mode / wifi / bluetooth / screenshot / trash / messaging
- Per-matcher cost budgets
- Live trace streaming
- Rich content output from matchers

## 11. Test plan

**Happy path per matcher:**
- `"set a timer for 5 minutes"` → timer
- `"note: buy milk"` → note
- `"define cromulent"` → dictionary (or nil if DCS misses)
- `"go to github.com"` → web
- `"pause"` → music
- `"50 lbs in kg"` → smart_calculator
- `"pythagorean theorem"` → formula_database

**Negative:**
- Empty / whitespace-only → nil
- >40 words → nil
- `"note: set a timer for 5 minutes"` → nil (note guard)
- `"open chrome"` → nil (app denylist)
- `"search for pasta recipes"` → nil (web rejects spaces)
- `"play Shape of You"` → nil (music doesn't own library)

**Integration:**
- Submit local-handled prompt → no `loop.submit` call, `conversation.count == 1`.
- Submit LLM-required prompt → `loop.submit` fires exactly once.
- ModeRouter takes precedence: `/learning X` → only ModeRouter fires, not pipeline.

## 12. Implementation sequencing

1. Create `LocalCommands/` directory.
2. `LocalCommandHit.swift`, `LocalCommandHelpers.swift`, `LocalCommandPipeline.swift`.
3. Five matcher files (any order).
4. Copy `SmartCalculator.swift` verbatim.
5. Copy `FormulaDatabase.swift` with 2 edits.
6. Patch `AICommandViewModel.submit` + `finalizeLocalTurn` helper.
7. Build + smoke test.
