# Project Continuum — Implementation Plan

A magical, invisible, memory-driven news + continuation experience for Metamorphia.

## Design principles (NON-NEGOTIABLE)

1. **Invisible learning** — interest graph grows silently; no preferences panel required.
2. **Pull before push** — every feature has a pull surface first.
3. **Continuation over discovery** — news surfaces only when it connects to an entity/thread already in the user's head.
4. **Anti-algorithm** — down-rank what everyone else shows; up-rank what only this user would care about.
5. **On-device** — no news-aggregator API keys; no remote personalization.
6. **Respect the notch** — headlines ride inside existing morningBrief/clipboardSuggestion/activeAlerts lanes.

## Naming register (enforce strictly)

- Concrete nouns + verb-object. NO `Manager`, `Orchestrator`, `Provider`, `Dispatcher`, `Router` suffixes.
- Examples to mirror: `YahooFinanceService`, `MarketQuoteMonitor`, `WatchlistStore`, `MarketDataTool`.
- Typography: San Francisco only. NO SF Mono unless rendering code.
- No emojis in source files.

## Architectural map (already in repo — DO NOT RE-INVENT)

- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/Stores/FileMemoryStore.swift` — synaptic decay store, MemoryCategory enum, SynapticStrength, `~/Library/Application Support/Metamorphia/memories.json`
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/Stores/ConversationStore.swift` + `ConversationPersistenceService`
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/Core/ToolDefinition.swift` — protocol
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/LLM/ToolRegistry.swift` — `register`, `ToolCategory` enum (has `.memory`, `.webContent`)
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/LLM/AgentLoop.swift` — `makeDefaultMiddlewareChain()`
- `Packages/MetamorphiaExecutors/Sources/MetamorphiaExecutors/MetamorphiaExecutors.swift` — bulk tool registration
- `Metamorphia/MetamorphiaBootstrap.swift` — app-level registration
- `Metamorphia/ViewModels/AICommandViewModel.swift` — `submit()`, system prompt builder, skill injection
- `Metamorphia/services/MarketQuoteMonitor.swift` — canonical polling + wake + morningBrief pattern (lines 96, 153-186, 278-339)
- `Metamorphia/managers/ClipboardManager.swift` — `$clipboardHistory` Combine publisher
- `Metamorphia/components/Notch/NotchMarketsView.swift` — canonical tab UI pattern
- `Metamorphia/components/Live activities/PriceAlertLiveActivity.swift` — canonical alert surface
- `Metamorphia/enums/generic.swift` — `NotchState`, `NotchViews`
- `Metamorphia/models/MarketModels.swift` — `RichTurnContent` enum (already has `.newsDigest`, `.morningBrief`, `.functionGraph`)
- `Metamorphia/models/MarketDefaults.swift` — feature-flag pattern
- `Metamorphia/services/WatchlistStore.swift` — persistence + debounced write + iCloud KVS pattern
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/Skills/SkillRegistry.swift` — `/skill-name` system-prompt injection

## Phases

---

### Phase 0 — Memory tools (ghost tools)

**Goal:** `store_memory` + `recall_memory` ToolDefinitions. Currently referenced by `market-lens/SKILL.md` but not implemented.

**Build:**
- Create `Packages/MetamorphiaExecutors/Sources/MetamorphiaExecutors/Tools/MemoryTools.swift`
  - `StoreMemoryTool: ToolDefinition` — takes `{key, value, category?, keywords?}`, writes via FileMemoryStore.
  - `RecallMemoryTool: ToolDefinition` — takes `{query, category?, limit?}`, returns LTP-applying recall.
- Extend `FileMemoryStore.MemoryCategory` enum with: `.interest`, `.thesis`, `.thread`, `.entity` (each with its own tau constant — interest: 21d, thesis: 14d, thread: 7d, entity: 30d). Floor-weight for `.entity` to prevent full eviction of important entities.
- Register tools in `MetamorphiaBootstrap.swift` under `.memory` category.

**Acceptance:** An end-to-end test where a user in the command bar says "remember that my thesis on AAPL is services growth", a later turn asks "what's my AAPL thesis?", and the agent recalls it.

---

### Phase 1 — On-device entity extraction

**Goal:** sensor layer. Extract entities from every user turn + clipboard item without LLM calls.

**Build:**
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/NL/EntityExtractor.swift`
  - Uses `NaturalLanguage.NLTagger` with `.nameType` for people/organizations/places.
  - Regex supplements: tickers `\$[A-Z]{1,5}\b`, URLs (domain as entity), ISBNs, DOIs, GitHub repos.
  - Topic-noun extraction via `.lexicalClass` filtered to nouns; TF-IDF against rolling user-corpus baseline to surface top-5 unusual nouns.
  - Output: `ExtractedEntity { canonicalName, type (person|org|ticker|topic|place|url|paper|repo), surfaceForm, confidence }`.
- Canonicalization map at `~/Library/Application Support/Metamorphia/entity-aliases.json` — starts empty, learned over time.
- Hooks: call from `AICommandViewModel.submit()` pre-LLM and from `ClipboardManager.$clipboardHistory` sink.
- Back-fill historical `ConversationPersistenceService` turns on first launch (one-shot).

**Acceptance:** `"what's happening with Anthropic's constitutional AI work?"` → `[Anthropic:org, constitutional AI:topic]` in < 20ms.

---

### Phase 2 — InterestGraphStore

**Goal:** persistent, decaying, encrypted weight map of entities.

**Build:**
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/Stores/InterestGraphStore.swift`
  - `InterestNode { entityId, type, weight: SynapticStrength, lastSeen, firstSeen, coOccurrences: [entityId: Int], salienceReasons: [SalienceReason] }`
  - Persist at `~/Library/Application Support/Metamorphia/interest-graph.json`, encrypted at rest with a CryptoKit symmetric key stored in the Keychain (bundle-id-scoped).
  - Potentiation deltas:
    - Explicit query mention: +0.08
    - Clipboard copy: +0.04
    - Tool call about entity: +0.06
    - Long dwell (>8s): +0.02
    - User dismissed "boring": −0.10
  - Decay tau = 21 days semantic, floor 0.02 for eviction, max 500 nodes. Weakest-first eviction.
  - Public API: `topInterests(type:, count:)`, `score(entity:)`, `edgesOut(entity:)`, `potentiate(entity:event:)`, `prune(entity:)`.
- `InterestGraphPotentiator` (middleware) registered in `AgentLoop.makeDefaultMiddlewareChain()` — observes turns, routes extracted entities into the store.

**Acceptance:** After simulating a week of usage, `topInterests(type: .org, count: 10)` returns a sensibly ranked list.

---

### Phase 3 — Google News RSS pipeline

**Goal:** clean ingestion.

**Build:**
- `Packages/MetamorphiaExecutors/Sources/MetamorphiaExecutors/Tools/GoogleNewsService.swift` — public struct, `Sendable`. Methods: `topStories(locale:)`, `section(_: NewsSection, locale:)`, `search(query:, locale:)`. SAX parse via `XMLParser`.
- `Metamorphia/services/NewsSources.swift` — complementary free feeds: Hacker News Firebase, a curated set of primary RSS (AP, Reuters, BBC, arXiv, SEC EDGAR).
- `Packages/MetamorphiaExecutors/Sources/MetamorphiaExecutors/Tools/NewsDataTool.swift` — `news_feed` tool. Actions: `top`, `section`, `search`, `story_thread`, `since_last_check`.
- Register in `MetamorphiaBootstrap.swift` under `.webContent`.
- `AnonymizedNewsFetcher` — ephemeral URLSession, no cookies, no tracking pixel rendering.

**Acceptance:** `"what's the latest on OpenAI?"` returns cited sources with timestamps in < 2s.

---

### Phase 4 — StoryTracker

**Goal:** narrative deduplication.

**Build:**
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/News/StoryTracker.swift`
  - Cluster articles sharing ≥ 2 entities within 24h (Jaccard ≥ 0.6).
  - `Story { id, title, entities, firstSeenAt, articles: [NewsArticle], userLastCheckedAt? }`
  - Persist at `~/Library/Application Support/Metamorphia/stories.json`; evict after 30 days quiet.
  - `storiesSince(_:entity:)` returns diffs: new articles, new entities, sentiment shift.

**Acceptance:** 40 OpenAI headlines → ~4-5 clustered stories. `storiesSince(tuesday, entity: "OpenAI")` returns only new developments.

---

### Phase 5 — ThreadContinuationEngine

**Goal:** score articles by connection to user's active threads.

**Build:**
- `Packages/MetamorphiaAgentKit/Sources/MetamorphiaAgentKit/News/ThreadContinuationEngine.swift`
  - `relevance = α·Σ(entity.weight for entity in story.entities) + β·memoryHit(story, recentTurns) + γ·novelty − δ·ubiquity`
  - `memoryHit`: entity appeared in turns in last 14 days.
  - `novelty`: new entities introduced in a tracked story.
  - `ubiquity`: penalty for wide mainstream coverage.
  - Output: `ContinuationProposal { story, score, reasons: [String] }` — carries human-readable rationale.

**Acceptance:** A labeled test — 20 sample stories scored; magic-rate (user-judged "this is relevant") ≥ 40% on second-week dogfooding.

---

### Phase 6 — AttentionModel

**Goal:** learn engagement windows; gate proactive surfaces.

**Build:**
- `Metamorphia/services/AttentionModel.swift` — `@MainActor`, `.shared`.
  - Idle detection via `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .any)` polled at 30s.
  - Log every command-bar submission timestamp + every proactive surface dismissal/engagement.
  - Bucket by `(day-of-week, hour)` — per-bucket `engagementScore ∈ [0,1]`. Additive gradient with learning rate (observe → nudge; clamp [0,1]).
  - `currentScore()` returns the live multiplier. 14-day rolling horizon.
  - Encrypted persistence alongside InterestGraph.

**Acceptance:** After 2 weeks of dogfooding, surfacing respects learned quiet hours (zero surfaces during ignored windows, full surfacing during engaged windows).

---

### Phase 7 — Calendar pre-briefs (EventKit)

**Goal:** T-5 minute meeting pre-brief from native macOS Calendar.

**Build:**
- `Metamorphia/services/CalendarLens.swift` — direct EventKit integration. Request `.event` access via `EKEventStore.requestFullAccessToEvents()`.
- Poll upcoming events every 5 min; at T-15 identify attendees; at T-5, assemble `MeetingPreBrief { attendee, company, recentStories, lastConversationMentions }`.
- Canonicalize attendee emails to entity ids (reuse EntityAliases map).
- New `RichTurnContent.meetingBrief` case + optional notch-flash surface using PriceAlertLiveActivity idiom.
- One-per-meeting guard; auto-dismiss 25s.

**Acceptance:** Calendar event "Lunch with Sarah (Anthropic)" → T-5 flash with 3 recent Anthropic stories + "last spoke Tuesday".

---

### Phase 8 — Clipboard enrichment

**Goal:** generalize the finance clipboard reflex to any interest-graph entity.

**Build:**
- Extract a new `ClipboardInsights` service (don't leave everything in `MarketQuoteMonitor`). Run EntityExtractor on every clipboard item.
- If any entity hits InterestGraph with weight > 0.3, enqueue one `ContinuationProposal` into the existing `clipboardSuggestion` surface (new case of the existing enum or a sibling field).
- Keep finance-specific behavior intact via delegation.

**Acceptance:** Copying "Anthropic" → banner reads *"Anthropic · published interpretability paper · 2h ago · continues last week's thread."*

---

### Phase 9 — Morning Brief fusion

**Goal:** `MorningMarketBrief` → `MorningBrief` with multiple typed sections.

**Build:**
- Rename model → `MorningBrief` with `marketMovers`, `threadUpdates`, `meetingsToday`, `openLoops`.
- Extend `RichTurnContent.morningBrief` to carry the new shape.
- `threadUpdates` = top 3 ThreadContinuationEngine proposals since last wake, gated by AttentionModel.
- Card hard-cap 3 lines, auto-dismiss 25s, one-per-calendar-day. Update `MarketQuoteMonitor.maybePostMorningBrief()` to use the fused assembler; factor that assembler into a dedicated service so it isn't living inside the market monitor.

**Acceptance:** Wake Mac → single unified card with mixed markets + threads + meetings.

---

### Phase 10 — Predictive staging

**Goal:** answer ready before the question.

**Build:**
- `PredictiveStaging` middleware in `AgentLoop.makeDefaultMiddlewareChain()`.
- Detect patterns in command-bar submission history: entity set × time-of-day. If ≥ 4 days/week the user asks variants of "what happened overnight" within 2 min of wake, pre-compute on wake.
- Cache under TTL 10 min; attach to a staged-response slot on `AICommandViewModel`.
- When user opens command bar within TTL, render staged answer instantly (< 100ms) with a small sparkle indicator. Any new input invalidates.

**Acceptance:** After ≥ 5 days of repeating the same morning query, the sixth morning shows the staged answer instantly on notch-open.

---

### Phase 11 — Notch News tab + Story view

**Goal:** the pull surface.

**Build:**
- Add `.news` case to `NotchViews` enum in `Metamorphia/enums/generic.swift`.
- `Metamorphia/components/Notch/NotchNewsView.swift` — mirrors NotchMarketsView structure. Header: "Following N threads". Rows: title · source · *reason it's here* · relative time.
- `Metamorphia/components/News/StoryDetailView.swift` — inline-expanded story diff view.
- Route into `ContentView` `NotchViews` switch + `MetamorphiaViewCoordinator` tab order.
- Empty state: *"Nothing new on your threads"* + a single search field for exploration.

**Acceptance:** Opening News never shows a headline the user has no thread about; visuals match Markets typographic register.

---

### Phase 12 — news-lens skill

**Goal:** editorial stance.

**Build:**
- `Packages/MetamorphiaExecutors/Sources/MetamorphiaExecutors/Resources/Skills/news-lens/SKILL.md`
  - Rules: cite source + timestamp, down-rank single-source claims, prefer primary sources (SEC/papers/engineering blogs) over aggregators, always call `recall_memory` before presenting to connect to existing threads, use `story_thread` action for narrative tracking, respect AttentionModel's current score (if low, be terse).
  - Tool reference block documenting each `news_feed` action.

**Acceptance:** Invoking `/news-lens` in the command bar followed by a question triggers memory recall → news fetch → connected response chain automatically.

---

### Phase 13 — Settings & kill switches

**Goal:** shippable polish.

**Build:**
- Add `.news` to `SettingsTab` enum under an appropriate group.
- Toggles mirroring `MarketDefaults`:
  - `newsEnabled` (master)
  - `newsMorningBriefEnabled`
  - `newsClipboardEnrichmentEnabled`
  - `newsMeetingPreBriefsEnabled`
  - `newsPredictiveStagingEnabled`
  - `attentionModelEnabled`
- **Interest Graph visibility pane** — disclosure sheet showing top-50 entities with weights, each with a "forget" button that calls `InterestGraphStore.prune(entity:)`. Legibility-on-demand, invisible-by-default.

**Acceptance:** All new behaviors can be turned off individually; the interest graph can be inspected and pruned by the user.

---

## Cross-cutting build rules

- Every phase MUST compile. Run `xcodebuild -project Metamorphia.xcodeproj -scheme Metamorphia build` (or `swift build` for package-only changes) and paste the tail of the output into the report.
- NEVER introduce jargon suffixes (`Manager`, `Orchestrator`, `Provider`, `Dispatcher`, `Router`).
- NEVER add SF Mono. San Francisco body font everywhere except code rendering.
- NEVER add emojis.
- Match existing file layout conventions. New package files go under the relevant `Sources/<module>/<subdir>/` tree; app-target files go under `Metamorphia/services/`, `Metamorphia/models/`, `Metamorphia/components/...`.
- Preserve existing public API shapes unless the phase spec says otherwise (renames require migration).
- Where persistence is introduced, reuse `WatchlistStore`'s debounced atomic-write pattern.
- Where polling is introduced, avoid cadences already in use (0.5s clipboard, 1s stats/timer, 3s Bluetooth, 4s ticker). Use 2.5s, 5s, 10s, 30s, 45s, 60s slots.
- All new persistent on-device data about the user (InterestGraph, AttentionModel, stories) is encrypted at rest via a Keychain-scoped CryptoKit key.
