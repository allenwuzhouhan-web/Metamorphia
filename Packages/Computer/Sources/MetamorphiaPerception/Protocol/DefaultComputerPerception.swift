import Foundation
import CoreGraphics

/// Default concrete implementation of `ComputerPerception` that wraps existing ComputerLib subsystems.
/// This is what Executer uses at runtime. Tests can substitute a mock conformance instead.
public final class DefaultComputerPerception: ComputerPerception, @unchecked Sendable {
    // `internal` so Rank 2 delta helpers in this target can reach the pipeline
    // for `refStabilizer.tierSnapshot()`. External modules still go through
    // the protocol surface below.
    let pipeline: PerceptionPipeline
    private let db: ElementDatabase
    /// Snapshot cache for delta sessions. Actor-isolated — safe to share.
    private let deltaCache: SnapshotCache

    public init(
        pipeline: PerceptionPipeline = .shared,
        db: ElementDatabase = .shared,
        deltaCache: SnapshotCache = .shared
    ) {
        self.pipeline = pipeline
        self.db = db
        self.deltaCache = deltaCache
    }

    // Singleton for convenience — mirrors the old PerceptionPipeline.shared pattern.
    public static let shared = DefaultComputerPerception()

    // MARK: - Perception

    public func capture(forceOCR: Bool, appFilter: String?) async -> ScreenMap {
        // Default to `.auto` policy — equivalent to today's behavior plus Rank
        // 7's seed-aware skip-screenshot optimization.
        await capture(forceOCR: forceOCR, appFilter: appFilter, ocrOverride: .auto)
    }

    /// Rank 7 — policy-aware capture with auto-profile learning.
    public func capture(forceOCR: Bool, appFilter: String?, ocrOverride: OCRPolicy) async -> ScreenMap {
        let map = await pipeline.capture(
            forceOCR: forceOCR,
            appFilter: appFilter,
            ocrOverride: ocrOverride
        )

        // Auto-profile for learning. Live auto-profiles win over seeds after
        // one capture — see `AppProfileSeeds.installIfNeeded` rules.
        AppProfile.autoProfile(map: map, db: db)

        return map
    }

    public func invalidateCache() {
        pipeline.invalidateCache()
    }

    public func installBootstrapProfiles() {
        AppProfileSeeds.installIfNeeded(into: db)
    }

    public func appProfileIsOCRRequired(bundleID: String) -> Bool? {
        // Live profile trumps seed — both are assembled from the same source
        // of truth (ElementDatabase), but a live auto-profile reflects this
        // machine's state better than a seed guess.
        if let live = db.getAppProfile(bundleID: bundleID) {
            return live.needsOCR
        }
        // Fall back to seed data directly so callers who didn't install seeds
        // (e.g. custom pipelines) still get a useful answer.
        return AppProfileSeeds.seedFor(bundleID: bundleID)?.needsOCR
    }

    // MARK: - Streaming Perception

    public func startPerceptionLoop(targetHz: Double) async {
        await PerceptionLoop.shared.start(targetHz: targetHz)
    }

    public func stopPerceptionLoop() async {
        await PerceptionLoop.shared.stop()
    }

    public func observePerceptionStream() -> AsyncStream<ScreenMap> {
        PerceptionLoop.shared.observe()
    }

    // MARK: - Menu Bar Invocation

    public func invokeMenu(path: [String], pid: pid_t) -> Bool {
        MenuBarReader.invoke(path: path, pid: pid)
    }

    // MARK: - Change Detection

    public func diff(previous: ScreenMap, current: ScreenMap) -> ChangeDetector.ScreenDiff {
        ChangeDetector.diff(previous: previous, current: current)
    }

    public func hasVisualChange(previousHash: UInt64, currentHash: UInt64, threshold: Int) -> Bool {
        ChangeDetector.hasVisualChange(previousHash: previousHash, currentHash: currentHash, threshold: threshold)
    }

    // MARK: - Element Resolution

    public func findByRef(_ refString: String, in map: ScreenMap) -> ScreenElement? {
        Disambiguator.findByRef(refString, in: map)
    }

    // MARK: - Safety

    public func classifyDanger(element: ScreenElement, appBundleID: String?, windowTitle: String) -> DangerDetector.DangerResult {
        let context = DangerDetector.ScanContext(appBundleID: appBundleID, windowTitle: windowTitle)
        return DangerDetector.classify(element: element, context: context)
    }

    public func scanSafety(elements: [ScreenElement], appBundleID: String?, windowTitle: String) -> SafetyReport {
        SafetyScanner.scan(elements: elements, appBundleID: appBundleID, windowTitle: windowTitle)
    }

    // MARK: - Action Suggestion

    public func suggestActions(goal: String, map: ScreenMap) -> ActionSuggester.ActionPlan {
        let shortcuts = discoverShortcuts()
        return ActionSuggester.suggest(goal: goal, in: map, shortcuts: shortcuts, db: db)
    }

    // MARK: - Shortcuts

    public func discoverShortcuts() -> [ShortcutAdvisor.Shortcut] {
        ShortcutAdvisor.discoverShortcuts()
    }

    public func formatShortcuts(_ shortcuts: [ShortcutAdvisor.Shortcut]) -> String {
        ShortcutAdvisor.formatForLLM(shortcuts)
    }

    // MARK: - Output Formatting

    public func formatForLLM(_ map: ScreenMap) -> String {
        TextFormatter.format(map)
    }

    public func formatAsJSON(_ map: ScreenMap) -> String {
        SnapshotEncoder.encode(map)
    }

    // Rank 1 — policy-aware overloads.

    public func formatForLLM(_ map: ScreenMap, policy: FilterPolicy) -> String {
        // Route through the filter-result overload so we compute the
        // stabilizer tier snapshot exactly once and share it with the
        // formatter. Keeps tier-rescue consistent across the two encoders.
        let tierSnapshot = pipeline.refStabilizer.tierSnapshot()
        let result = ElementFilter.apply(map.elements, in: map, policy: policy, tierSnapshot: tierSnapshot)
        return TextFormatter.format(map, maxElements: 120, filterResult: result)
    }

    public func formatAsJSON(_ map: ScreenMap, policy: FilterPolicy) -> String {
        let tierSnapshot = pipeline.refStabilizer.tierSnapshot()
        let result = ElementFilter.apply(map.elements, in: map, policy: policy, tierSnapshot: tierSnapshot)
        return SnapshotEncoder.encode(map, filterResult: result)
    }

    public func applyFilter(_ map: ScreenMap, policy: FilterPolicy) -> FilterResult {
        let tierSnapshot = pipeline.refStabilizer.tierSnapshot()
        return ElementFilter.apply(map.elements, in: map, policy: policy, tierSnapshot: tierSnapshot)
    }

    // MARK: - Delta Encoding (Rank 2)

    public func captureDelta(sessionID: String, policy: FilterPolicy) async -> DeltaPayload {
        // Snapshot the previous entry BEFORE we capture — the new capture
        // rotates the pipeline's ref stabilizer internally, so reading
        // previous tiers after capture would give us the current ones.
        let previousEntry = await deltaCache.fetch(sessionID: sessionID)

        let current = await capture(forceOCR: false, appFilter: nil, ocrOverride: .auto)
        let currentTiers = pipeline.refStabilizer.tierSnapshot()

        let sequence = await deltaCache.nextSequenceNumber(for: sessionID)

        let payload = DeltaEncoder.buildPayload(
            previous: previousEntry?.map,
            current: current,
            previousTiers: previousEntry?.tiers,
            currentTiers: currentTiers,
            sessionID: sessionID,
            sequenceNumber: sequence,
            policy: policy
        )

        // Store the new snapshot + tiers so the next call can diff against it.
        await deltaCache.store(sessionID: sessionID, map: current, tiers: currentTiers)

        return payload
    }

    public func resetDeltaSession(sessionID: String) async {
        await deltaCache.reset(sessionID: sessionID)
    }

    public func formatDeltaForLLM(_ payload: DeltaPayload, maxElements: Int) -> String {
        // Pure sync path. For baselines the caller receives a header-only
        // indicator; the full snapshot tree is still available via
        // `formatDeltaAsJSON(payload)` (which embeds the full JSON) or via
        // the async `formatDeltaForLLMAsync` that consults the snapshot
        // cache. Keeping this function sync preserves the legacy
        // `formatForLLM(_:)` call-site shape.
        DeltaEncoder.encodeText(payload, maxElements: maxElements)
    }

    /// Rank 2 — async overload that renders a full TextFormatter tree for
    /// baseline captures by consulting the snapshot cache. Delta captures
    /// route to the same synchronous summary. Use this when the caller
    /// wants the LLM to see the full screen on the first capture.
    public func formatDeltaForLLMAsync(_ payload: DeltaPayload, maxElements: Int = 120) async -> String {
        if payload.isBaseline {
            if let entry = await deltaCache.fetch(sessionID: payload.sessionID) {
                return TextFormatter.formatBaseline(
                    entry.map,
                    sequenceNumber: payload.sequenceNumber,
                    sessionID: payload.sessionID,
                    maxElements: maxElements
                )
            }
        }
        return DeltaEncoder.encodeText(payload, maxElements: maxElements)
    }

    public func formatDeltaAsJSON(_ payload: DeltaPayload) -> String {
        DeltaEncoder.encode(payload)
    }

    // MARK: - Vision Diffs (Rank 8)

    public func visionDiff(sessionID: String, policy: VisionDiffPolicy) async -> VisionDiff? {
        // Snapshot the previous map BEFORE capturing — the new capture
        // rotates the stabilizer and overwrites the retained image.
        let previousEntry = await deltaCache.fetch(sessionID: sessionID)

        // Capture fresh. We intentionally do NOT route through captureDelta
        // (avoids bumping the sequence counter) — the caller may be chaining
        // screen_delta + vision_diff and we don't want to double-increment.
        let current = await capture(forceOCR: false, appFilter: nil, ocrOverride: .auto)
        let currentTiers = pipeline.refStabilizer.tierSnapshot()

        // Update the cache so the next call in this session can diff against
        // the fresh map.
        await deltaCache.store(sessionID: sessionID, map: current, tiers: currentTiers)

        // First call → no previous map → nothing to diff against. Return nil
        // so callers can detect "baseline, no vision needed yet".
        guard let previous = previousEntry?.map else { return nil }

        let mainDisplayIndex = current.displays.first(where: \.isMain)?.index ?? 0

        // Retained image path: use the freshly-retained full-res image from
        // the pipeline's VisualDiffState. Fall back to a fresh captureDisplay
        // if nothing was retained (e.g. permission denied or first-ever call
        // in this process).
        let cgImage: CGImage? = await {
            if let retained = await pipeline.visualDiffState.fetch(displayIndex: mainDisplayIndex) {
                return retained.value
            }
            if let fresh = ScreenCapture.captureDisplay(index: mainDisplayIndex) {
                return fresh
            }
            // Last-resort: main-display capture.
            return ScreenCapture.captureMainDisplay()
        }()

        // No image available (e.g. capture failed / permission revoked).
        // Bail gracefully — consistent with the no-previous-map case above.
        guard let cgImage else { return nil }

        return VisionDiffer.diff(
            previous: previous,
            current: current,
            currentImage: cgImage,
            tiers: currentTiers,
            policy: policy,
            sessionID: sessionID
        )
    }

    public func visionDiffMultiDisplay(sessionID: String, policy: VisionDiffPolicy) async -> MultiDisplayVisionDiff? {
        let previousEntry = await deltaCache.fetch(sessionID: sessionID)
        let current = await capture(forceOCR: false, appFilter: nil, ocrOverride: .auto)
        let currentTiers = pipeline.refStabilizer.tierSnapshot()

        await deltaCache.store(sessionID: sessionID, map: current, tiers: currentTiers)

        guard let previous = previousEntry?.map else { return nil }

        // Prefer retained per-display images; fall back to fresh captures for
        // displays that don't have a retained frame yet.
        var imagesByDisplay: [Int: CGImage] = [:]
        let retained = await pipeline.visualDiffState.fetchAll()
        for (idx, img) in retained {
            imagesByDisplay[idx] = img.value
        }
        for display in current.displays where imagesByDisplay[display.index] == nil {
            if let fresh = ScreenCapture.captureDisplay(index: display.index) {
                imagesByDisplay[display.index] = fresh
            }
        }

        return VisionDiffer.diffMultiDisplay(
            previous: previous,
            current: current,
            currentImagesByDisplay: imagesByDisplay,
            tiers: currentTiers,
            policy: policy,
            sessionID: sessionID
        )
    }

    // MARK: - Query (Rank 6)

    public func parseSelector(_ raw: String) throws -> Selector {
        try QueryEngine.parse(raw)
    }

    public func query(_ selector: String, in map: ScreenMap, options: QueryOptions) throws -> [QueryResult] {
        let tiers = pipeline.refStabilizer.tierSnapshot()
        return try QueryEngine.query(selector, in: map, tiers: tiers, options: options)
    }

    public func query(_ selector: String, sessionID: String?, options: QueryOptions) async throws -> [QueryResult] {
        // Parse first so bad selectors fail cheaply without a capture.
        let parsed = try QueryEngine.parse(selector)
        let map: ScreenMap
        let tiers: [ElementRef: IdentityTier]
        if let sessionID, let cached = await deltaCache.fetch(sessionID: sessionID) {
            // Use cached map and tiers — the delta pipeline just rotated the
            // stabilizer, so fresh `tierSnapshot()` would be from the next
            // frame, not the frame the map belongs to.
            map = cached.map
            tiers = cached.tiers
        } else {
            map = await capture(forceOCR: false, appFilter: nil, ocrOverride: .auto)
            tiers = pipeline.refStabilizer.tierSnapshot()
        }
        return QueryEngine.execute(parsed, in: map, tiers: tiers, options: options)
    }

    // MARK: - Learning

    public func recordSuccess(element: ScreenElement, appBundleID: String?) {
        let hash = UnknownElementHandler.elementHash(element: element, appBundleID: appBundleID)
        db.recordCorrectMatch(hash: hash)
    }

    public func recordFailure(element: ScreenElement, appBundleID: String?) {
        let hash = UnknownElementHandler.elementHash(element: element, appBundleID: appBundleID)
        db.recordWrongMatch(hash: hash)
    }

    public func processCorrection(_ correction: CorrectionLoop.Correction, map: ScreenMap) {
        CorrectionLoop.process(correction: correction, currentMap: map, db: db)
    }

    public func confusionSummary(appBundleID: String?) -> String? {
        CorrectionLoop.confusionSummary(appBundleID: appBundleID, db: db)
    }

    public func appProfile(bundleID: String) -> AppProfileRecord? {
        db.getAppProfile(bundleID: bundleID)
    }

    // MARK: - Undo

    public func checkUndoState() -> UndoAdvisor.UndoState {
        UndoAdvisor.checkUndoState()
    }
}
