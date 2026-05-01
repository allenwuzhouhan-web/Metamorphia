import AppKit
import ApplicationServices
import Defaults
import KeyboardShortcuts
import MetamorphiaAgentKit
import MetamorphiaExecutors
import MetamorphiaPerception

/// One-stop bootstrap for the Metamorphia AI features. Call `MetamorphiaBootstrap.configure()`
/// from `AppDelegate.applicationDidFinishLaunching(_:)` and everything wires up:
///   - Builds the shared `ToolRegistry` and registers Metamorphia-native tools.
///   - Constructs the `AgentLoop` with the default middleware stack.
///   - Creates `AICommandViewModel`, hands it to `CommandBarCoordinator.shared`.
///   - Registers the Cmd+Shift+Space handler that toggles the Command Bar.
///   - Pre-populates `ToolDisplayName` with the default friendly-name map.
///
/// Idempotent — calling it twice is harmless (subsequent calls return the cached
/// objects).
@MainActor
public enum MetamorphiaBootstrap {

    public static private(set) var registry: ToolRegistry?
    public static private(set) var loop: AgentLoop?
    public static private(set) var viewModel: AICommandViewModel?
    public static private(set) var costTracker: CostTracker?
    public static private(set) var memoryStore: (any MemoryStore)?
    /// Skill catalog. Built at bootstrap, read by the command bar's slash
    /// dropdown so users can browse skills without going through the LLM
    /// `search_skills` roundtrip. Bundled skills ship inside the
    /// `MetamorphiaExecutors` resource directory; user-authored skills are
    /// loaded from `~/Library/Application Support/Metamorphia/skills/user/`.
    public static private(set) var skills: SkillRegistry?
    /// Continuum Phase 1: shared entity stores. Exactly one writer to
    /// entity-aliases.json — both AICommandViewModel and ClipboardInsights
    /// use these instances, never fresh ones.
    public static private(set) var aliasStore: EntityAliasStore?
    public static private(set) var termFrequency: RollingTermFrequency?
    /// Continuum Phase 2: shared interest graph. Exactly one instance;
    /// `InterestGraphPotentiator` and future consumers share this reference.
    public static private(set) var interestGraph: InterestGraphStore?
    /// PowerPoint design-language profile learned from user-uploaded reference
    /// decks. Stores extracted metadata only; raw deck contents are not kept.
    public static private(set) var presentationTasteStore: PresentationTasteStore?
    /// Continuum Phase 4: story tracker. Clusters news articles into narrative
    /// `Story` objects via entity-overlap. Phase 5's ThreadContinuationEngine
    /// decides when to call `ingest`; the `news_feed` tool accepts a `track`
    /// flag that pipes articles through here when set. Not auto-ingesting on
    /// bootstrap keeps the launch path lean.
    public static private(set) var stories: StoryTracker?
    /// Continuum Phase 5: continuation engine. Scores stories against the
    /// interest graph + recent conversation turns to produce
    /// `ContinuationProposal`s. Nil until `configure()` completes.
    public static private(set) var continuation: ThreadContinuationEngine?
    /// Observation spine: typed activity-event stream + disk journal. Created
    /// with a `Defaults`-backed gate so Settings can flip the whole pipeline
    /// off without restarting the app. Sensors added in later workstreams
    /// take this stream via DI rather than reaching for `ActivityStream.shared`.
    public static private(set) var activityStream: ActivityStream?
    public static private(set) var activityJournal: ActivityJournal?
    /// WS-2..6 sensors. Held on the bootstrap so their poll tasks / workspace
    /// observers / CGEventTap survive for the lifetime of the process.
    public static private(set) var appFocusSensor: AppFocusSensor?
    public static private(set) var browserTabSensor: BrowserTabSensor?
    public static private(set) var inputIdleSensor: InputIdleSensor?
    public static private(set) var placeSensor: PlaceSensor?
    /// WS-5 derived-event detectors. Pure stream consumers that emit higher-
    /// level events (meeting / session) back into the spine.
    public static private(set) var hardwareStreamBridge: HardwareStreamBridge?
    public static private(set) var meetingDetector: MeetingDetector?
    public static private(set) var sessionSegmenter: SessionSegmenter?
    static private(set) var voiceController: VoiceController?
    /// Super-perceiver new sensors (Wave 7). Held so their timers / bus
    /// handlers survive for the lifetime of the process.
    public static private(set) var pasteboardWatcher: PasteboardWatcher?
    public static private(set) var selectionTracker: SelectionTracker?
    /// Workspace trigger source (Phase D push mode). Retained so its
    /// NSWorkspace observers stay registered for the lifetime of the process.
    /// AXObserverPool + PushPerceptionDriver are singletons already.
    public static private(set) var workspaceTriggerSource: WorkspaceTriggerSource?

    private static var didConfigure = false

    /// Wire everything up. Safe to call from `applicationDidFinishLaunching`.
    public static func configure() {
        guard !didConfigure else { return }
        didConfigure = true

        // 1. Friendly tool names — used by StreamingProgressMiddleware for nice labels.
        ToolDisplayName.register(AgentLoop.defaultFriendlyNames)

        // 1b. Previously we *forced* `openNotchOnHover = true` and
        // `minimumHoverDuration = 1.0` here. That stomped on the user's own
        // preference every launch and meant every cursor-arrival on the notch
        // auto-opened to the home view (showing music controls) before the
        // user's click ever registered as an explicit "summon command bar"
        // action. We now respect whatever the user has in Settings. If the
        // default has never been set, the base default in `Constants.swift`
        // still applies.

        // 2. Shared infrastructure: registry, cost tracker, memory store, safety gate.
        //    The safety gate is the *only* thing standing between an LLM-
        //    generated tool call (shell/applescript/script/destructive file op)
        //    and execution. Without it, the registry dispatches unconditionally.
        let safetyGate = MetamorphiaToolSafetyGate.shared
        let registry = ToolRegistry(safetyGate: safetyGate)
        let tracker = CostTracker()
        let metamorphiaSupport = URL.applicationSupportDirectory
            .appendingPathComponent("Metamorphia", isDirectory: true)

        // 2a. Install the perception host before anything in ComputerLib is
        //     touched. This routes ElementDatabase / AppProfile / WorkflowRecorder
        //     persistence to `~/Library/Application Support/Metamorphia/perception/`
        //     and migrates the legacy `~/Library/Application Support/Computer/`
        //     database on first launch. Must precede any code path that could
        //     hit `DefaultComputerPerception.shared` (tool registrations,
        //     AgentLoop construction, middleware init).
        PerceptionBootstrap.configure(applicationSupportDir: metamorphiaSupport)

        // 2b. Register the perception-backed argument safety inspector. The
        //     gate consults this *before* its static tier table on every tool
        //     call, so gesture clicks targeting destructive elements ("Delete
        //     account", "Erase all…") and typing into password / credit-card
        //     fields automatically escalate to `.critical` and prompt the
        //     user — even though the underlying `click_at` / `type_text` tools
        //     would otherwise fall through silently.
        safetyGate.register(inspector: PerceptionBootstrap.makeSafetyInspector())

        // 2b2. Build the ambient perception context provider. It wraps the
        //      null provider (nothing else populates system context today)
        //      and injects a `PerceptionSummary` derived from the 10 Hz
        //      perception loop. `start()` is deferred until after the
        //      middleware chain is built (see step 8c) so an early crash
        //      there doesn't also crash the loop.
        let perceptionContext = PerceptionBootstrap.makeContextProvider()

        let memory = FileMemoryStore(
            storageURL: metamorphiaSupport.appendingPathComponent("memories.json")
        )
        Self.registry = registry
        Self.costTracker = tracker
        Self.memoryStore = memory

        // 2c. Continuum Phase 1 shared entity stores. Constructed here so
        //     AICommandViewModel and ClipboardInsights both hold the same
        //     instances — guaranteeing exactly one writer to entity-aliases.json.
        let sharedAliasStore = EntityAliasStore()
        let sharedTermFrequency = RollingTermFrequency()
        Self.aliasStore = sharedAliasStore
        Self.termFrequency = sharedTermFrequency

        // 2d. Continuum Phase 2 — interest graph. Encrypted at rest; falls back
        //     to plain JSON if the Keychain is unavailable. Constructed before
        //     the middleware chain so InterestGraphPotentiator can hold a strong
        //     reference from the very first agent-loop run.
        let sharedInterestGraph = InterestGraphStore()
        Self.interestGraph = sharedInterestGraph

        let sharedPresentationTasteStore = PresentationTasteStore()
        Self.presentationTasteStore = sharedPresentationTasteStore

        // 2e. Continuum Phase 4 — story tracker. Encrypted at rest; falls back
        //     to plain JSON if the Keychain is unavailable. The instance is
        //     exposed for Phase 5 wiring and injected into `NewsDataTool` so
        //     the `track` flag can route articles through narrative clustering.
        let sharedStoryTracker = StoryTracker()
        Self.stories = sharedStoryTracker

        // 3. Wire the cost tracker into the LLM service manager so every API call
        //    flows through it.
        LLMServiceManager.shared.costTracker = tracker

        // 4. Register Metamorphia-native tools (timer, clipboard, notes, shelf, etc.)
        MetamorphiaTools.register(into: registry)

        // 4b. Register MetamorphiaExecutors tools (run_applescript, run_shell_command).
        MetamorphiaExecutors.register(into: registry)

        // 4b1. Memory tools — store_memory + recall_memory, backed by the
        //      FileMemoryStore constructed above. Must follow register(into:)
        //      so the tools appear alongside the rest of the catalog.
        MetamorphiaExecutors.registerMemoryTools(into: registry, memory: memory)

        // 4b1b. News tools — news_feed, backed by GoogleNewsService + RSSParser.
        //       No API key; Google News public RSS endpoints only.
        //       Phase 4: inject the StoryTracker + entity stores so the
        //       `track: true` flag can pipe articles through clustering.
        MetamorphiaExecutors.registerNewsTools(
            into: registry,
            storyTracker: sharedStoryTracker,
            aliasStore: sharedAliasStore,
            termFrequency: sharedTermFrequency
        )

        // 4b5. Continuum Phase 7 — Calendar Lens.
        //      Start the 5-minute calendar poll. Access is NOT requested here;
        //      the Settings UI (Phase 13) calls CalendarLens.shared.requestAccess().
        CalendarLens.shared.start(
            interestGraph: sharedInterestGraph,
            stories: sharedStoryTracker,
            aliasStore: sharedAliasStore,
            memory: memory
        )

        // 4b2. Market Lens — watchlist + ambient quote polling + alerts.
        //      Watchlist persistence loads from disk (and iCloud KVS if
        //      available); the monitor starts polling if the watchlist is
        //      non-empty. Both are ObservableObject singletons consumed by
        //      `NotchMarketsView`, `MarketTickerView`, and
        //      `PriceAlertLiveActivity`.
        _ = WatchlistStore.shared
        MarketQuoteMonitor.shared.start()

        // 4b3b. Activity-observation spine.
        //       One append-only stream + one encrypted daily journal. Sensors
        //       (frontmost app, browser tab, input cadence, meeting detector,
        //       place) added in later workstreams emit into this stream instead
        //       of each consumer polling its own source.
        let activityStream = ActivityStream(gate: DefaultsBackedActivityGate())
        Self.activityStream = activityStream
        let activityJournal = ActivityJournal.shared
        Self.activityJournal = activityJournal
        let activityPersistence = try? SecurePersistence(serviceTag: "com.metamorphia.activity.v1")
        if let activityPersistence {
            activityJournal.start(
                stream: activityStream,
                persistence: activityPersistence,
                gate: DefaultsBackedActivityGate()
            )
        } else {
            // Keychain unavailable (ad-hoc build, locked Keychain). Fall back
            // to plaintext JSON under the same directory; the journal logs the
            // downgrade exactly once per process.
            activityJournal.startInsecure(
                stream: activityStream,
                gate: DefaultsBackedActivityGate()
            )
        }

        // 4b3c. Activity sensors.
        //       Each sensor emits into `activityStream` when its own
        //       `Defaults[.observe*]` toggle is on. Starting them is idempotent;
        //       flipping a toggle in Settings takes effect on the next poll.
        let appFocus = AppFocusSensor(stream: activityStream)
        appFocus.start()
        Self.appFocusSensor = appFocus

        let browserTab = BrowserTabSensor(stream: activityStream, allowlist: BrowserDomainAllowlist.shared)
        browserTab.start()
        Self.browserTabSensor = browserTab

        let inputIdle = InputIdleSensor(stream: activityStream)
        inputIdle.start()
        Self.inputIdleSensor = inputIdle

        InputCadenceTracker.shared.start()

        let place = PlaceSensor(stream: activityStream, labelStore: PlaceLabelStore.shared)
        place.start()
        Self.placeSensor = place

        // 4b3d. Derived-event detectors.
        //       HardwareStreamBridge forwards Camera/Mic @Published state into
        //       the spine as .cameraToggled / .microphoneToggled. MeetingDetector
        //       combines those with frontmost app + last browser URL to flag
        //       meeting start/end. SessionSegmenter collapses focus+idle events
        //       into .sessionClosed units that downstream LLM consumers reason over.
        let hardwareBridge = HardwareStreamBridge(stream: activityStream)
        hardwareBridge.start()
        Self.hardwareStreamBridge = hardwareBridge

        let meetingDetector = MeetingDetector(stream: activityStream)
        meetingDetector.start()
        Self.meetingDetector = meetingDetector

        let cadenceProvider: @Sendable () -> CadenceTier = {
            // Hop onto the main actor synchronously — InputCadenceTracker is
            // @MainActor-isolated. This closure runs from the segmenter actor,
            // so the sync hop is safe (no reentrancy) and avoids making the
            // provider `async` which would cascade through the stream.
            let tier = DispatchQueue.main.sync { InputCadenceTracker.shared.tier }
            switch tier {
            case .idle:  return CadenceTier.idle
            case .light: return CadenceTier.light
            case .heavy: return CadenceTier.heavy
            }
        }
        let segmenter = SessionSegmenter(stream: activityStream, cadenceProvider: cadenceProvider)
        Task { await segmenter.start() }
        Self.sessionSegmenter = segmenter

        // 4b3e. Super-perceiver control plane (always-on, cheap when idle).
        //       TriggerBus is the coalescing inbox for all push-mode AX reasons.
        //       PerceptionBudget adjusts lane tiers based on battery/thermal state.
        //       PermissionVault watches for mid-session revocations and updates
        //       per-lane status so the UI can surface a re-prompt without restart.
        TriggerBus.shared.start()

        Task {
            await PerceptionBudget.shared.attach(battery: BatteryStateAdapter())
            await PerceptionBudget.shared.start()
        }

        PermissionVault.shared.startRevocationWatch()

        // Push pipeline — event-driven perception via AX observers + workspace
        // notifications. Default since Phase D: `perceptionTriggerMode == "push"`
        // (flipped from "pull" in SelectionTracker.swift). Users who hit trouble
        // with a weak-AX Electron app can opt back to "pull" in Settings;
        // we honor their choice explicitly rather than forcing push on.
        //
        // Start order matters: AXObserverPool + WorkspaceTriggerSource produce
        // the reasons that PushPerceptionDriver's handler consumes, so wire the
        // sources first, then the driver.
        if Defaults[.perceptionTriggerMode] == "push" {
            let workspaceSource = WorkspaceTriggerSource()
            workspaceSource.start()
            Self.workspaceTriggerSource = workspaceSource
            AXObserverPool.shared.start()
            PushPerceptionDriver.shared.start()
        }

        // 4b3f. New conditional sensors.
        //       PasteboardWatcher and SelectionTracker respect their own
        //       Defaults gates inside start(); constructing them here and
        //       calling start() is the correct pattern — matching existing sensors.
        let pasteboardWatcher = PasteboardWatcher(stream: activityStream)
        pasteboardWatcher.start()
        Self.pasteboardWatcher = pasteboardWatcher

        if Defaults[.observeSelection] {
            let tracker = SelectionTracker(stream: activityStream)
            tracker.start()
            Self.selectionTracker = tracker
        }

        // Phase D — ambient proposal loop. Subscribes to the ActivityStream,
        // polls AttentionModel and PerceptionBudget, emits Proposal values
        // into its Combine publisher when the guard stack allows. The
        // Whisper Card (`AmbientProposalPresenter`) subscribes downstream
        // and renders one proposal at a time; nothing runs unless the
        // user explicitly accepts.
        Task {
            await ProposalLoop.shared.start(
                stream: activityStream,
                attentionScore: { @MainActor in AttentionModel.shared.currentScore },
                budgetTier: { await PerceptionBudget.shared.current.rawValue }
            )
        }

        // Whisper Card — ambient proposal surface. Subscribes to the
        // ProposalLoop publisher, shows one card at a time below the notch,
        // hands acceptance back to a caller-supplied runner. `onAccept` is
        // still a stub in this turn — Phase E wires it to a SemanticExecutor
        // + computer_batch pipeline so one tap runs the proposed actions.
        Task { @MainActor in
            AmbientProposalPresenter.shared.onAccept = { proposal in
                // Lowering lives on the presenter so the bootstrap doesn't
                // own the per-goal logic. Runner fires on its own Task
                // (the presenter's `accept(_:)` already Task-wraps this
                // closure) so the card's fade-out isn't blocked by the
                // executor's wall-clock budget.
                Task { await AmbientProposalPresenter.runDefaultAction(for: proposal) }
            }
            AmbientProposalPresenter.shared.install()
        }

        // DocumentOpenWatcher is defined in the test suite but its production
        // source file has not landed yet. Boot call will be added here once
        // DocumentOpenWatcher.swift is committed to the Metamorphia target.

        // 4c. Retrace — temporal recall index (Phase 1-10).
        //     Wires the index, query rank, and archivers. Heavy sources
        //     (ScreenHarvest, FileHarvest, MessageArchive, MailArchive) are
        //     only activated when the user opts in via Settings.
        Task { @MainActor in
            RetraceSurface.shared.aliasStore = sharedAliasStore
            RetraceSurface.shared.termFrequency = sharedTermFrequency
            RetraceSurface.shared.interestGraph = Self.interestGraph
            RetraceSurface.shared.activityStream = activityStream
            RetraceSurface.shared.start()
            RetraceSessionBridge.shared.start(stream: activityStream)
            if Defaults[.retraceIngestionEnabled] &&
               Defaults[.retraceScreenEnabled] &&
               AXIsProcessTrusted() {
                ScreenHarvest.shared.start()
            }
            // Bridge the recall_scene tool to RetraceSurface so the agent
            // can ask questions like "what was I doing yesterday night?"
            RecallSceneTool.search = { @Sendable query in
                let result = await RetraceSurface.shared.search(query)
                guard let result else { return nil }
                let scenes: [RecallSceneTool.RecallResult.Scene] = result.scenes.map { scene in
                    let hero = scene.hero.item
                    return RecallSceneTool.RecallResult.Scene(
                        heroTitle: hero.title ?? "(untitled)",
                        heroKind: String(describing: hero.kind),
                        heroTimestamp: hero.timestamp,
                        heroSnippet: String(hero.body.prefix(240)),
                        heroPath: hero.docPath,
                        heroURL: hero.url,
                        chipEntities: scene.chipEntities,
                        siblingCount: max(0, scene.members.count - 1),
                        anchorReason: scene.anchorReason
                    )
                }
                let window = result.window.map {
                    RecallSceneTool.RecallResult.WindowSummary(start: $0.start, end: $0.end, reason: $0.reason)
                }
                return RecallSceneTool.RecallResult(scenes: scenes, window: window, autoNarrowed: result.autoNarrowed)
            }
        }

        // 4b4. Continuum Phase 6 — attention model.
        //      Learns engagement windows from behavioural signals and exposes
        //      `currentScore` for gating proactive surfaces in later phases.
        //      Falls back to in-memory buckets (plain JSON) if the Keychain is
        //      unavailable; observable via AttentionModel.shared.currentScore.
        let attentionPersistence = try? SecurePersistence(serviceTag: "com.metamorphia.attention.v1")
        AttentionModel.shared.start(securePersistence: attentionPersistence)

        // 4b6. Continuum Phase 10 — predictive staging.
        //      QueryPatternLearner records every submission and detects
        //      recurring morning queries. PredictiveStaging pre-computes
        //      the top candidate on wake so the command bar can render it
        //      instantly (< 100 ms) with a sparkle indicator.
        let patternPersistence = try? SecurePersistence(serviceTag: "com.metamorphia.querypatterns.v1")
        let patternExtractor = EntityExtractor(aliasStore: sharedAliasStore, termFrequency: sharedTermFrequency)
        QueryPatternLearner.shared.start(
            securePersistence: patternPersistence,
            extractor: patternExtractor
        )

        // 4b3. Continuum Phase 1 — entity extraction hook.
        //      ClipboardInsights subscribes to clipboard changes and posts
        //      continuumEntitiesExtracted notifications for Phase 2.
        //      Pass the shared stores so there is exactly one writer to
        //      entity-aliases.json.
        ClipboardInsights.shared.start(aliasStore: sharedAliasStore, termFrequency: sharedTermFrequency)

        // 4c. Build the SkillRegistry, load bundled skills, and register the
        //     `search_skills` + `load_skill` tools. Also load any user-authored
        //     skills the chain observer has saved to disk on prior runs.
        let skills = SkillRegistry()
        MetamorphiaExecutors.registerSkills(into: registry, skills: skills, loadBundledSkills: true)
        let userSkillsDir = metamorphiaSupport
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("user", isDirectory: true)
        try? FileManager.default.createDirectory(at: userSkillsDir, withIntermediateDirectories: true)
        skills.loadSkills(from: userSkillsDir)
        Self.skills = skills

        // Phase E — compiled-skill catalog. Loads any previously-learned
        // CompiledSkills from the `workflows` SQLite table and registers
        // each as a dynamic ToolDefinition so the LLM can invoke learned
        // routines by name. Propagates the Defaults[.workflowRecorderEnabled]
        // flag to the SkillRecorder so opt-in is honored at launch.
        Task {
            await CompiledSkillCatalog.shared.attach(registry: registry)
            await SkillRecorder.shared.setEnabled(Defaults[.workflowRecorderEnabled])
        }

        // 5. Construct the agent loop with the default middleware stack.
        let chain = AgentLoop.makeDefaultMiddlewareChain(
            progressSink: NullProgressSink(),  // swapped out below once viewModel is available
            memoryStore: memory,
            systemContext: perceptionContext,
            clipboard: NullClipboardProvider(),
            session: NullSessionProvider(),
            toolCatalog: ToolRegistryCatalogAdapter(registry: registry),
            adaptiveResponseStorageURL: metamorphiaSupport.appendingPathComponent("response_engagement.json"),
            interestGraph: sharedInterestGraph
        )

        let loop = AgentLoop(
            service: LLMServiceManager.shared.currentService,
            registry: registry,
            middlewareChain: chain,
            displayStateSink: nil,    // wired via viewModel below
            progressSink: nil,
            treeSink: nil,
            costTracker: tracker      // powers the per-task cost ceiling breaker
        )
        Self.loop = loop

        // 6. Intent scorer — learns which tool categories satisfy each kind
        //    of query. Hints are injected into the system prompt as soft
        //    priors; outcomes feed back via `recordOutcome` for LTP/decay.
        let intentScorer = IntentScorer(
            registry: registry,
            storageURL: metamorphiaSupport.appendingPathComponent("intent_history.json")
        )

        // 6b. Conversation persistence — restores prior turns on launch and
        //     threads them into each `loop.submit` as `previousMessages`.
        let persistence = ConversationPersistenceService(
            storageURL: metamorphiaSupport.appendingPathComponent("conversation.json")
        )

        // 6c. Continuum Phase 5 — thread continuation engine.
        //     The turns provider reads `persistence.turns` on the MainActor,
        //     filtering to the last 14 days, and returns the user-prompt
        //     strings. Captured as a @Sendable closure so the engine (an actor)
        //     can call it without holding the MainActor.
        let continuationEngine = ThreadContinuationEngine(
            stories: sharedStoryTracker,
            interestGraph: sharedInterestGraph,
            conversationTurnsProvider: {
                let cutoff = Date().addingTimeInterval(-14 * 86_400)
                let recentTurns: [String] = await MainActor.run {
                    persistence.turns
                        .filter { $0.createdAt >= cutoff }
                        .map { $0.prompt }
                }
                return recentTurns
            },
            aliasStore: sharedAliasStore,
            termFrequency: sharedTermFrequency
        )
        Self.continuation = continuationEngine

        // 6c-news. Continuum Phase 11 — News tab model.
        //          Configure after the continuation engine is in scope so
        //          NewsTabModel.refreshNow() can call engine.propose immediately.
        NewsTabModel.shared.configure(
            continuation: continuationEngine,
            stories: sharedStoryTracker,
            newsService: GoogleNewsService()
        )

        // 6d. Continuum Phase 8 — clipboard enrichment surface.
        //     Must be wired after both ClipboardInsights.start (Phase 1, step 4b3)
        //     and the continuation engine (Phase 5, step 6c). continuationEngine
        //     is in scope here.
        ClipboardInsightsSurface.shared.start(
            interestGraph: sharedInterestGraph,
            stories: sharedStoryTracker,
            continuation: continuationEngine
        )

        // 6e. Continuum Phase 9 — Morning Brief assembler.
        //     Wire after continuationEngine (Phase 5) is in scope.
        //     MarketQuoteMonitor.shared.start() above schedules the first
        //     maybePostMorningBrief() as a Task, so configure() runs before
        //     that Task body executes on the next run-loop turn.
        MorningBriefAssembler.shared.configure(
            markets: MarketQuoteMonitor.shared,
            stories: sharedStoryTracker,
            continuation: continuationEngine,
            calendar: CalendarLens.shared,
            attention: AttentionModel.shared
        )

        // 7. View model — pass the shared Continuum stores so the same
        //    EntityAliasStore and RollingTermFrequency back all writes.
        let viewModel = AICommandViewModel(
            loop: loop,
            intentScorer: intentScorer,
            persistence: persistence,
            skills: skills,
            userSkillsDirectory: userSkillsDir,
            aliasStore: sharedAliasStore,
            termFrequency: sharedTermFrequency
        )
        Self.viewModel = viewModel

        // 6a. Attach the view model back as all three sinks. The loop was
        // built first because the view model needs a live reference to it;
        // this is the closing edge of that cycle. Sinks are captured into
        // each `submit(...)`'s detached Task at call time, so setting them
        // before any user prompt fires is enough — no need to refactor the
        // loop's lifecycle. Previously every sink was nil: tool pills,
        // live status, and the agent tree never reached the UI even though
        // the wiring code existed.
        Task {
            await loop.setProgressSink(viewModel)
            await loop.setDisplayStateSink(viewModel)
            await loop.setTreeSink(viewModel)
        }

        // Phase 10 (continued): wire PredictiveStaging with a dedicated
        // AgentLoop so pre-warm runs are completely isolated from the user's
        // live run. The staging loop shares the same registry / middleware
        // deps but is a separate instance — its cancelInFlight() cannot
        // touch the user-facing loop.
        let stagingChain = AgentLoop.makeDefaultMiddlewareChain(
            progressSink: NullProgressSink(),
            memoryStore: memory,
            systemContext: perceptionContext,
            clipboard: NullClipboardProvider(),
            session: NullSessionProvider(),
            toolCatalog: ToolRegistryCatalogAdapter(registry: registry),
            adaptiveResponseStorageURL: metamorphiaSupport.appendingPathComponent("response_engagement.json"),
            interestGraph: sharedInterestGraph
        )
        let stagingLoop = AgentLoop(
            service: LLMServiceManager.shared.currentService,
            registry: registry,
            middlewareChain: stagingChain,
            displayStateSink: nil,
            progressSink: nil,
            treeSink: nil,
            costTracker: tracker
        )

        PredictiveStaging.shared.start(
            patterns: QueryPatternLearner.shared,
            agentSubmit: { @MainActor [weak viewModel] prompt in
                guard let vm = viewModel else { return "" }
                return await vm.submitSilent(prompt, loop: stagingLoop)
            },
            isUserBusy: { @MainActor [weak viewModel] in
                viewModel?.isProcessing ?? false
            }
        )

        // 7. Hand the view model to the coordinator so the Command Bar can find it.
        CommandBarCoordinator.shared.viewModel = viewModel

        // 7a. Voice input (T5). Owns VoiceService + glow window lifecycle. Weak
        //     ref back on the view model so hotkey callers that only hold the VM
        //     can reach the controller.
        let voiceCtrl = VoiceController(viewModel: viewModel)
        voiceCtrl.setup()
        Self.voiceController = voiceCtrl
        viewModel.voiceController = voiceCtrl

        // 8. Register the Cmd+Shift+Space hotkey.
        KeyboardShortcuts.onKeyDown(for: .commandBar) {
            NSLog("🔔 [Metamorphia/CommandBar] hotkey ⌘⇧Space pressed")
            Task { @MainActor in
                CommandBarCoordinator.shared.toggle()
            }
        }

        // 8a. Defensive default restore (fix #10). If the user (or a stale
        // UserDefaults import) has cleared the commandBar shortcut, restore
        // the ⌘⇧Space default so the primary entry point is always bound.
        // `getShortcut` returns nil if the user wiped the binding.
        if KeyboardShortcuts.getShortcut(for: .commandBar) == nil {
            KeyboardShortcuts.reset(.commandBar)
            print("[MetamorphiaBootstrap] commandBar hotkey was empty — restored ⌘⇧Space default.")
        }

        // 8b. Cmd+Shift+V — voice input.
        KeyboardShortcuts.onKeyDown(for: .voiceInput) {
            NSLog("🎙 [Metamorphia/Voice] hotkey ⌘⇧V pressed")
            Task { @MainActor in
                MetamorphiaBootstrap.voiceController?.activate()
            }
        }

        // 8c. Defensive default restore — mirrors the `.commandBar` path.
        if KeyboardShortcuts.getShortcut(for: .voiceInput) == nil {
            KeyboardShortcuts.reset(.voiceInput)
            print("[MetamorphiaBootstrap] voiceInput hotkey was empty — restored ⌘⇧V default.")
        }

        // 8b. Keep the global KeyboardShortcuts switch ON — the commandBar
        // hotkey must survive even when the user disables per-feature
        // shortcuts. See MetamorphiaApp's `updateFeatureShortcutAvailability`
        // which enforces the same invariant whenever the flag changes.
        KeyboardShortcuts.isEnabled = true

        print("[MetamorphiaBootstrap] AI command bar configured. \(registry.count) tools, \(skills.count) skills registered.")

        // 8c. Start the ambient perception loop and wire the stream into the
        //     context provider we already handed to the middleware chain.
        //     Deferred until the rest of the bootstrap is stable so an early
        //     crash doesn't also take down the perception loop — it runs on a
        //     detached task and keeps the 10 Hz stream alive until the app
        //     exits. No-op if accessibility permission isn't yet granted; the
        //     loop just emits empty maps until the user authorizes.
        perceptionContext.start()

        // 9. Continuum Phase 1 — one-shot historical back-fill.
        //    On the very first launch after this code ships, replay all
        //    persisted conversation turns through the entity extractor so the
        //    interest graph (Phase 2) starts with a warm entity set rather than
        //    a cold start. Runs on a detached background Task so it never
        //    delays app launch.
        scheduleEntityBackfill(persistence: persistence, aliasStore: sharedAliasStore, termFrequency: sharedTermFrequency)

        // 10. Continuum Phase 13 — kill switches.
        //     Subscribes to feature-flag changes and clears live in-flight state
        //     (staged response, morning brief, meeting brief, clipboard hint)
        //     within one run-loop tick when a flag is toggled off. Without this,
        //     disabled surfaces persist until their next scheduled poll or wake.
        ContinuumKillSwitches.shared.start()
    }

    // MARK: - Continuum entity back-fill

    private static func scheduleEntityBackfill(
        persistence: ConversationPersistenceService,
        aliasStore: EntityAliasStore,
        termFrequency: RollingTermFrequency
    ) {
        let backfillKey = "continuum.entityBackfillDone"
        guard !UserDefaults.standard.bool(forKey: backfillKey) else { return }

        Task.detached(priority: .utility) {
            let turns = await MainActor.run { persistence.turns }
            guard !turns.isEmpty else {
                await MainActor.run { UserDefaults.standard.set(true, forKey: backfillKey) }
                return
            }

            // Use the shared stores — no extra writer to entity-aliases.json.
            let extractor = EntityExtractor(aliasStore: aliasStore, termFrequency: termFrequency)

            for turn in turns {
                let text = turn.prompt
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let entities = await extractor.extract(text)
                guard !entities.isEmpty else { continue }

                await MainActor.run {
                    NotificationCenter.default.post(
                        Notification.continuumEntitiesExtracted(entities: entities, source: .backfill, text: text)
                    )
                }
            }

            await MainActor.run {
                UserDefaults.standard.set(true, forKey: backfillKey)
                print("[MetamorphiaBootstrap] Continuum entity back-fill complete — \(turns.count) turns processed.")
            }
        }
    }
}
