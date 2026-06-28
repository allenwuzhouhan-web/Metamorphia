import Foundation
import Combine
import SwiftUI
import AppKit
#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

// T7: Research mode choice.
public enum ResearchMode: String {
    case deep = "deep"
    case light = "light"
}

/// Central view model for the AI Command Bar. Owns the conversation state,
/// holds a reference to the shared `AgentLoop`, and conforms to
/// `AgentProgressSink` + `AgentDisplayStateSink` + `AgentTreeSink` so it
/// receives live updates from the agent.
///
/// NOTE: This file imports `MetamorphiaAgentKit` via the local Swift package
/// dependency at `Packages/MetamorphiaAgentKit`.
@MainActor
public final class AICommandViewModel: ObservableObject {

    // MARK: - Conversation state

    public struct Turn: Identifiable {
        public let id: UUID
        public let prompt: String
        public var result: String
        public var toolPills: [ToolCallPill]
        public var isStreaming: Bool
        /// Optional rich payload rendered alongside `result`. Nil for every
        /// pre-existing code path — only the Market Lens flow populates it.
        /// Intentionally NOT persisted via `ConversationPersistenceService`
        /// (quote data goes stale in minutes; re-derived from
        /// `MarketQuoteMonitor` on restore).
        public var richContent: RichTurnContent?
        /// True when this turn was pre-computed by PredictiveStaging and
        /// rendered instantly on command-bar open. Drives the sparkle
        /// indicator in the response card.
        public var isStaged: Bool
        /// True when the agent run for this turn terminated in `.error`.
        /// Drives per-turn bubble selection in the transcript so past error
        /// turns keep rendering as errors after the FSM has returned to `.ready`.
        public var isError: Bool
        /// Execution trace for this turn. Set after `loop.submit` returns.
        /// Nil for hydrated (pre-restart) turns and staged responses — the
        /// trace button in both bubbles is gated strictly on `trace != nil`.
        /// Not persisted via `ConversationPersistenceService`.
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
            self.id = id
            self.prompt = prompt
            self.result = result
            self.toolPills = toolPills
            self.isStreaming = isStreaming
            self.richContent = richContent
            self.isStaged = isStaged
            self.isError = isError
            self.trace = trace
        }
    }

    public struct ToolCallPill: Identifiable {
        public let id: UUID
        public let toolName: String
        public let stepIndex: Int
        public let totalSteps: Int
        public var isComplete: Bool
        public var isSuccess: Bool

        public init(
            id: UUID = UUID(),
            toolName: String,
            stepIndex: Int,
            totalSteps: Int,
            isComplete: Bool,
            isSuccess: Bool
        ) {
            self.id = id
            self.toolName = toolName
            self.stepIndex = stepIndex
            self.totalSteps = totalSteps
            self.isComplete = isComplete
            self.isSuccess = isSuccess
        }
    }

    @Published public private(set) var conversation: [Turn] = []
    /// Turn IDs whose final displayed result was rewritten after `loop.submit`
    /// returned. The display sink may still deliver a late raw `.result`
    /// event; do not let that clobber compact document-review delivery.
    private var protectedTerminalTurnIDs: Set<UUID> = []
    @Published public var currentInput: String = "" {
        didSet {
            refreshSlashSuggestions()
            // Phase 10: if the user types something that doesn't match the
            // staged prompt, discard the stage immediately.
            // Normalize the user's input the same way the learner normalizes
            // queries so apostrophes, punctuation, and case differences don't
            // cause false invalidations (e.g. "what's new" vs "whats new").
            let trimmed = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let staged = PredictiveStaging.shared.stagedResponse {
                    let normalizedInput = QueryPatternLearner.normalize(trimmed)
                    // Keep the stage when the user is typing toward it (the
                    // staged prompt starts with what they've typed so far) OR
                    // when the first 5 chars of their normalized input match
                    // (covers the case where the staged prompt is a synonym
                    // expansion and the user starts typing the original form).
                    let keepByPrefix = staged.prompt.hasPrefix(normalizedInput)
                    let keepByLeadingChars = !normalizedInput.isEmpty &&
                        normalizedInput.hasPrefix(String(staged.prompt.prefix(5)))
                    if !keepByPrefix && !keepByLeadingChars {
                        PredictiveStaging.shared.invalidate(reason: .userTyped)
                    }
                }
            }
        }
    }
    /// Current command-bar FSM state. Authoritative source of truth for the
    /// command bar UI; `isProcessing` is now derived from this.
    @Published public private(set) var inputBarState: InputBarState = .ready {
        didSet {
            MenuBarTaskStatusStore.shared.update(from: inputBarState)
        }
    }

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
    /// Hydrated from UserDefaults on init. Written only via setActiveAgent.
    @Published public private(set) var currentAgent: AgentProfile = .general

    /// Back-compat shim for any stray reader of the old property name.
    public var currentAgentName: String { currentAgent.id }

    @Published public private(set) var learningActive: Bool = false
    @Published public private(set) var errorMessage: String?

    // MARK: - Slash command state

    /// Ranked list of skills matching the slash token the user is currently
    /// typing. Empty when the caret isn't inside a `/<token>` — that's how
    /// the command bar knows whether to render the dropdown.
    @Published public private(set) var slashSuggestions: [SkillSuggestion] = []
    /// Currently-highlighted row in the dropdown. Driven by up/down arrow
    /// key presses in the command bar. Resets to 0 on every refresh.
    @Published public var selectedSuggestionIndex: Int = 0
    /// Surfaced when the chain observer detects a long multi-skill workflow
    /// the user might want to crystallise into a named skill. Nil when no
    /// proposal is pending.
    @Published public var pendingSkillProposal: SkillProposal?

    /// Payload for the "save as skill" banner. Carries enough metadata for
    /// the UI to justify *why* the banner appeared and to pre-fill the name
    /// field.
    public struct SkillProposal: Equatable {
        public let suggestedName: String?
        public let justification: String
        /// The slash-expanded original prompt. Stored here so the skill body
        /// can reproduce the recipe verbatim when we serialize to disk.
        public let recipeBody: String
    }

    /// Short (≤32 char) live status label that replaces the static
    /// "Thinking…" string while the agent is mid-run. Nil when idle. See
    /// ``AgentProgressEvent.Kind.status``.
    @Published public private(set) var liveStatus: String?
    /// The full agent execution tree rendered above the response body while a
    /// turn is streaming. Nil before the first `treeStarted` and after the
    /// run terminates.
    @Published public private(set) var agentTree: AgentTreeSnapshot?
    /// Measured content height (from `CommandBarContentHeightKey`) used to
    /// drive a dynamic notch height instead of a fixed 320pt tall rectangle.
    @Published public private(set) var commandBarPreferredHeight: CGFloat = 56
    /// Extra width the command bar is asking for — grows with the size of the
    /// latest response so long answers don't get squeezed into the default
    /// notch width. `0` means "use the default notch width".
    @Published public private(set) var commandBarPreferredWidth: CGFloat = 0
    /// True when the user has scrolled up in the response area, signalling
    /// they want the notch out of the way. Drives a height cap at the notch
    /// layer so the bar collapses to a compact preview until the user scrolls
    /// back down or a new turn arrives.
    @Published public private(set) var isResponseCompacted: Bool = false
    /// Set when an agent run completes while the notch is minimized. Drives
    /// the minimized view's pulse dot color (blue pulsing → solid green).
    @Published public var hasUnseenCompletion: Bool = false

    /// Files the user has dragged onto the command bar, pending injection into
    /// the next submitted prompt. Cleared after each submission. Not persisted.
    @Published public private(set) var attachedFiles: [CommandBarAttachedFile] = []

    /// The agent-tree node whose `liveStatus` should reflect the next
    /// incoming `.status(label:)` event. For a simple AgentLoop-only run
    /// this is the root; for a `SubAgentCoordinator` run it's whichever
    /// sub-agent was most recently transitioned to `.running`.
    private var currentlyRunningNodeId: String?

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

    /// Guards against auto-exporting the same research turn twice — the
    /// terminal `.result` state can be re-entered (e.g. rich-content
    /// post-processing).
    private var lastAutoExportedTurnID: UUID?

    /// Reserved id the view model uses for the Oracle root node the agent
    /// loop opens via `treeStarted(.oracle)`.
    private static let rootNodeID = "__agent_tree_root__"

    // MARK: - T7: Research / browser-choice sentinels

    /// Bracketed prefixes that signal a re-entry from a choice card. Prompts
    /// starting with any of these skip detection so we don't recurse.
    fileprivate static let choicePrefixes: [String] = [
        "[deep research] ",
        "[light research] ",
        "[browser visible] ",
        "[browser background] ",
    ]

    fileprivate static func hasChoicePrefix(_ prompt: String) -> Bool {
        choicePrefixes.contains { prompt.hasPrefix($0) }
    }

    fileprivate static func hasResearchPrefix(_ prompt: String) -> Bool {
        prompt.hasPrefix("[deep research] ") || prompt.hasPrefix("[light research] ")
    }

    /// Shared system prompt for every submit path. Includes the current
    /// user's actual home directory and short name so the model can't
    /// invent `/Users/<random-name>/...` paths and then refuse to open
    /// files in the user's real home folder thinking it belongs to
    /// someone else.
    public static var defaultSystemPrompt: String {
        let home = NSHomeDirectory()
        let user = NSUserName()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let now = formatter.string(from: Date())
        return """
        You are Metamorphia, an AI assistant on macOS. Use the available \
        tools to fulfill the user's request. Be concise — the user sees \
        your reply in a compact bar.

        ## Fresh information
        - Do not answer time-sensitive facts from memory. If the user asks \
        for current/latest/recent/today/now facts, live office holders \
        (for example POTUS, president, prime minister, CEO), prices, \
        schedules, news, laws, or other facts that may have changed since \
        training, call `search_web` first when it is available.
        - If a needed live-data tool is unavailable, say you cannot verify \
        the current answer instead of guessing.

        ## Skills and dependencies
        - If the user asks what skills, integrations, or capabilities you \
        have, call `search_skills` when it is available before answering.
        - If the user asks for Word, Excel, PowerPoint, DOCX, XLSX, or PPTX \
        work, prefer Office-specific skills when available: `word-docx`, \
        `excel-xlsx`, and `pptx`.
        - Never combine dependency checks with installs in one command. Do \
        not use patterns like `pip show ... || pip install ...` or \
        `node -e ... || npm install ...`. Check first; if a dependency is \
        missing, ask before installing or use a no-install fallback.

        ## User context
        - macOS short name: \(user)
        - Home directory: \(home)
        - Current local date/time: \(now)
        - Treat \(home) as the user's home. Files under it belong to the \
        user — never refuse to open them claiming they belong to a \
        different user. Do not invent usernames or paths.

        ## Output formatting
        - NEVER use emojis. No exceptions, regardless of tone or topic.
        - When you mention a file by name or path, render it as a clickable \
        italic markdown link pointing at the file's `file://` URL: \
        `[*filename*](file:///absolute/path/to/file)`. Use the absolute \
        path. The italic text becomes the visible label; the URL makes it \
        open when clicked.
        - Apply this to every file reference — source files, documents, \
        folders, anything with a real path on disk. If you only know a \
        bare name with no path, still italicize it (`*filename*`) but omit \
        the link.
        """
    }

    /// Debounce work item for `updatePreferredHeight(_:)`. 80ms ≈ 12Hz,
    /// matches the existing `debouncedUpdateWindowSize` cadence at
    /// `MetamorphiaApp.swift:153-165`.
    private var preferredHeightWorkItem: DispatchWorkItem?

    /// True when this view model was constructed without a live `AgentLoop`
    /// (i.e. `MetamorphiaAgentKit` is not linked into the current build target).
    /// The command bar reads this to surface a visible warning instead of
    /// silently accepting prompts that will never be processed (fix #12).
    public let isStubMode: Bool

    /// True while a silent pre-warm run is executing via `submitSilent`.
    /// All sink callbacks check this flag and return immediately when set,
    /// preventing phantom tool pills, liveStatus flashes, and agentTree
    /// mutations on the visible conversation.
    private var isSilentRunInProgress: Bool = false

#if canImport(MetamorphiaAgentKit)
    private let loop: AgentLoop
    private let intentScorer: IntentScorer?
    private let persistence: ConversationPersistenceService?
    private let skills: SkillRegistry?
    private let userSkillsDirectory: URL?
    private var conversationSink: AnyCancellable?

    // MARK: - Continuum Phase 1: entity extraction
    private let aliasStore: EntityAliasStore
    private let entityExtractor: EntityExtractor

    public init(
        loop: AgentLoop,
        intentScorer: IntentScorer? = nil,
        persistence: ConversationPersistenceService? = nil,
        skills: SkillRegistry? = nil,
        userSkillsDirectory: URL? = nil,
        aliasStore: EntityAliasStore? = nil,
        termFrequency: RollingTermFrequency? = nil
    ) {
        self.loop = loop
        self.intentScorer = intentScorer
        self.persistence = persistence
        self.skills = skills
        self.userSkillsDirectory = userSkillsDirectory
        let store = aliasStore ?? EntityAliasStore()
        self.aliasStore = store
        let tf = termFrequency ?? RollingTermFrequency()
        self.entityExtractor = EntityExtractor(aliasStore: store, termFrequency: tf)
        self.isStubMode = false
        self.currentAgent = AgentRegistry.shared.loadPersistedActive()

        // Hydrate prior session BEFORE wiring the sink so the initial
        // assignment doesn't trigger a redundant disk write.
        if let p = persistence {
            self.conversation = p.decayedAndCapped(maxTurns: 20)
                .sorted { $0.createdAt < $1.createdAt }
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
            self.conversationSink = $conversation
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak p] turns in
                    Task { @MainActor in p?.record(turns: turns) }
                }
        }
    }

    /// Submit a prompt. Cancels any in-flight run first.
    ///
    /// Slash-command semantics: if the input contains one or more `/skill`
    /// tokens that resolve against the `SkillRegistry`, their bodies are
    /// loaded and injected into the system prompt in order, and the tokens
    /// are stripped from the user-visible prompt before it reaches the LLM.
    /// The turn's displayed prompt preserves the original (slashes included)
    /// so the conversation history reflects what the user actually typed.
    public func submit(prompt: String, systemPrompt: String) async {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if ConversationContinuationService.parseWeChatDirectMessageRequest(prompt) != nil {
            currentInput = ""
            errorMessage = nil
            inputBarState = .processing
            let outcome = await ConversationContinuationService.shared.runWeChatDirectMessageAndPlace(
                sourcePrompt: prompt
            )
            let isError: Bool
            switch outcome {
            case .failure, .needsUserInput:
                isError = true
                inputBarState = .error(message: outcome.userMessage)
            case .placed, .placedDirect, .cancelled:
                isError = false
                inputBarState = .result(message: outcome.userMessage)
            }
            conversation.append(Turn(
                prompt: prompt,
                result: outcome.userMessage,
                toolPills: [],
                isStreaming: false,
                isError: isError
            ))
            liveStatus = nil
            agentTree = nil
            return
        }

        if ConversationContinuationService.isConversationContinuationRequest(prompt) {
            currentInput = ""
            errorMessage = nil
            inputBarState = .processing
            let outcome = await ConversationContinuationService.shared.runDraftReviewAndPlace(
                sourcePrompt: prompt,
                preferredAppName: CommandBarCoordinator.shared.lastExternalAppName
            )
            let isError: Bool
            switch outcome {
            case .failure, .needsUserInput:
                isError = true
                inputBarState = .error(message: outcome.userMessage)
            case .placed, .placedDirect, .cancelled:
                isError = false
                inputBarState = .result(message: outcome.userMessage)
            }
            conversation.append(Turn(
                prompt: prompt,
                result: outcome.userMessage,
                toolPills: [],
                isStreaming: false,
                isError: isError
            ))
            liveStatus = nil
            agentTree = nil
            return
        }

        // ModeRouter takes first pass — if input is `/<keyword> <args>` and
        // the keyword matches a registered mode, the mode handles the turn
        // (possibly by calling back into `submit` itself) and we early-exit.
        if await ModeRouter.tryHandle(prompt, viewModel: self) {
            return
        }

        // T13 — local command pipeline. Runs AFTER ModeRouter, BEFORE the
        // agent loop and T7 research/browser detection. On a hit the turn is
        // finalized immediately without touching the LLM.
        if let hit = await LocalCommandPipeline.handle(prompt: prompt) {
            finalizeLocalTurn(hit, prompt: prompt)
            return
        }

        // T7: Research / browser-task detection. Runs AFTER ModeRouter so
        // `/learning research quantum tunneling` is handled as a mode, not
        // intercepted as a research card. Fast-paths out if the prompt already
        // carries a bracketed prefix (re-entry from a choice button).
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

        // Continuum Phase 10: record query pattern for predictive staging.
        // Fires before any async work so the pattern accumulates even if the
        // run is cancelled. Does not fire for the silent pre-warm path.
        QueryPatternLearner.shared.observe(query: prompt, submittedAt: .now)

        // WS-8: broadcast to activity stream so other consumers can react to
        // query submissions without coupling to QueryPatternLearner directly.
        // entityCount: 0 — entity extraction runs async below; see TODO
        if let stream = MetamorphiaBootstrap.activityStream {
            Task { await stream.emit(.querySubmitted(queryID: UUID(), entityCount: 0, at: .now)) }
        }

        // Continuum Phase 6: record every submission as a positive engagement
        // signal. Fires before any async work so the bucket for the current
        // hour accumulates the sample even if the agent run is cancelled.
        AttentionModel.shared.recordCommandBarSubmission()

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
        // New turn — if the user had compacted the bar reading the previous
        // reply, bring it back to full size so they see the fresh stream.
        if isResponseCompacted {
            isResponseCompacted = false
            if let delegate = AppDelegate.shared {
                delegate.commandBarPreferredHeightDidChange()
            }
        }

        // Parse slash tokens against the registry so skill chains expand
        // before the LLM ever sees them. Unknown tokens fall through as
        // free text — the LLM decides what they mean.
        let knownIds: Set<String> = Set(skills?.allSkills().map(\.id) ?? [])
        let resolved = SlashCommandParser.resolve(input: prompt, knownIds: knownIds)

        // The agent receives either the cleaned prose (if any) or a
        // synthetic directive naming the chain — sending just whitespace
        // to the LLM produces unhelpful replies.
        let agentPrompt: String
        if resolved.freeText.isEmpty, !resolved.skillIds.isEmpty {
            agentPrompt = "Execute the \(resolved.skillIds.joined(separator: " → ")) workflow."
        } else {
            agentPrompt = resolved.freeText.isEmpty ? prompt : resolved.freeText
        }

        // Continuum Phase 1: extract entities from this user turn before the
        // LLM call. Posts to NotificationCenter; Phase 2 (InterestGraphStore)
        // will subscribe.
        await extractAndPostEntities(from: prompt, source: .userTurn)

        // M4: pre-fetch the temporal-recall block off the async path so the
        // synchronous RetraceRecallMiddleware can read it from persistentStorage
        // on iteration 0. Suppressed when the focused field is sensitive.
        await prefetchRetraceRecall(for: agentPrompt)

        let functionSpec = FunctionDetector.detect(in: agentPrompt)
        let turn = Turn(
            prompt: prompt, result: "", toolPills: [], isStreaming: true,
            richContent: functionSpec.map { .functionGraph($0) }
        )
        conversation.append(turn)

        let chainedSystemPrompt = injectSkillBodies(
            base: systemPrompt,
            skillIds: resolved.skillIds
        )
        let agentShapedPrompt = injectAgentFragment(
            base: chainedSystemPrompt,
            agent: currentAgent
        )
        var primedPrompt = primedSystemPrompt(base: agentShapedPrompt, query: agentPrompt)
        if functionSpec != nil {
            primedPrompt += "\n\nThe user entered a mathematical function. A graph is being rendered. Briefly describe the function's shape and key properties. 2-3 sentences."
        }
        let priorMessages = persistence?.previousChatMessages() ?? []

        let commandWithAttachments: String
        var sections: [String] = [agentPrompt]
        if !attachedFiles.isEmpty {
            let cappedFiles = FileContentExtractor.enforceTotalCap(attachedFiles)
            let block = cappedFiles.map(\.formattedForPrompt).joined(separator: "\n\n")
            sections.append("""
            The user has attached the following file(s) for context:

            \(block)
            """)
            let idsToRetire = attachedFiles.map(\.id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.attachedFiles.removeAll { idsToRetire.contains($0.id) }
            }
        }
        commandWithAttachments = sections.joined(separator: "\n\n")

        let runTrace = AgentTrace(goal: commandWithAttachments)

        let outcome = await loop.submit(
            command: commandWithAttachments,
            systemPrompt: primedPrompt,
            previousMessages: priorMessages,
            trace: runTrace
        )

        if !outcome.wasCancelled, let scorer = intentScorer {
            scorer.recordOutcome(query: agentPrompt, toolsUsed: outcome.toolsUsed)
            scorer.updateSessionTools(outcome.toolsUsed)
        }

        if let idx = conversation.indices.last {
            conversation[idx].result = outcome.text
            conversation[idx].isStreaming = false
            conversation[idx].trace = outcome.trace
            // T11 — opportunistic rich-content parse. The copilot tools embed
            // a fully-resolved [PPT_DESIGN]/[PPT_REWRITE]/[DOC_REVIEW] block
            // (with restoreData/shapeSnapshots intact) in their return string;
            // the model echoes that block, and RichResultParser reconstructs
            // the bespoke result card here — Apply/Restore/Undo buttons and all.
            if conversation[idx].richContent == nil,
               let parsed = RichResultParser.parse(outcome.text) {
                conversation[idx].richContent = parsed.content
                conversation[idx].result = parsed.displayText
                protectedTerminalTurnIDs.insert(conversation[idx].id)
            }
            for pillIdx in conversation[idx].toolPills.indices {
                conversation[idx].toolPills[pillIdx].isComplete = true
            }
        }
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

        // Chain observer — surface the "save as skill" banner when this run
        // crossed the "long workflow" threshold. Runs only on successful
        // completions; we don't want to propose skills from cancelled or
        // errored runs.
        if !outcome.wasCancelled, errorMessage == nil {
            evaluateSkillProposal(
                userPrompt: prompt,
                resolvedSkillIds: resolved.skillIds,
                toolsUsed: outcome.toolsUsed
            )
        }
    }

    /// Submit a query silently — runs the full agent loop and returns the
    /// response text, but does NOT append a Turn to `conversation` and does
    /// NOT update UI state. Used by PredictiveStaging for pre-warming.
    ///
    /// - Parameter loop: The `AgentLoop` instance to use. Pass the dedicated
    ///   staging loop (not the user-facing loop) so this run cannot cancel
    ///   an in-flight user run via `cancelInFlight`.
    ///
    /// Does not record to QueryPatternLearner (the staging result itself is
    /// not a user-initiated query). Does not touch `isProcessing`.
    public func submitSilent(_ prompt: String, loop stagingLoop: AgentLoop? = nil) async -> String {
        // T13 — fast-path: if the local pipeline handles this, return immediately
        // without touching the LLM or mutating any UI state.
        if let hit = await LocalCommandPipeline.handle(prompt: prompt) {
            return hit.message
        }

        let basePrompt = Self.defaultSystemPrompt
        let systemPrompt = injectAgentFragment(base: basePrompt, agent: currentAgent)
        let agentPrompt = prompt
        let priorMessages = persistence?.previousChatMessages() ?? []
        // Raise the silent flag before submitting so every incoming sink
        // callback is suppressed for the duration of this pre-warm run.
        isSilentRunInProgress = true
        defer { isSilentRunInProgress = false }
        let targetLoop = stagingLoop ?? loop
        let outcome = await targetLoop.submit(
            command: agentPrompt,
            systemPrompt: systemPrompt,
            previousMessages: priorMessages
        )
        return outcome.text
    }

    /// Check for a valid staged response and inject it as the first turn.
    /// Called when the command bar becomes active. Returns true if a staged
    /// response was consumed and injected.
    @discardableResult
    public func consumeStagedResponse() -> Bool {
        guard let staged = PredictiveStaging.shared.consume() else { return false }
        let turn = Turn(
            prompt: staged.prompt,
            result: staged.response,
            toolPills: [],
            isStreaming: false,
            richContent: nil,
            isStaged: true
        )
        conversation.append(turn)
        return true
    }

    /// Annotate the system prompt with the IntentScorer's top predicted tool
    /// categories, formatted as confidence-tagged bullets. Soft prior — does
    /// not constrain the model.
    private func primedSystemPrompt(base: String, query: String) -> String {
        // Build the office-app soft hint once so it appears in both the early
        // return (no scored categories) and the full return below.
        let officeHint: String = {
            guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
                return ""
            }
            switch bundle {
            case "com.microsoft.Powerpoint":
                return "\n\nPowerPoint is frontmost. For simple slide-wide formatting (bold, italic, font size, color, alignment), call direct_edit. To restyle or rewrite the open slide/deck, call capture_deck first (for exact shape indices), then design_deck or rewrite_slides."
            case "com.microsoft.Word":
                return "\n\nMicrosoft Word is frontmost. To critique the open document or apply tracked comments, use review_document or edit_word_comments."
            default:
                return ""
            }
        }()

        guard let scorer = intentScorer else { return base + officeHint }
        let top = scorer.scoreIntent(query: query)
            .filter { $0.score >= 0.4 }
            .prefix(4)
        guard !top.isEmpty else { return base + officeHint }
        let bullets = top
            .map { "- \($0.category.rawValue) (confidence \(String(format: "%.2f", $0.score)))" }
            .joined(separator: "\n")
        return base + "\n\n## Likely Tool Categories\n" + bullets + officeHint
    }

    public func setActiveAgent(_ profile: AgentProfile) {
        guard profile.id != currentAgent.id else { return }
        currentAgent = profile
        AgentRegistry.shared.persistActive(profile)
    }

    public func cancel() async {
        await loop.cancelInFlight()
        inputBarState = .ready
        liveStatus = nil
        agentTree = nil
        currentlyRunningNodeId = nil
        streamingBuffer = ""
    }

    // MARK: - T13: Local command finalization

    /// Finalize a turn that was handled entirely by the local command pipeline
    /// without touching the LLM. Appends the turn to `conversation`, transitions
    /// `inputBarState` to `.result`, and attaches a synthetic `AgentTrace` so
    /// the T12 trace sheet can display the local hit.
    @MainActor
    private func finalizeLocalTurn(_ hit: LocalCommandHit, prompt: String) {
        let pill = ToolCallPill(
            toolName: "local:\(hit.matcherName)",
            stepIndex: 1,
            totalSteps: 1,
            isComplete: true,
            isSuccess: true
        )

        // Build a synthetic trace so the T12 trace button lights up.
        let trace = AgentTrace(goal: prompt)
        trace.append(TraceEntry(
            kind: .toolCall(
                name: "local:\(hit.matcherName)",
                arguments: hit.arguments,
                result: hit.message,
                durationMs: hit.elapsed * 1000,
                success: true
            )
        ))
        trace.finalOutcome = .success
        trace.endTime = Date()

        let turn = Turn(
            prompt: prompt,
            result: hit.message,
            toolPills: [pill],
            isStreaming: false,
            richContent: nil,
            isStaged: false,
            isError: false,
            trace: trace
        )
        conversation.append(turn)
        inputBarState = .result(message: hit.message)

        if AppDelegate.shared?.vm.notchState == .minimized {
            hasUnseenCompletion = true
        }
    }

    @MainActor
    public func showModeError(_ message: String) {
        self.errorMessage = message
        self.inputBarState = .error(message: message)
        self.currentInput = ""
    }

    @MainActor
    public func showModeError(_ message: String, prompt: String) {
        self.errorMessage = message
        self.inputBarState = .error(message: message)
        self.currentInput = ""

        let turn = Turn(
            prompt: prompt,
            result: message,
            toolPills: [],
            isStreaming: false,
            richContent: nil,
            isStaged: false,
            isError: true,
            trace: nil
        )
        conversation.append(turn)
        protectedTerminalTurnIDs.insert(turn.id)
        if AppDelegate.shared?.vm.notchState == .minimized {
            hasUnseenCompletion = true
        }
    }

    // MARK: - T7: Research / browser choice submission

    /// Re-submit with the user-chosen research depth. Prepends a bracketed
    /// prefix so the detection preamble fast-paths on re-entry.
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

    /// Re-submit with the user-chosen browser visibility. Prepends a bracketed
    /// prefix so the detection preamble fast-paths on re-entry.
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

    /// Dismiss the research or browser choice card and return to `.ready`.
    /// `currentInput` is NOT cleared — the user's original text survives for
    /// tweaking and re-submission.
    public func cancelChoice() {
        switch inputBarState {
        case .researchChoice, .browserChoice:
            inputBarState = .ready
        default:
            break
        }
    }

    // MARK: - Continuum Phase 1: entity extraction

    /// Extract entities from `text` and post the
    /// `continuumEntitiesExtracted` notification on the main queue.
    /// Async — awaits the entity extractor's actor hops directly.
    func extractAndPostEntities(from text: String, source: EntitySource) async {
        let entities = await entityExtractor.extract(text)
        guard !entities.isEmpty else { return }

        NotificationCenter.default.post(
            Notification.continuumEntitiesExtracted(entities: entities, source: source, text: text)
        )
    }

    // MARK: - M4: Temporal recall pre-fetch

    /// M4: Fetches the temporal-recall block via the bootstrap-wired closure and
    /// stashes it (plus the sensitivity suppress flag) into the loop's middleware
    /// persistentStorage so RetraceRecallMiddleware can read it synchronously.
    private func prefetchRetraceRecall(for query: String) async {
        // Privacy gate — never recall while a sensitive field is focused.
        let sensitive = await MetamorphiaBootstrap.focusedFieldIsSensitive()
        if sensitive {
            await loop.setMiddlewareStorage(
                [RetraceRecallMiddleware.suppressKey: true]
            )
            return
        }
        guard let fetch = MetamorphiaBootstrap.retraceRecallFetch else { return }
        guard let block = await fetch(query) else { return }
        await loop.setMiddlewareStorage(
            [RetraceRecallMiddleware.recallBlockKey: block]
        )
    }

    // MARK: - Slash suggestions

    /// Re-rank the dropdown against the current input. Called by the
    /// `currentInput` didSet observer, which means *every keystroke*.
    /// Kept intentionally synchronous — the registry is in-memory and
    /// `search` is O(skills × tokens).
    private func refreshSlashSuggestions() {
        guard let skills else {
            if !slashSuggestions.isEmpty { slashSuggestions = [] }
            return
        }
        guard let token = SlashCommandParser.activeToken(in: currentInput) else {
            if !slashSuggestions.isEmpty { slashSuggestions = [] }
            return
        }

        let ranked: [Skill]
        if token.query.isEmpty {
            // Bare `/` with nothing after it — show every skill so the user
            // has a full browsable catalog, not an empty dropdown.
            ranked = skills.allSkills()
        } else {
            let hits = skills.search(query: token.query, limit: 12)
            if hits.isEmpty {
                // Fallback: substring match against id when the tokenizer
                // filters out short queries (e.g. single-character `/d`).
                ranked = skills.allSkills().filter {
                    $0.id.lowercased().contains(token.query.lowercased())
                }
            } else {
                ranked = hits
            }
        }

        let mapped = ranked.map { SkillSuggestion(skill: $0) }
        if mapped != slashSuggestions {
            slashSuggestions = mapped
            selectedSuggestionIndex = 0
        }
    }

    /// Move the dropdown selection up (-1) or down (+1). Wraps at the ends.
    /// No-op when the dropdown is closed.
    public func moveSelection(_ delta: Int) {
        guard !slashSuggestions.isEmpty else { return }
        let next = (selectedSuggestionIndex + delta + slashSuggestions.count) % slashSuggestions.count
        selectedSuggestionIndex = next
    }

    /// Insert the currently-highlighted suggestion into the input, replacing
    /// the live token, and close the dropdown. Called by Tab/Return when the
    /// dropdown is open.
    @discardableResult
    public func acceptSelectedSuggestion() -> Bool {
        guard !slashSuggestions.isEmpty,
              slashSuggestions.indices.contains(selectedSuggestionIndex) else { return false }
        return insertSuggestion(slashSuggestions[selectedSuggestionIndex])
    }

    /// Insert a specific suggestion (from a mouse click on the dropdown row).
    @discardableResult
    public func insertSuggestion(_ suggestion: SkillSuggestion) -> Bool {
        guard let token = SlashCommandParser.activeToken(in: currentInput) else { return false }
        let replacement = "/\(suggestion.id) "
        var next = currentInput
        next.replaceSubrange(token.range, with: replacement)
        currentInput = next
        // Closing the dropdown is implicit — the trailing space after the
        // inserted id means `activeToken` no longer matches.
        return true
    }

    // MARK: - Skill chaining (prompt injection)

    /// Compose a system prompt that prepends the bodies of every skill the
    /// user invoked. Ordering is preserved; the LLM is instructed to execute
    /// the skills in sequence and pass outputs between them.
    private func injectSkillBodies(base: String, skillIds: [String]) -> String {
        guard !skillIds.isEmpty, let skills else { return base }
        let bodies = skillIds.compactMap { skills.skill(named: $0) }
        guard !bodies.isEmpty else { return base }

        var out = base
        out += "\n\n## Invoked Skills\n"
        out += "The user has explicitly invoked the following skills via slash commands. "
        out += "Execute them in order; if more than one, pipe the output of each phase into the next. "
        out += "The skill bodies below are authoritative — follow their workflows rather than your own defaults.\n"
        for (idx, skill) in bodies.enumerated() {
            out += "\n### Phase \(idx + 1) — `\(skill.id)`\n"
            out += skill.body
            out += "\n"
        }
        return out
    }

    // MARK: - Agent fragment injection

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

    // MARK: - Chain observer → skill proposal

    /// Decide whether the just-completed run justifies surfacing the "save
    /// as skill" banner. Fires on two signals:
    ///
    /// 1. The user explicitly chained **≥ 2** skills with slashes, OR
    /// 2. The trace produced **≥ 6** tool calls using **≥ 4** unique tools.
    ///
    /// Rationale: an explicit chain is a clear intent signal — they composed
    /// a workflow on purpose. A long implicit chain is a behavioural signal —
    /// the agent did a lot of work that's probably worth crystallising.
    private func evaluateSkillProposal(
        userPrompt: String,
        resolvedSkillIds: [String],
        toolsUsed: [String]
    ) {
        let hasExplicitChain = resolvedSkillIds.count >= 2
        let uniqueTools = Set(toolsUsed)
        let hasImplicitChain = toolsUsed.count >= 6 && uniqueTools.count >= 4

        guard hasExplicitChain || hasImplicitChain else { return }
        guard userSkillsDirectory != nil else { return }

        let justification: String
        let suggested: String?
        if hasExplicitChain {
            let chainDesc = resolvedSkillIds.joined(separator: " → ")
            justification = "You chained \(resolvedSkillIds.count) skills: \(chainDesc)."
            suggested = resolvedSkillIds.joined(separator: "-and-")
        } else {
            justification = "The agent ran \(toolsUsed.count) tool calls across \(uniqueTools.count) distinct tools — that's a workflow worth naming."
            suggested = nil
        }

        pendingSkillProposal = SkillProposal(
            suggestedName: suggested,
            justification: justification,
            recipeBody: userPrompt
        )
    }

    /// Dismiss the banner without saving. No side effects beyond clearing
    /// the proposal; the chain observer will re-evaluate on the next run.
    public func dismissSkillProposal() {
        pendingSkillProposal = nil
    }

    /// Persist the proposed skill to disk at
    /// `~/Library/Application Support/Metamorphia/skills/user/<name>/SKILL.md`,
    /// then re-register the directory with the SkillRegistry so the new
    /// skill shows up in the dropdown immediately.
    public func savePendingSkill(as rawName: String) {
        guard let proposal = pendingSkillProposal,
              let skills,
              let root = userSkillsDirectory else { return }
        let id = SaveSkillBannerView.kebab(rawName)
        guard !id.isEmpty else { return }

        let folder = root.appendingPathComponent(id, isDirectory: true)
        let file = folder.appendingPathComponent("SKILL.md")

        let content = composeSkillMarkdown(id: id, proposal: proposal)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
            skills.loadSkills(from: root)
            pendingSkillProposal = nil
            print("[AICommandViewModel] Saved new skill '\(id)' to \(file.path)")
        } catch {
            errorMessage = "Couldn't save skill: \(error.localizedDescription)"
        }
    }

    private func composeSkillMarkdown(id: String, proposal: SkillProposal) -> String {
        let description = "User-saved workflow. Re-runs the recipe that produced: \(proposal.recipeBody.prefix(100))"
        return """
        ---
        name: \(id)
        description: \(description)
        source: user-saved
        ---

        # \(id)

        A saved workflow. Metamorphia suggested this skill after observing a long chain; the user named and kept it.

        ## Recipe

        \(proposal.recipeBody)

        ## Justification

        \(proposal.justification)

        ## Notes

        This file was auto-generated. Edit freely to refine the recipe — any frontmatter `description:` change will update how the skill appears in the dropdown the next time Metamorphia launches.
        """
    }
#else
    public init() {
        self.isStubMode = true
        self.currentAgent = AgentRegistry.shared.loadPersistedActive()
    }
    public func submit(prompt: String, systemPrompt: String) async {
        // Package not linked yet — placeholder for compile-in-isolation.
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if await ModeRouter.tryHandle(prompt, viewModel: self) { return }
        // T13 — local command pipeline (stub path).
        if let hit = await LocalCommandPipeline.handle(prompt: prompt) {
            let pill = ToolCallPill(
                toolName: "local:\(hit.matcherName)",
                stepIndex: 1, totalSteps: 1,
                isComplete: true, isSuccess: true
            )
            conversation.append(Turn(
                prompt: prompt, result: hit.message,
                toolPills: [pill], isStreaming: false
            ))
            inputBarState = .result(message: hit.message)
            return
        }
        // T7: detection preamble (stub path).
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
        currentInput = ""
        conversation.append(Turn(
            prompt: prompt,
            result: "MetamorphiaAgentKit package not linked into this target.",
            toolPills: [],
            isStreaming: false
        ))
    }
    public func setActiveAgent(_ profile: AgentProfile) {
        guard profile.id != currentAgent.id else { return }
        currentAgent = profile
        AgentRegistry.shared.persistActive(profile)
    }
    public func cancel() async {}
    @MainActor
    public func showModeError(_ message: String) {
        self.errorMessage = message
        self.inputBarState = .error(message: message)
        self.currentInput = ""
    }
    // T7 stubs — match the public API of the real path so callers compile.
    public func submitResearch(query: String, mode: ResearchMode) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let prefixed = "[\(mode.rawValue) research] \(query)"
        inputBarState = .processing
        Task { [weak self] in
            guard let self else { return }
            await self.submit(prompt: prefixed, systemPrompt: Self.defaultSystemPrompt)
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
            await self.submit(prompt: prefixed, systemPrompt: Self.defaultSystemPrompt)
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
#endif

    // MARK: - Attachment management

    public func attachFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            if self.attachedFiles.contains(where: { $0.url == url }) { continue }
            Task { [weak self] in
                guard let file = await FileContentExtractor.shared.extract(from: url) else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !self.attachedFiles.contains(where: { $0.url == file.url }) {
                        withAnimation(.spring(response: 0.25)) {
                            self.attachedFiles.append(file)
                        }
                    }
                }
            }
        }
    }

    public func removeAttachment(id: UUID) {
        attachedFiles.removeAll { $0.id == id }
    }

    public func clearAttachments() {
        withAnimation(.spring(response: 0.25)) {
            attachedFiles.removeAll()
        }
    }

    public func clearConversation() {
        conversation.removeAll()
        protectedTerminalTurnIDs.removeAll()
        attachedFiles.removeAll()
#if canImport(MetamorphiaAgentKit)
        // Synchronously wipe persisted history and drain the pending debounced
        // write. Without this, the very next `submit` re-reads prior turns via
        // `previousChatMessages` (the sink debounce hasn't fired yet) — the user
        // sees a cleared panel but the LLM still receives the full backlog.
        persistence?.clearAndFlush()
#endif
        inputBarState = .ready
        errorMessage = nil
        liveStatus = nil
        agentTree = nil
        currentlyRunningNodeId = nil
        isResponseCompacted = false
        commandBarPreferredWidth = 0
    }

    /// Called from `NotchCommandBarView`'s preference-key pipeline whenever
    /// the rendered content height changes. Debounced so SwiftUI's
    /// rapid-fire preference-change stream doesn't thrash the window
    /// resize spring.
    public func updatePreferredHeight(_ height: CGFloat) {
        preferredHeightWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Cap is purely screen-relative so a long response can grow the
            // notch downward until the available screen runs out; the inner
            // ScrollView only takes over once content would overflow the
            // physical display.
            let screenCap: CGFloat = {
                let visible = NSScreen.main?.visibleFrame.height ?? 900
                return max(120, visible - 40)
            }()
            let clamped = max(44, min(screenCap, height))
            let newHeight = abs(self.commandBarPreferredHeight - clamped) > 1 ? clamped : self.commandBarPreferredHeight

            // Width is intentionally fixed at the user's configured
            // `openNotchWidth`. Growing the window wider than the SwiftUI
            // content's natural width caused the visible notch shape to
            // drift LEFT (content is leading-aligned within an over-wide
            // window) and exposed the physical MacBook notch in the
            // center. Long paragraphs simply wrap — that's a much better
            // tradeoff than a notch that wanders off-center.
            let newWidth: CGFloat = 0

            var changed = false
            if newHeight != self.commandBarPreferredHeight {
                self.commandBarPreferredHeight = newHeight
                changed = true
            }
            if abs(self.commandBarPreferredWidth - newWidth) > 1 {
                self.commandBarPreferredWidth = newWidth
                changed = true
            }
            if changed, let delegate = AppDelegate.shared {
                delegate.commandBarPreferredHeightDidChange()
            }
        }
        preferredHeightWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Export the given turn to a `.docx` in `~/Documents/Metamorphia
    /// Research/` and open it with the user's default Word-doc app
    /// (Pages, Microsoft Word, or TextEdit). Called from the result
    /// bubble's "Open as Word document" button for long responses and
    /// research-mode turns.
    public func openLastResultAsDocument(turnID: UUID) {
        guard let turn = conversation.first(where: { $0.id == turnID }) else { return }
        let text = turn.result
        let prompt = turn.prompt
        guard !text.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let url = try writeResponseDoc(markdown: text, prompt: prompt)
                _ = await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                print("[AICommand] openLastResultAsDocument failed: \(error)")
            }
        }
    }

    public func handleRichContentAction(turnID: UUID, action: DocumentReviewAction) async {
        guard let turn = conversation.first(where: { $0.id == turnID }) else { return }
        guard case .documentReview(let review)? = turn.richContent else { return }

        let label: String = {
            guard let finding = review.findings.first(where: { $0.id == action.findingID }) else {
                return "Document action"
            }
            switch action {
            case .jump:
                return "Document action: Jump to \(finding.location)"
            case .insertComment:
                return "Document action: Comment on \(finding.location)"
            case .applySuggestedRevision:
                return "Document action: Apply rewrite for \(finding.location)"
            }
        }()

        let outcome = await DocumentCopilot.performAction(action, review: review)
        appendDocumentActionTurn(
            prompt: label,
            result: outcome.message,
            success: outcome.success
        )
    }

    public func handlePowerPointRewriteAction(turnID: UUID, action: PowerPointRewriteAction) async {
        guard let turn = conversation.first(where: { $0.id == turnID }) else { return }
        guard case .powerPointRewrite(let rewrite)? = turn.richContent else { return }

        let label: String
        switch action {
        case .jump:
            label = "PowerPoint rewrite: Jump to slide \(rewrite.slideIndex)"
        case .apply:
            label = "PowerPoint rewrite: Apply slide \(rewrite.slideIndex)"
        case .restore:
            label = "PowerPoint rewrite: Restore slide \(rewrite.slideIndex)"
        }

        let outcome = await PowerPointCopilot.performAction(action, rewrite: rewrite)
        appendDocumentActionTurn(
            prompt: label,
            result: outcome.message,
            success: outcome.success
        )
    }

    public func handlePowerPointDesignAction(turnID: UUID, action: PowerPointDesignAction) async {
        guard let turn = conversation.first(where: { $0.id == turnID }) else { return }
        guard case .powerPointDesign(let design)? = turn.richContent else { return }

        let label: String
        switch action {
        case .jump:
            label = "PowerPoint design: Jump to slide \(design.slideIndex)"
        case .apply:
            label = "PowerPoint design: Apply slide \(design.slideIndex)"
        case .restore:
            label = "PowerPoint design: Restore slide \(design.slideIndex)"
        case .undo:
            label = "PowerPoint design: Undo slide \(design.slideIndex)"
        }

        let outcome = await PowerPointCopilot.performDesignAction(action, design: design)
        appendDocumentActionTurn(
            prompt: label,
            result: outcome.message,
            success: outcome.success
        )
    }

    public func handlePowerPointDirectEditAction(turnID: UUID, action: PowerPointDirectEditControlAction) async {
        guard let turn = conversation.first(where: { $0.id == turnID }) else { return }
        guard case .powerPointDirectEdit(let result)? = turn.richContent else { return }

        let label: String
        switch action {
        case .jump:
            label = "PowerPoint edit: Jump to slide \(result.slideIndex)"
        case .restore:
            label = "PowerPoint edit: Restore slide \(result.slideIndex)"
        case .undo:
            label = "PowerPoint edit: Undo slide \(result.slideIndex)"
        }

        let outcome = await PowerPointCopilot.performDirectEditAction(action, result: result)
        appendDocumentActionTurn(
            prompt: label,
            result: outcome.message,
            success: outcome.success
        )
    }

    private func appendDocumentActionTurn(
        prompt: String,
        result: String,
        success: Bool
    ) {
        let turn = Turn(
            prompt: prompt,
            result: result,
            toolPills: [],
            isStreaming: false,
            richContent: nil,
            isStaged: false,
            isError: !success,
            trace: nil
        )
        conversation.append(turn)
        inputBarState = success ? .result(message: result) : .error(message: result)
        if AppDelegate.shared?.vm.notchState == .minimized {
            hasUnseenCompletion = true
        }
    }

    /// Toggle the "user scrolled up, compact the bar" mode. Posts through
    /// the same resize pipeline as height changes so the collapse/expand
    /// rides the existing spring.
    public func setResponseCompacted(_ compacted: Bool) {
        guard isResponseCompacted != compacted else { return }
        isResponseCompacted = compacted
        if let delegate = AppDelegate.shared {
            delegate.commandBarPreferredHeightDidChange()
        }
    }

}

#if canImport(MetamorphiaAgentKit)
// MARK: - AgentProgressSink

extension AICommandViewModel: AgentProgressSink {
    public nonisolated func publish(_ event: AgentProgressEvent) {
        Task { @MainActor in
            guard !self.isSilentRunInProgress else { return }
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
                // AgentLoop emits `streamingToken` on `progressSink` (not
                // `.streaming` on the display sink for live partial text).
                // Synthesise the display state here. Guarded so a stray token
                // after completion doesn't revive `.streaming`.
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
        }
    }

    private func handleStatus(_ label: String) {
        let capped = String(label.prefix(32))
        self.liveStatus = capped
        // Also pipe into the tree so the currently-running node's tagline
        // reflects real-time progress ("Scout: fetching reuters.com").
        if var tree = self.agentTree, let id = self.currentlyRunningNodeId {
            tree.mutate(id: id) { node in
                node.liveStatus = capped
            }
            self.agentTree = tree
        }
    }

    private func handleRunTerminated(_ kind: AgentProgressEvent.Kind) {
        self.liveStatus = nil
        self.agentTree = nil
        self.currentlyRunningNodeId = nil
        // If the user set the notch aside while work was running, flip the
        // minimized dot from blue-pulse to solid-green so they can see at a
        // glance that the task finished (or failed) without re-expanding.
        if AppDelegate.shared?.vm.notchState == .minimized {
            self.hasUnseenCompletion = true
        }
    }

    private func appendToolPill(name: String, step: Int, total: Int) {
        guard let lastIdx = conversation.indices.last else { return }
        conversation[lastIdx].toolPills.append(ToolCallPill(
            toolName: name, stepIndex: step, totalSteps: total, isComplete: false, isSuccess: false
        ))
    }

    private func completeToolPill(name: String, success: Bool) {
        guard let lastIdx = conversation.indices.last else { return }
        if let pillIdx = conversation[lastIdx].toolPills.lastIndex(where: { $0.toolName == name && !$0.isComplete }) {
            conversation[lastIdx].toolPills[pillIdx].isComplete = true
            conversation[lastIdx].toolPills[pillIdx].isSuccess = success
        }
    }

    private func updateToolPillSteps(step: Int, total: Int) {
        guard let lastIdx = conversation.indices.last,
              let pillIdx = conversation[lastIdx].toolPills.indices.last else { return }
        conversation[lastIdx].toolPills[pillIdx] = ToolCallPill(
            toolName: conversation[lastIdx].toolPills[pillIdx].toolName,
            stepIndex: step,
            totalSteps: total,
            isComplete: conversation[lastIdx].toolPills[pillIdx].isComplete,
            isSuccess: conversation[lastIdx].toolPills[pillIdx].isSuccess
        )
    }
}

// MARK: - AgentTreeSink

extension AICommandViewModel: AgentTreeSink {
    public nonisolated func treeStarted(root: AgentIdentityRef) {
        Task { @MainActor in
            guard !self.isSilentRunInProgress else { return }
            self.handleTreeStarted(root: root)
        }
    }
    public nonisolated func nodeAdded(parentId: String?, node: AgentNodeSnapshot) {
        Task { @MainActor in
            guard !self.isSilentRunInProgress else { return }
            self.handleNodeAdded(parentId: parentId, snapshot: node)
        }
    }
    public nonisolated func nodeStateChanged(id: String, state: AgentNodeStateRef, liveStatus: String?) {
        Task { @MainActor in
            guard !self.isSilentRunInProgress else { return }
            self.handleNodeStateChanged(id: id, state: state, liveStatus: liveStatus)
        }
    }

    private func handleTreeStarted(root: AgentIdentityRef) {
        let rootNode = AgentNode(
            id: Self.rootNodeID,
            identity: AgentNameCatalog.identity(for: root),
            state: .running
        )
        self.agentTree = AgentTreeSnapshot(root: rootNode)
        self.currentlyRunningNodeId = rootNode.id
    }

    private func handleNodeAdded(parentId: String?, snapshot: AgentNodeSnapshot) {
        guard var tree = self.agentTree else { return }
        let child = AgentNode(
            id: snapshot.id,
            identity: AgentNameCatalog.identity(for: snapshot.identity),
            state: AgentNodeState(snapshot.state),
            liveStatus: snapshot.liveStatus
        )
        tree.append(child: child, under: parentId)
        self.agentTree = tree
    }

    private func handleNodeStateChanged(id: String, state: AgentNodeStateRef, liveStatus: String?) {
        guard var tree = self.agentTree else { return }
        let uiState = AgentNodeState(state)
        tree.mutate(id: id) { node in
            node.state = uiState
            node.liveStatus = liveStatus
        }
        self.agentTree = tree
        switch state {
        case .running:
            self.currentlyRunningNodeId = id
        case .done, .failed:
            if self.currentlyRunningNodeId == id {
                // Fall back to root so subsequent .status events still have
                // a node to attach to (Oracle resumes control between
                // sub-agents).
                self.currentlyRunningNodeId = Self.rootNodeID
            }
        case .pending:
            break
        }
    }
}

// MARK: - AgentDisplayStateSink

extension AICommandViewModel: AgentDisplayStateSink {
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
                    let turnID = self.conversation[idx].id
                    if self.protectedTerminalTurnIDs.contains(turnID) {
                        self.inputBarState = .result(message: self.conversation[idx].result)
                        self.streamingBuffer = ""
                        return
                    }

                    self.conversation[idx].result = text
                    self.conversation[idx].isStreaming = false
                    self.conversation[idx].isError = false   // defensively clear

                    // T11 — opportunistic rich-content detection. Never overrides
                    // an existing richContent (e.g. functionGraph pre-seed).
                    if self.conversation[idx].richContent == nil,
                       let parsed = RichResultParser.parse(text) {
                        self.conversation[idx].richContent = parsed.content
                        self.conversation[idx].result = parsed.displayText
                        self.protectedTerminalTurnIDs.insert(turnID)
                    }

                    // Research-mode: a research prompt produces a long-form
                    // document, so present it as a real Word doc instead of
                    // cramming the whole thing through the notch. The
                    // in-notch summary stays, but the user's real reading
                    // experience happens in Pages/Word.
                    let turn = self.conversation[idx]
                    if Self.hasResearchPrefix(turn.prompt),
                       self.lastAutoExportedTurnID != turn.id,
                       !text.isEmpty {
                        self.lastAutoExportedTurnID = turn.id
                        self.openLastResultAsDocument(turnID: turn.id)
                    }
                }
                self.inputBarState = .result(message: text)
                self.streamingBuffer = ""

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

            case .cancelled:
                if let idx = self.conversation.indices.last {
                    self.conversation[idx].isStreaming = false
                }
                self.inputBarState = .ready
                self.streamingBuffer = ""
            }
        }
    }
}

// MARK: - Voice input (T5)

extension AICommandViewModel {

    /// The voice controller instance. Weak because it's owned by
    /// `MetamorphiaBootstrap`; nil when voice hasn't been configured (e.g.
    /// tests, preview, or a build where the voice stack was excluded).
    var voiceController: VoiceController? {
        get { objc_getAssociatedObject(self, &voiceControllerKey) as? VoiceController }
        set {
            objc_setAssociatedObject(
                self,
                &voiceControllerKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Hotkey handler — toggles voice listening. Keep this thin: all actual
    /// mic work happens inside `VoiceController.activate()`.
    public func activateVoice() {
        // Called in two paths:
        //   1. `VoiceController.beginVoiceUI()` flips us into `.voiceListening`
        //      as part of UI setup; this method no-ops because state already
        //      matches.
        //   2. A caller that only has a view-model reference (e.g. a menu
        //      item) calls this and expects the controller to handle
        //      everything downstream. We forward to the controller.
        if case .voiceListening = inputBarState { return }

        guard let controller = voiceController else {
            // Voice stack not configured — surface a one-shot error so the
            // user sees why nothing happened.
            inputBarState = .error(message: "Voice input is not available in this build.")
            return
        }
        inputBarState = .voiceListening(partial: "")
        controller.activate()
    }

    /// Called by `VoiceController` on each live partial transcript.
    public func onVoicePartial(_ text: String) {
        // Guard so stale partials after cancel don't resurrect .voiceListening.
        if case .voiceListening = inputBarState {
            inputBarState = .voiceListening(partial: text)
        }
    }

    /// Called by `VoiceController` when the recognizer returns a final
    /// utterance. Dispatches to the agent via the existing `submit` path.
    public func onVoiceFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inputBarState = .ready
            return
        }
        // Drop back to .ready first so `submit` can flip to .processing
        // cleanly (submit's guard only respects the ready/result/error path).
        inputBarState = .ready
        Task { [weak self] in
            guard let self else { return }
            // Reuse the same system prompt NotchCommandBarView uses for typed
            // prompts — voice commands are treated identically to typed ones.
            let basePrompt = Self.defaultSystemPrompt
            let systemPrompt = self.injectAgentFragment(base: basePrompt, agent: self.currentAgent)
            await self.submit(prompt: trimmed, systemPrompt: systemPrompt)
        }
    }

    /// Cancel voice listening and return the pill to `.ready`.
    public func cancelVoice() {
        if case .voiceListening = inputBarState {
            inputBarState = .ready
        }
    }
}

private var voiceControllerKey: UInt8 = 0
#endif
