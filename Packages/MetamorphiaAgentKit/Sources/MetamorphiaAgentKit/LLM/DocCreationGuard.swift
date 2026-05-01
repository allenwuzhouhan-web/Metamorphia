import Foundation

/// Hard guardrail preventing the agent from "building" a presentation by driving
/// Keynote / PowerPoint / Google Slides with GUI tools. For presentation-creation
/// intents the ONLY permitted path is `create_presentation` (+ `generate_image` or
/// `search_images` for visuals) followed by `open_file` on the returned `.pptx`.
///
/// Weaker models (DeepSeek/Kimi/Minimax) don't reliably obey prompt-level rules.
/// When the LLM issues a forbidden call during a presentation task, `executeToolCalls`
/// substitutes a synthetic "BLOCKED" result instead of running the tool.
public enum DocCreationGuard {

    // MARK: - Intent Detection

    /// Does this user command look like "please build me a presentation"?
    public static func isPresentationCreationIntent(_ command: String) -> Bool {
        let c = command.lowercased()
        let verbs = [
            "create ", "make ", "build ", "generate ", "draft ", "design ",
            "put together", "whip up", "prepare ", "write me ", "give me ",
            "i want ", "i need ",
        ]
        let nouns = [
            "presentation", "pptx", ".ppt", "powerpoint", "slide deck",
            "slides ", "slides about", "slides on", "slides for", "keynote deck",
            "deck about", "deck on", "deck for", "a deck", "new deck",
        ]
        let hasVerb = verbs.contains { c.contains($0) }
        let hasNoun = nouns.contains { c.contains($0) }
        return hasVerb && hasNoun
    }

    // MARK: - State Checks

    /// True iff `create_presentation` has already succeeded in this task's trace.
    public static func presentationAlreadyCreated(_ trace: AgentTrace?) -> Bool {
        guard let t = trace else { return false }
        return t.entries.contains { entry in
            if case .toolCall(let name, _, _, _, let success) = entry.kind,
               name == "create_presentation", success {
                return true
            }
            return false
        }
    }

    // MARK: - Block Rule

    /// Returns a non-nil block reason if this tool call should be refused.
    /// The reason string is what the LLM sees as the tool result — written to
    /// redirect the model onto the correct path.
    public static func blockReason(toolName: String, arguments: String, command: String, trace: AgentTrace?) -> String? {
        guard isPresentationCreationIntent(command) else { return nil }
        if presentationAlreadyCreated(trace) { return nil }

        let args = arguments.lowercased()
        let slideAppTokens = [
            "keynote", "powerpoint", "microsoft powerpoint", "google slides",
            "slides.google", "office.com", "onedrive", "pages",
        ]

        // 1. Block: launching a slide editor or Desmos-style web tool.
        if toolName == "launch_app" || toolName == "open_url" {
            if slideAppTokens.contains(where: { args.contains($0) }) {
                return Self.slideAppBlockMessage
            }
            let researchTokens = ["desmos", "wolfram", "geogebra", "khanacademy"]
            if researchTokens.contains(where: { args.contains($0) }) {
                return Self.researchBlockMessage
            }
        }

        // 2. Block: AppleScript / shell automation targeting slide editors.
        if toolName == "run_applescript" || toolName == "run_shell_command" {
            if slideAppTokens.contains(where: { args.contains($0) }) {
                return Self.slideAppBlockMessage
            }
        }

        // 3. Block: driving ANY app via cursor/keyboard/UI tools during creation phase.
        let guiDriverTools: Set<String> = [
            "click", "click_element", "click_ref", "drag", "scroll",
            "move_cursor", "keyboard_action", "type_text", "press_key",
            "hotkey", "explore_ui",
        ]
        if guiDriverTools.contains(toolName) {
            return Self.guiDriverBlockMessage
        }

        // 4. Block: browser sessions (web "research" loops).
        if toolName == "browser_task" || toolName == "browser_extract" || toolName == "browser_session" {
            return Self.researchBlockMessage
        }

        return nil
    }

    // MARK: - Block Messages

    public static let slideAppBlockMessage = """
        BLOCKED by DocCreationGuard. You tried to launch or drive a slide editor app, but this task \
        is "create a presentation". The ONLY correct path is:

          1. (Optional, for custom images) Call `generate_image` in PARALLEL, once per visual the deck \
             needs, each with `auto_open: false`. Z-Image-Turbo produces 1024×1024 PNGs locally in ~35s.
          2. Call `create_presentation` with a FULL JSON spec, embedding the returned local paths \
             in slide `image_path` fields (or search_images URLs in `image_url` fields).
          3. Call `open_file` on the .pptx path returned by create_presentation.

        Do NOT launch Keynote, PowerPoint, or Google Slides to build the deck by clicking. \
        `create_presentation` writes a real .pptx file to disk via a Python engine. That file \
        IS the deliverable. Keynote/PowerPoint is only allowed at step 3 to VIEW the finished file.

        Reply with the correct tool calls NOW in this response.
        """

    public static let researchBlockMessage = """
        BLOCKED by DocCreationGuard. You tried to open a browser/search tool to research a topic, \
        but this task is "create a presentation". You do NOT need Desmos, Wolfram, GeoGebra, or a \
        browser session to write slide content — use your own knowledge. If you need a specific \
        fact, use `fetch_url_content` on ONE authoritative URL (Wikipedia, official docs), not a \
        browser session.

        Call `create_presentation` directly. If the user asked for "custom images", call \
        `generate_image` in parallel first. Do NOT stall in a research loop.
        """

    public static let guiDriverBlockMessage = """
        BLOCKED by DocCreationGuard. Cursor/keyboard/click tools are forbidden during presentation \
        creation — the .pptx has not been built yet. Presentations are created by calling \
        `create_presentation` with a JSON spec, NOT by typing into a GUI app.

        Correct next step: call `create_presentation` (plus `generate_image` in parallel if the user \
        asked for custom images). Those are the only two tools you need in this response.
        """
}
