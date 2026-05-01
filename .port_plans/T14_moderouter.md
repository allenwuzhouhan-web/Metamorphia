# T14 — Port ModeRouter into Metamorphia

## Executive summary

Port Executer's `ModeRouter` — a slash-prefixed dispatcher that intercepts `/<keyword> <args>` BEFORE the normal agent pipeline and routes to pluggable "mode" handlers. Metamorphia already has a `SlashCommandParser` for skill dropdown completion; ModeRouter is orthogonal and takes first pass. If the first token matches a registered mode, the mode handles the turn (potentially submitting its own prompt back through the agent) and `submit` early-exits. Otherwise control falls through to the existing `SlashCommandParser` / `injectSkillBodies` / `primedPrompt` / `loop.submit` pipeline untouched.

Three new Swift files land under `Metamorphia/components/Modes/`: `MetamorphiaMode.swift` (protocol), `ModeRouter.swift` (parser + registry + dispatch), `LearningMode.swift` (stub that builds a learning-mode system prompt and re-enters `AICommandViewModel.submit`).

## 1. File list

**New:**
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/Modes/MetamorphiaMode.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/Modes/ModeRouter.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/Modes/LearningMode.swift`

**Edit:**
- `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift` — add router hook at top of `submit(...)` + `showModeError` helper.

No pbxproj edit needed: Metamorphia uses `PBXFileSystemSynchronizedRootGroup`, so new files under `Metamorphia/` auto-compile.

## 2. `MetamorphiaMode.swift`

```swift
import Foundation

@MainActor
public protocol MetamorphiaMode {
    static var slashKeyword: String { get }
    static func handle(argument: String, viewModel: AICommandViewModel) async
}
```

## 3. `ModeRouter.swift`

```swift
import Foundation

@MainActor
public enum ModeRouter {

    public struct ParsedCommand: Equatable {
        public let modeName: String
        public let argument: String
    }

    public static func parse(_ input: String) -> ParsedCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let withoutSlash = String(trimmed.dropFirst())
        guard let splitIndex = withoutSlash.firstIndex(where: { $0.isWhitespace }) else {
            return ParsedCommand(modeName: withoutSlash.lowercased(), argument: "")
        }
        let name = String(withoutSlash[..<splitIndex]).lowercased()
        let arg = String(withoutSlash[withoutSlash.index(after: splitIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedCommand(modeName: name, argument: arg)
    }

    private static let handlers: [String: any MetamorphiaMode.Type] = [
        LearningMode.slashKeyword: LearningMode.self,
    ]

    public static func registeredModes() -> [String] {
        handlers.keys.sorted()
    }

    public static func isKnownMode(_ name: String) -> Bool {
        handlers[name.lowercased()] != nil
    }

    @discardableResult
    public static func tryHandle(_ input: String, viewModel: AICommandViewModel) async -> Bool {
        guard let parsed = parse(input) else { return false }
        guard let modeType = handlers[parsed.modeName] else { return false }
        await modeType.handle(argument: parsed.argument, viewModel: viewModel)
        return true
    }
}
```

## 4. `LearningMode.swift`

```swift
import Foundation

public enum LearningMode: MetamorphiaMode {

    public static let slashKeyword = "learning"

    public static func handle(argument: String, viewModel: AICommandViewModel) async {
        let topic = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            viewModel.showModeError("Give a topic, e.g. /learning krebs cycle")
            return
        }
        let systemPrompt = """
        You are Metamorphia Learning Mode. Build a thorough, well-structured \
        explanation of: \(topic). Use markdown headings, numbered sections, \
        LaTeX for any math, code blocks for examples. Aim for ~500-800 words.
        """
        await viewModel.submit(prompt: topic, systemPrompt: systemPrompt)
    }
}
```

## 5. `AICommandViewModel.swift` edits

**Edit A — router hook at top of `submit(prompt:systemPrompt:)`:**

Insert immediately after the empty-input guard, BEFORE any state mutation:

```swift
// ModeRouter takes first pass — if input is `/<keyword> <args>` and
// the keyword matches a registered mode, the mode handles the turn
// (possibly by calling back into `submit` itself) and we early-exit.
if await ModeRouter.tryHandle(prompt, viewModel: self) {
    return
}
```

**Edit B — add `showModeError` helper**, placed near `cancel()`:

```swift
@MainActor
public func showModeError(_ message: String) {
    self.errorMessage = message
    self.inputBarState = .error(message: message)
    self.currentInput = ""
}
```

## 6. Risks & mitigations

1. **Skill name collision** — if a user creates a skill named `learning`, ModeRouter wins. Documented; not addressed here.
2. **Empty argument** — covered by `showModeError`.
3. **Recursion** — `LearningMode` re-enters `submit(topic)`; topic doesn't start with `/`, so `ModeRouter.parse` returns nil and normal flow resumes.
4. **Mid-string slash** — `parse` only fires on leading `/`. Safe.
5. **Package linkage** — new files don't depend on `MetamorphiaAgentKit`.

## 7. Out of scope

- LaTeX PDF engine / document viewer / scroll monitor
- Additional modes beyond `/learning`
- Settings panel for enabling/disabling modes
- Visible `/learning` tag chrome in transcript
- Reserved-keyword validation in `SkillRegistry`
- Slash-dropdown completion for mode keywords

## 8. Test plan

- `/learning photosynthesis` → agent runs with learning-mode system prompt; markdown output.
- `/learning` (no arg) → `.error("Give a topic, e.g. /learning krebs cycle")`, no agent turn.
- `/summarize report.pdf` (registered skill) → ModeRouter returns false, normal skill flow.
- `/unknownmode xyz` → ModeRouter returns false, treated as free text.
- `visit https://example.com/learning` → ModeRouter returns false, normal flow.
- Cancellation during `/learning` → `cancel()` works normally.

## 9. Implementation order

1. Create `Metamorphia/components/Modes/` directory + 3 new files.
2. Build (should pass since ModeRouter + LearningMode aren't called yet).
3. Edit `AICommandViewModel.swift` (hook + `showModeError`).
4. Build + manual test.
