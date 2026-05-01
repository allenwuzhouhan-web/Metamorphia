import Foundation
import MetamorphiaAgentKit

/// `MetamorphiaExecutors` — the package that hosts AppKit-coupled tool implementations
/// (subprocess execution, AppleScript, document creation, FFmpeg, MCP server hosts,
/// the Learning subsystem, and the Metamorphia-native bindings shipped from the app
/// target).
///
/// In contrast to `MetamorphiaAgentKit` (zero AppKit/SwiftUI imports — pure agent loop +
/// middleware + LLM services), this package is allowed to depend on `AppKit`,
/// system frameworks, and macOS subprocesses. It compiles only on macOS.
///
/// Status: this is the **skeleton + initial executors**. The full Executer port
/// (~24 executor modules + Learning + Security + Skills + Memory + Knowledge +
/// Storage subsystems) is a multi-day effort. See
/// `_PHASE_3_EXECUTOR_IMPORT_PLAN.md` for the workflow.
public enum MetamorphiaExecutors {
    public static let version = "0.1.0"

    /// Tools currently shipped in this package. Add to the array as more
    /// executors land.
    public static let allTools: [(tool: any ToolDefinition, category: ToolCategory)] = [
        (RunAppleScriptTool(), .automation),
        (RunShellCommandTool(), .systemBash),
        (FileOperationTool(), .files),
        (FindFilesTool(), .fileSearch),

        // Single broad-search entry point. Sweeps the Retrace timeline once,
        // falls back to Spotlight for indexed-file matches when no scenes
        // surface, and applies an inferred doc-type filter so a "paper"
        // query never returns a PowerPoint or a code file. The actual
        // scene-search bridge is wired in MetamorphiaBootstrap via the
        // tool's static `search` hook.
        (RecallSceneTool(), .memory),
        (GetClipboardTextTool(), .clipboard),
        (SetClipboardTextTool(), .clipboard),
        (OpenURLTool(), .web),
        (FetchURLContentTool(), .webContent),
        (SearchWebTool(), .web),

        // Script execution — lets the agent write real programs, not just
        // shell one-liners. Categorized as systemBash so intent classification
        // surfaces them for anything "write a script" / "process data" flavored.
        (RunPythonTool(), .systemBash),
        (RunNodeTool(), .systemBash),
        (RunRubyTool(), .systemBash),

        // File content — the missing read/write/edit trio. FileOperationTool
        // covers move/copy/trash, not content.
        (ReadFileTool(), .fileContent),
        (WriteFileTool(), .fileContent),
        (EditFileTool(), .fileContent),

        // Structured HTTP — spares the LLM from curl escaping gymnastics.
        (HTTPRequestTool(), .web),

        // Market Lens — stock quotes, history, news, fundamentals, search via
        // Yahoo Finance's keyless public endpoints. No API key required;
        // delivers a consumer-grade market experience without the usual
        // API-key ceremony.
        (MarketDataTool(), .web),

        // System introspection + process control.
        (SystemInfoTool(), .systemInfo),
        (ListProcessesTool(), .systemBash),
        (KillProcessTool(), .systemBash),

        // Screen capture as a first-class tool (vs. agent composing
        // screencapture via RunShellCommandTool).
        (CaptureScreenTool(), .screenshot),

        // Semantic screen perception — bridges the Computer package's
        // ComputerLib into Metamorphia. Lets the agent read the current screen as
        // a structured tree of ref-addressable elements, query for specific
        // widgets, diff across frames, suggest actions for a goal, invoke
        // menu items without synthesizing clicks, and enumerate shortcuts.
        (ScreenPerceiveTool(), .screenPerception),
        (ScreenQueryTool(), .screenPerception),
        (ScreenDiffTool(), .screenPerception),
        (InvokeMenuTool(), .screenPerception),
        (FindElementTool(), .screenPerception),
        (SuggestActionsTool(), .screenPerception),
        (ShortcutsTool(), .screenPerception),

        // Rank 2 — ref-only delta encoding. `screen_delta` ships only the
        // added/removed/changed refs per tick, saving ~95% tokens when
        // most of the screen is unchanged. `screen_reset_session` drops
        // the cached baseline when the agent knows the screen changed
        // radically (app switch, navigation).
        (ScreenDeltaTool(), .screenPerception),
        (ScreenResetSessionTool(), .screenPerception),

        // Rank 10 — multi-display awareness. `list_displays` enumerates every
        // attached monitor; `capture_display` captures a specific one via
        // ComputerLib's per-display CGWindowListCreateImage path. Pairs with
        // the displays array on the ScreenMap emitted by `screen_perceive`.
        (ListDisplaysTool(), .screenPerception),
        (CaptureDisplayTool(), .screenPerception),

        // Rank 8 — cropped vision diffs. `vision_diff` ships only the PNG
        // of the changed region (not the full screenshot) to LLM vision
        // APIs, saving ~94% bytes on localized changes. `vision_diff_multi`
        // does the same per-display for multi-monitor setups.
        (VisionDiffTool(), .screenPerception),
        (VisionDiffMultiTool(), .screenPerception),

        // Phase 4 — capabilities that were previously dormant inside
        // ComputerLib. `browser_dom_capture` pulls the full DOM of the
        // frontmost browser locally (Safari AppleScript or CDP on
        // localhost:9222). `menu_list` enumerates every menu bar leaf of
        // the frontmost app so the agent can drive canvas-drawn apps
        // (Blender, DaVinci, CapCut) whose main windows are opaque to AX.
        // `undo_state` reports whether ⌘Z recovery is available before the
        // agent commits to a potentially regrettable action.
        (BrowserDOMCaptureTool(), .screenPerception),
        (MenuListTool(),          .screenPerception),
        (UndoStateTool(),         .screenPerception),

        // App control without an AppleScript roundtrip.
        (OpenAppTool(), .appControl),
        (QuitAppTool(), .appControl),

        // Rank 9 — Gesture & Event Synthesis. First-class programmatic
        // control of mouse and keyboard via CGEvent, bridged from
        // ComputerLib's GestureExecutor. These replace the slow AppleScript
        // `tell application "System Events" to click at {x,y}` path and
        // deliver events to apps (Electron / hardened content views) that
        // AppleScript can't reach.
        (ClickAtTool(),       .input),
        (DoubleClickAtTool(), .input),
        (RightClickAtTool(),  .input),
        (DragTool(),          .input),
        (SwipeTool(),         .input),
        (ScrollTool(),        .input),
        (LongPressTool(),     .input),
        (TypeTextTool(),      .input),
        (KeyComboTool(),      .input),
        (MoveMouseTool(),     .input),

        // Phase A — semantic, ref-addressable actions. `press` routes the
        // LLM's @eN directly to the fastest reachable path: AX action when
        // the element exposes `.press` and we can locate it live, CGEvent
        // fallback otherwise. Coordinate tools above stay as the visual /
        // OCR-only escape hatch — prefer `press` whenever the LLM has a ref.
        (PressTool(), .input),
        (TypeTool(), .input),

        // Phase B — taxonomy completion. These close the six gaps against
        // the standard computer-use tool set (zoom / switch_display / wait /
        // hold_key / middle_click / list_granted_applications) so the LLM
        // has a consistent surface across every category of action the
        // reference spec enumerates.
        (WaitTool(),                     .input),
        (HoldKeyTool(),                  .input),
        (MiddleClickTool(),              .input),
        (ZoomTool(),                     .input),
        (SwitchDisplayTool(),            .input),
        (ListGrantedApplicationsTool(),  .systemInfo),

        // Phase B module 4 — `computer_batch` runs an ordered sequence of
        // semantic actions in one feedback-suppressed span, then recaptures
        // and evaluates a post-condition. Lets the LLM describe multi-step
        // flows (open, toggle, save, close) as one verified operation
        // instead of five uncorrelated tool calls with perception ticks
        // wedged between them.
        (ComputerBatchTool(),            .input),
    ]

    /// Register every tool in `allTools` with the given registry. Call from
    /// the app target's bootstrap after constructing the `ToolRegistry`.
    public static func register(into registry: ToolRegistry) {
        registry.register(allTools)
    }

    /// Register the News tools. `news_feed` becomes available to the LLM,
    /// backed by `GoogleNewsService` and `AnonymizedNewsFetcher`. Call after
    /// `register(into:)` so the tool appears alongside the rest of the catalog.
    ///
    /// - Parameters:
    ///   - registry: The shared ``ToolRegistry`` to register into.
    ///   - storyTracker: Optional ``StoryTracker`` for Phase 4 narrative clustering.
    ///     When provided, `news_feed` calls with `"track": true` will ingest
    ///     articles into the tracker using `EntityExtractor`.
    ///   - aliasStore: Required when `storyTracker` is non-nil.
    ///   - termFrequency: Required when `storyTracker` is non-nil.
    public static func registerNewsTools(
        into registry: ToolRegistry,
        storyTracker: StoryTracker? = nil,
        aliasStore: EntityAliasStore? = nil,
        termFrequency: RollingTermFrequency? = nil
    ) {
        let tool: NewsDataTool
        if let tracker = storyTracker,
           let alias = aliasStore,
           let freq = termFrequency {
            tool = NewsDataTool(storyTracker: tracker, aliasStore: alias, termFrequency: freq)
        } else {
            tool = NewsDataTool()
        }
        registry.register([(tool, .webContent)])
    }

    /// Register the Memory tools. `store_memory` and `recall_memory` become
    /// available to the LLM, backed by the provided ``MemoryStore``. Call
    /// after `register(into:)` so these tools are alongside the rest of the
    /// tool catalog.
    ///
    /// - Parameters:
    ///   - registry: The shared ``ToolRegistry`` to register into.
    ///   - memory: The ``MemoryStore`` instance the tools will read/write.
    public static func registerMemoryTools(
        into registry: ToolRegistry,
        memory: any MemoryStore
    ) {
        registry.register([
            (StoreMemoryTool(store: memory), .memory),
            (RecallMemoryTool(store: memory), .memory),
        ])
    }

    /// Register the Skills subsystem. `search_skills` and `load_skill` become
    /// available to the LLM, backed by the provided ``SkillRegistry``. If
    /// `loadBundledSkills` is true (default), the library ships with ~10
    /// macOS-native skills copied from the package bundle.
    ///
    /// Call after `register(into:)` so skills show up alongside the rest of
    /// the tool catalog.
    public static func registerSkills(
        into registry: ToolRegistry,
        skills: SkillRegistry,
        loadBundledSkills: Bool = true
    ) {
        if loadBundledSkills, let bundled = bundledSkillsDirectory() {
            skills.loadSkills(from: bundled)
        }
        registry.register([
            (SearchSkillsTool(registry: skills), .skills),
            (LoadSkillTool(registry: skills), .skills),
        ])
    }

    /// Location of the package-bundled `Skills/` directory (MIT-licensed, ships
    /// with the binary). Returns `nil` if the resource wasn't bundled — e.g.,
    /// the app was built without SPM resource handling. Callers can pass any
    /// other directory to `SkillRegistry.loadSkills(from:)` for user-authored
    /// skills.
    public static func bundledSkillsDirectory() -> URL? {
        Bundle.module.url(forResource: "Skills", withExtension: nil)
    }
}
