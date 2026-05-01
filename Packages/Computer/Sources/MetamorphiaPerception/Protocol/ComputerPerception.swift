import Foundation
import CoreGraphics

// MARK: - Protocol Boundary

/// The primary protocol that external consumers (e.g., Executer) code against.
/// Decouples consumers from ComputerLib's concrete types, enabling testing and alternative backends.
public protocol ComputerPerception: Sendable {

    // MARK: - Perception

    /// Capture the current screen state.
    func capture(forceOCR: Bool, appFilter: String?) async -> ScreenMap

    /// Capture with an explicit OCR policy override (Rank 7). Supersedes
    /// `forceOCR` when both are provided. See `OCRPolicy` for available modes.
    func capture(forceOCR: Bool, appFilter: String?, ocrOverride: OCRPolicy) async -> ScreenMap

    /// Invalidate any caches, forcing fresh data on next capture.
    func invalidateCache()

    /// Install bootstrap app profiles (Rank 7). Idempotent — safe to call at any
    /// time, will not clobber user-refined or auto-built profiles. Called
    /// automatically by `PerceptionPipeline.init`; external consumers building
    /// their own pipeline can invoke this from their own bootstrap.
    func installBootstrapProfiles()

    /// Rank 7 — cheap seed-aware OCR-need check. Returns `true` if the app is
    /// known to need OCR, `false` if AX-rich, `nil` if neither a seed nor a
    /// live profile exists for the bundle.
    func appProfileIsOCRRequired(bundleID: String) -> Bool?

    // MARK: - Streaming Perception (10 Hz background loop)

    /// Start the background perception loop at `targetHz`. Safe to call when already
    /// running — updates the rate without restarting. Emits `ScreenMap`s over the stream
    /// returned by `observePerceptionStream()` — only when the screen actually changes.
    func startPerceptionLoop(targetHz: Double) async

    /// Stop the background perception loop. In-flight captures complete; subscribers
    /// see no new frames. Safe to call when already stopped.
    func stopPerceptionLoop() async

    /// Subscribe to the perception stream. Each call returns a fresh AsyncStream with
    /// latest-wins backpressure — slow consumers see only the newest frame. Emits
    /// only when content has changed (dHash / element-set / browser-DOM gate in
    /// `PerceptionLoop`). Entirely local — no network calls beyond localhost.
    func observePerceptionStream() -> AsyncStream<ScreenMap>

    // MARK: - Menu Bar Invocation (non-screenshot path)

    /// Invoke a menu item in the frontmost app by its title path (e.g. `["File", "Save"]`).
    /// The implementation re-walks the live AX tree at dispatch time and dispatches via
    /// `AXUIElementPerformAction(kAXPressAction)` — no pixels, no cursor, no clicks.
    /// Returns `true` on a successful press, `false` if the path could not be resolved
    /// or the target item is disabled.
    func invokeMenu(path: [String], pid: pid_t) -> Bool

    // MARK: - Change Detection

    /// Diff two screen maps to find what changed.
    func diff(previous: ScreenMap, current: ScreenMap) -> ChangeDetector.ScreenDiff

    /// Quick visual change check via perceptual hash (< 1ms).
    func hasVisualChange(previousHash: UInt64, currentHash: UInt64, threshold: Int) -> Bool

    // MARK: - Element Resolution

    /// Find an element by its @eN reference string in a given map.
    func findByRef(_ refString: String, in map: ScreenMap) -> ScreenElement?

    // MARK: - Safety

    /// Check if an element is dangerous in its current context.
    func classifyDanger(element: ScreenElement, appBundleID: String?, windowTitle: String) -> DangerDetector.DangerResult

    /// Run full safety scan on elements.
    func scanSafety(elements: [ScreenElement], appBundleID: String?, windowTitle: String) -> SafetyReport

    // MARK: - Action Suggestion

    /// Suggest actions to achieve a goal given the current screen state.
    func suggestActions(goal: String, map: ScreenMap) -> ActionSuggester.ActionPlan

    // MARK: - Shortcuts

    /// Discover keyboard shortcuts for the frontmost app.
    func discoverShortcuts() -> [ShortcutAdvisor.Shortcut]

    /// Format shortcuts for LLM context injection.
    func formatShortcuts(_ shortcuts: [ShortcutAdvisor.Shortcut]) -> String

    // MARK: - Output Formatting

    /// Format a ScreenMap as compact text for LLM consumption.
    func formatForLLM(_ map: ScreenMap) -> String

    /// Format a ScreenMap as token-efficient JSON.
    func formatAsJSON(_ map: ScreenMap) -> String

    /// Format a ScreenMap as compact text with an explicit filter policy.
    /// Rank 1 — lets callers dial in `.aggressive` for token-constrained
    /// contexts or `.permissive` for local debugging.
    func formatForLLM(_ map: ScreenMap, policy: FilterPolicy) -> String

    /// Format a ScreenMap as token-efficient JSON with an explicit filter
    /// policy. Rank 1.
    func formatAsJSON(_ map: ScreenMap, policy: FilterPolicy) -> String

    /// Apply the visibility filter directly and return the detailed
    /// `FilterResult`. Callers who need per-rule drop counters (telemetry,
    /// debugging) use this instead of the two formatters above. Rank 1.
    func applyFilter(_ map: ScreenMap, policy: FilterPolicy) -> FilterResult

    // MARK: - Delta Encoding (Rank 2)

    /// Rank 2 — Capture a fresh `ScreenMap` and diff against the session's
    /// previous capture. On the first call for a session, returns a baseline
    /// payload containing the full snapshot JSON; subsequent calls return a
    /// ref-partitioned delta (added / removedRefs / changed / retained) plus
    /// filter and meta deltas. The session key is opaque — callers choose
    /// it (default `"default"` is fine for a single-user tool).
    func captureDelta(sessionID: String, policy: FilterPolicy) async -> DeltaPayload

    /// Drop the cached snapshot for a session so the next `captureDelta`
    /// call emits a fresh baseline. Useful when the agent knows the screen
    /// has changed radically (app switch, screen lock, etc.).
    func resetDeltaSession(sessionID: String) async

    /// Format a `DeltaPayload` as LLM-ready text via
    /// `TextFormatter.formatDelta`.
    func formatDeltaForLLM(_ payload: DeltaPayload, maxElements: Int) -> String

    /// Format a `DeltaPayload` as compact JSON via `DeltaEncoder.encode`.
    func formatDeltaAsJSON(_ payload: DeltaPayload) -> String

    // MARK: - Vision Diffs (Rank 8)

    /// Rank 8 — Capture a fresh map and build a cropped `VisionDiff` against
    /// the session's previous capture. Returns nil on the first call of the
    /// session (no previous map to diff against) or when no meaningful
    /// change is detected. Reuses the retained full-resolution image from
    /// `PerceptionPipeline.visualDiffState` to avoid a second screenshot;
    /// falls back to a fresh display capture when nothing is retained.
    ///
    /// Session state is shared with `captureDelta` (same `SnapshotCache`), so
    /// chaining `screen_delta` → `vision_diff` on the same session ID reuses
    /// the same previous-map cache.
    func visionDiff(sessionID: String, policy: VisionDiffPolicy) async -> VisionDiff?

    /// Rank 8 — multi-display variant. Captures every attached display and
    /// returns per-display cropped diffs. Primary is the display with the
    /// largest change area.
    func visionDiffMultiDisplay(sessionID: String, policy: VisionDiffPolicy) async -> MultiDisplayVisionDiff?

    // MARK: - Query (Rank 6)

    /// Parse a selector string into a `Selector` without running it. Pass
    /// the result to `execute` or reuse it across captures. Raises
    /// `QueryError` on any malformed / unknown construct.
    func parseSelector(_ raw: String) throws -> Selector

    /// Run a selector against a specific `ScreenMap`. Uses the pipeline's
    /// current tier snapshot and the given options. Callers that hold a
    /// map already (e.g. tests, delta consumers) should prefer this — it's
    /// purely synchronous and does no capture.
    func query(_ selector: String, in map: ScreenMap, options: QueryOptions) throws -> [QueryResult]

    /// Run a selector against the latest capture. When `sessionID` is set,
    /// the cached map from `SnapshotCache.shared.fetch(sessionID:)` is used
    /// (no new capture); nil falls through to a fresh `capture()`. This
    /// makes the query cheap to chain after `screen_perceive(session_id:)`.
    func query(_ selector: String, sessionID: String?, options: QueryOptions) async throws -> [QueryResult]

    // MARK: - Learning

    /// Record that the agent successfully interacted with an element.
    func recordSuccess(element: ScreenElement, appBundleID: String?)

    /// Record that the agent failed to interact correctly with an element.
    func recordFailure(element: ScreenElement, appBundleID: String?)

    /// Process a user correction (wrong element → correct element).
    func processCorrection(_ correction: CorrectionLoop.Correction, map: ScreenMap)

    /// Get confusion pattern summary for LLM context injection.
    func confusionSummary(appBundleID: String?) -> String?

    /// Get the app profile for an app (OCR needed, AX coverage, etc.)
    func appProfile(bundleID: String) -> AppProfileRecord?

    // MARK: - Undo

    /// Check the current undo/redo state of the frontmost app.
    func checkUndoState() -> UndoAdvisor.UndoState
}

// MARK: - Default Parameter Extensions

public extension ComputerPerception {
    func capture() async -> ScreenMap {
        await capture(forceOCR: false, appFilter: nil)
    }

    /// Rank 7 — convenience overload for callers that only want to pick a
    /// policy. Delegates to the full three-arg signature with `forceOCR:
    /// false`. When `ocrOverride != .auto`, the policy wins.
    func capture(ocrOverride: OCRPolicy) async -> ScreenMap {
        await capture(forceOCR: false, appFilter: nil, ocrOverride: ocrOverride)
    }

    /// Legacy two-arg overload default — preserves source compat for
    /// conformers that pre-date Rank 7. Delegates to the policy-aware variant
    /// with `ocrOverride: .auto` so the `forceOCR` flag still gates sync OCR.
    func capture(forceOCR: Bool, appFilter: String?) async -> ScreenMap {
        await capture(forceOCR: forceOCR, appFilter: appFilter, ocrOverride: .auto)
    }

    func hasVisualChange(previousHash: UInt64, currentHash: UInt64) -> Bool {
        hasVisualChange(previousHash: previousHash, currentHash: currentHash, threshold: 5)
    }

    /// Default-policy variant of `applyFilter` for callers that just want the
    /// standard pass. Rank 1.
    func applyFilter(_ map: ScreenMap) -> FilterResult {
        applyFilter(map, policy: .default)
    }

    /// Rank 2 — default-policy + default-session overload for
    /// `captureDelta`. Callers with simpler needs reach for this one.
    func captureDelta() async -> DeltaPayload {
        await captureDelta(sessionID: "default", policy: .default)
    }

    /// Rank 2 — default maxElements overload for the text formatter.
    func formatDeltaForLLM(_ payload: DeltaPayload) -> String {
        formatDeltaForLLM(payload, maxElements: 120)
    }

    /// Rank 6 — default-options overload for the sync query API.
    func query(_ selector: String, in map: ScreenMap) throws -> [QueryResult] {
        try query(selector, in: map, options: QueryOptions())
    }

    /// Rank 6 — default-options overload for the async / session query API.
    func query(_ selector: String, sessionID: String? = nil) async throws -> [QueryResult] {
        try await query(selector, sessionID: sessionID, options: QueryOptions())
    }

    /// Rank 8 — default-policy overload for the single-display vision diff.
    func visionDiff(sessionID: String = "default") async -> VisionDiff? {
        await visionDiff(sessionID: sessionID, policy: .default)
    }

    /// Rank 8 — default-policy overload for the multi-display variant.
    func visionDiffMultiDisplay(sessionID: String = "default") async -> MultiDisplayVisionDiff? {
        await visionDiffMultiDisplay(sessionID: sessionID, policy: .default)
    }
}
