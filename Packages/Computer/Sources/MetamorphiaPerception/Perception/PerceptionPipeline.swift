import Foundation
import CoreGraphics
import AppKit

// MARK: - OCR Policy (Rank 7)

/// Call-time override for the pipeline's OCR decision. See `OCRDecision` for
/// the gating matrix. Default is `.auto` — backward-compatible with pre-Rank-7
/// behavior plus the new "skip screenshot when AX-rich profile allows" shortcut.
public enum OCRPolicy: Sendable {
    /// Default. Seed-aware gating: AX-sufficient + profile says no-OCR → skip screenshot
    /// entirely. AX-insufficient + profile needs OCR → synchronous OCR. Everything
    /// else falls back to AX-only return + schedule background OCR. See the
    /// decision matrix in `OCRDecision.decide(...)`.
    case auto
    /// Force synchronous OCR this capture. Equivalent to the legacy `forceOCR: true`
    /// flag. Captures a fresh screenshot (or reuses the dHash one) and runs OCR
    /// inline so merged elements land in the returned `ScreenMap`.
    case require
    /// Skip OCR. No OCR-use screenshot. `dHash` screenshot is still captured for
    /// change detection (PerceptionLoop needs it). Fastest path.
    case skip
    /// Always schedule OCR to run in the background; return AX-only this call.
    /// Previous pending OCR (if any) is still merged into this capture.
    case async
}

/// Pure decision helper — exposed `internal` for direct unit testing without a
/// live screenshot pipeline. Wall-clock gating logic flows through this single
/// switch, so tests can lock down the 4×4 behavior table in isolation.
internal enum OCRDecision: Sendable, Equatable {
    case skipAll
    case syncOCR
    case scheduleBackground
    case mergePendingOnly

    static func decide(
        policy: OCRPolicy,
        axSufficient: Bool,
        profileNeedsOCR: Bool,
        hasPendingOCR: Bool
    ) -> OCRDecision {
        switch policy {
        case .require:
            return .syncOCR
        case .skip:
            return .skipAll
        case .async:
            return .scheduleBackground
        case .auto:
            if axSufficient && !profileNeedsOCR {
                // Fastest path: AX is rich and the profile says OCR is a waste
                // here. Skip the screenshot + OCR entirely.
                return .skipAll
            }
            if !axSufficient && profileNeedsOCR {
                // Canvas / pixel-heavy apps where AX is thin: sync OCR so the
                // caller's first snapshot already has text.
                return .syncOCR
            }
            if !axSufficient && hasPendingOCR {
                // We have background OCR from a prior tick — fold it in and
                // skip redundant work this capture.
                return .mergePendingOnly
            }
            // AX sufficient but profile asks for OCR (enrichment), or AX
            // insufficient with no pending → kick off background OCR.
            return .scheduleBackground
        }
    }
}

/// Orchestrates the full perception pipeline: AX tree → OCR fallback → fusion → ScreenMap.
/// Target: <250 ms typical, <500 ms worst case.
///
/// **Async OCR Fusion**: When OCR isn't forced, the pipeline returns AX-only results
/// immediately and schedules OCR in the background. The enriched results are merged
/// into the next capture or fanned out via `onOCREnrichment`.
///
/// **Rank 3 — Parallel async pipeline.** The independent phase-A work (AX read,
/// window enumeration, display snapshot, dHash screenshot, menu bar read) runs
/// concurrently on background executors via `async let`. Phase-B work (safety
/// scan, temporal state, off-screen detection, fusion) then consumes the joined
/// results. Mutable pipeline state is isolated behind two internal actors
/// (`CaptureCache` and `AsyncOCRState`) so `capture()` is safe to call from any
/// number of concurrent tasks.
///
/// **Rank 7 — Smart on-demand OCR.** The new `ocrOverride: OCRPolicy` parameter
/// lets callers force, skip, or defer OCR independently of the legacy `forceOCR`
/// flag. Seed profiles (`AppProfileSeeds`) pre-populate known app behaviors so
/// first-run captures don't fall through to the slow-path ambiguity. The dHash
/// screenshot is retained and reused by the sync-OCR branch, halving screen
/// capture work on the OCR path.
public final class PerceptionPipeline: @unchecked Sendable {
    // Rationale for `@unchecked Sendable`:
    // - `refStabilizer` is `@unchecked Sendable` (NSLock-protected).
    // - `lastSnapshot` / `lastSnapshotTime` live in `CaptureCache` (actor).
    // - `pendingOCR` state lives in `AsyncOCRState` (actor).
    // - `cacheTTL` is read-during-capture only and is a plain Double; set-once at init time
    //   in practice. Races here produce at most a one-tick cache hit/miss difference.
    // - `onOCREnrichment` is read under a pipeline-internal lock (see `ocrEnrichmentLock`).
    public static let shared = PerceptionPipeline()

    public let refStabilizer = RefStabilizer()

    // MARK: - Cache config

    public var cacheTTL: TimeInterval = 0.2

    // MARK: - Isolated state

    private let cache = CaptureCache()
    private let ocrState = AsyncOCRState()

    /// Rank 8 — retains the most-recent full-resolution screenshot per display so
    /// `VisionDiffer` can crop a diff region without re-capturing. Populated at
    /// the tail of `capture()` via a detached non-blocking store, but only once a
    /// vision-diff consumer has fetched (see `VisualDiffState.isActive`) — so the
    /// 10 Hz perception loop doesn't pin a full-screen frame in memory when nobody
    /// uses the vision-diff API. Actor-isolated and LRU-capped internally.
    public let visualDiffState = VisualDiffState()

    // MARK: - Callbacks

    /// Callback fired when background OCR enrichment completes (for SSE streaming).
    /// Must be `@Sendable` — invoked from a detached task on a background queue.
    private let ocrEnrichmentLock = NSLock()
    private var _onOCREnrichment: (@Sendable ([ScreenElement]) -> Void)?
    public var onOCREnrichment: (@Sendable ([ScreenElement]) -> Void)? {
        get {
            ocrEnrichmentLock.lock()
            defer { ocrEnrichmentLock.unlock() }
            return _onOCREnrichment
        }
        set {
            ocrEnrichmentLock.lock()
            defer { ocrEnrichmentLock.unlock() }
            _onOCREnrichment = newValue
        }
    }

    public init() {
        // Rank 7 — install bootstrap app profiles so first-run captures can
        // make the right OCR decision immediately. Idempotent; see
        // `AppProfileSeeds.installIfNeeded`.
        AppProfileSeeds.installIfNeeded()
    }

    public func invalidateCache() {
        // Synchronous contract preserved. Clearing the actors' state is
        // best-effort fire-and-forget: even if the Task hasn't started by
        // the time the next `capture()` call runs, that call's TTL check
        // will still miss because the actor resolves sequentially.
        Task { [cache, ocrState, visualDiffState] in
            await cache.clear()
            await ocrState.cancelAndClear()
            // Release the retained full-res vision-diff frame and reset
            // retention to inactive — it re-arms the next time a vision-diff
            // consumer fetches.
            await visualDiffState.clear()
        }
        AXReader.invalidateCache()
    }

    // MARK: - Capture

    /// Full perception: AX tree first, screenshot+OCR fallback if AX is insufficient.
    ///
    /// **Async OCR behavior**: When `forceOCR` is false and AX tree has sufficient interactive
    /// elements, OCR runs in the background. The current call returns AX-only results immediately.
    /// If a previous background OCR has completed, its results are merged into this capture.
    ///
    /// **Rank 7**: `ocrOverride` supersedes `forceOCR` when set to anything other than `.auto`.
    /// Legacy callers (`capture()`, `capture(forceOCR: true)`) work unchanged — `forceOCR: true`
    /// with `.auto` override resolves to `.require`. New callers pick an `OCRPolicy` directly.
    public func capture(
        forceOCR: Bool = false,
        appFilter: String? = nil,
        ocrOverride: OCRPolicy = .auto
    ) async -> ScreenMap {
        // Resolve the effective policy. `ocrOverride == .auto` (default) and
        // `forceOCR == true` promotes to `.require` for backward-compat.
        let effectivePolicy: OCRPolicy = {
            if ocrOverride != .auto { return ocrOverride }
            return forceOCR ? .require : .auto
        }()

        // Cache short-circuit BEFORE launching any subtasks. A cache hit returns
        // in ~microseconds and completely bypasses the parallel fan-out below.
        // Skip the cache when OCR is forced — caller wants fresh pixels.
        let allowCacheHit = (effectivePolicy != .require)
        if allowCacheHit, let cached = await cache.hit(ttl: cacheTTL) {
            return cached.map
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Snapshot NSScreen-derived values on the calling thread so the detached
        // subtasks don't have to reach into AppKit concurrently.
        let scaleFactor = Int(NSScreen.main?.backingScaleFactor ?? 2)
        let frontAppSnapshot = NSWorkspace.shared.frontmostApplication
        let frontPid: pid_t = frontAppSnapshot?.processIdentifier ?? 0

        // MARK: Phase A — independent subtasks run in parallel.
        //
        // Each `async let` hops onto the global cooperative pool and races the
        // others. The `await` below is the join point where results are
        // consumed; until then nothing blocks the calling task.

        async let axResultTask: PhaseAResult<AXReader.AXReadResult?> = Self.runPhase {
            // Pass `viewport: nil`. `AXReader` auto-derives the viewport from
            // the focused window bounds inside `readApp`, which is both more
            // accurate than a union-of-displays viewport (it excludes
            // off-screen or minimized windows) and preserves the pre-Rank-3
            // behavior byte-for-byte.
            if let filter = appFilter {
                let targetApp = NSWorkspace.shared.runningApplications.first {
                    $0.localizedName?.lowercased() == filter.lowercased()
                }
                guard let app = targetApp else { return nil }
                return AXReader.readApp(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? filter,
                    bundleID: app.bundleIdentifier,
                    viewport: nil
                )
            }
            return AXReader.readFrontmostApp(viewport: nil)
        }

        async let windowsTask: PhaseAResult<[WindowInfo]> = Self.runPhase {
            let all = WindowEnumerator.allWindows()
            if let filter = appFilter {
                return all.filter { $0.appName.lowercased() == filter.lowercased() }
            }
            return all
        }

        async let displaysTask: PhaseAResult<[DisplayInfo]> = Self.runPhase {
            WindowEnumerator.allDisplays()
        }

        // Rank 7: the dHash phase retains the full-res screenshot so the OCR
        // branch can reuse it instead of re-capturing. When the policy tells us
        // OCR will definitely not run (`.skip` plus PerceptionLoop isn't
        // gating on dHash — but PerceptionLoop *does* use dHash, so we still
        // capture for change detection), we keep the capture; when the policy
        // tells us OCR will definitely run, the image is available to hand off
        // without a second screenshot.
        async let dhashTask: PhaseAResult<DHashResult> = Self.runPhase {
            // Best-effort main-display capture for change detection (dHash) and
            // potential OCR reuse. We run on a background executor —
            // `CGWindowListCreateImage` is fine off the main thread. A `nil`
            // image means the capture failed (e.g. screen recording permission
            // missing) — the rest of the pipeline still produces a valid
            // ScreenMap.
            guard let cgImage = ScreenCapture.captureMainDisplay() else {
                return DHashResult(hash: nil, image: nil)
            }
            return DHashResult(hash: ScreenCapture.dHash(cgImage), image: SendableImage(cgImage))
        }

        // Menu bar read: optimistic using the frontmost pid sampled on the
        // calling thread. If the AX result later reports a different pid (app
        // switched mid-capture), we re-run the read for that pid.
        async let menusOptimisticTask: PhaseAResult<[MenuItem]> = Self.runPhase {
            guard frontPid > 0 else { return [] }
            return MenuBarReader.readMenuBar(pid: frontPid)
        }

        // MARK: Join phase A.
        let axBox = await axResultTask
        let windowsBox = await windowsTask
        let displaysBox = await displaysTask
        let dhashBox = await dhashTask
        let menusOptimisticBox = await menusOptimisticTask

        // Tick the fusion clock from the end of phase-A join. Everything below
        // is either serial-on-the-driver or phase-B overlap.
        let fusionT0 = CFAbsoluteTimeGetCurrent()

        let axResult = axBox.value
        let windows = windowsBox.value
        let displays = displaysBox.value
        let dhashResult = dhashBox.value // (hash, retained CGImage) for change detection + OCR reuse.

        // If the AX read resolved a different pid than the one we used for
        // the optimistic menu read, re-issue the menu read for the correct
        // pid. This only fires when the app switches after we snapshot
        // frontmostApplication but before AX traversal picks up the new
        // app — rare in practice.
        let menusMsExtra: Int
        let menus: [MenuItem]
        if let ax = axResult, ax.pid > 0, ax.pid != frontPid {
            let t0 = CFAbsoluteTimeGetCurrent()
            menus = MenuBarReader.readMenuBar(pid: ax.pid)
            menusMsExtra = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        } else {
            menus = menusOptimisticBox.value
            menusMsExtra = 0
        }

        // MARK: Phase B — AX + windows are available; build elements and run
        // the dependent scans concurrently.

        let axElements = axResult.map { buildElements(from: $0, displays: displays) } ?? []
        let interactiveCount = axElements.filter { $0.role.isInteractive }.count
        let axSufficient = interactiveCount >= 5

        // App profile: cheap synchronous lookup; keep on the driver task.
        let profileNeedsOCR: Bool = {
            guard let bundleID = axResult?.appBundleID,
                  let profile = ElementDatabase.shared.getAppProfile(bundleID: bundleID) else {
                return false
            }
            return profile.needsOCR
        }()

        // Temporal + off-screen detectors traverse the AX tree of the frontmost
        // app independently. They don't touch refStabilizer and they don't need
        // axElements — they run off of raw AX on their own. Run in parallel.
        async let temporalTask: PhaseAResult<TemporalState.TemporalInfo> = Self.runPhase {
            TemporalState.detect()
        }

        async let offScreenTask: PhaseAResult<OffScreenDetector.OffScreenInfo> = Self.runPhase {
            OffScreenDetector.detect()
        }

        // Main-display index drives the OCR coordinate-origin offset in Fusion.
        let mainDisplayIndex = displays.first(where: \.isMain)?.index ?? 0

        // OCR decision branch (Rank 7). The single-switch `OCRDecision` maps
        // policy × AX sufficiency × profile × pending state to one of four
        // actions. See the matrix in `OCRDecision.decide`.
        var finalElements = axElements
        var ocrUsed = false
        var ocrMs = 0

        let hasPending = await ocrState.hasPending()
        let decision = OCRDecision.decide(
            policy: effectivePolicy,
            axSufficient: axSufficient,
            profileNeedsOCR: profileNeedsOCR,
            hasPendingOCR: hasPending
        )

        switch decision {
        case .skipAll:
            // Nothing to do — don't schedule, don't capture. AX-only return.
            // Clear stale pending OCR so the next capture doesn't merge it
            // against a potentially-different app.
            await ocrState.clearPending()

        case .syncOCR:
            let ocrT0 = CFAbsoluteTimeGetCurrent()
            // Reuse the dHash full-res image when available — saves ~15–30 ms
            // on the second screen capture. Falls back to a fresh capture
            // when the dHash phase failed (e.g. recording permission missing).
            let cgImage: CGImage? = dhashResult.image?.value ?? ScreenCapture.captureMainDisplay()
            if let image = cgImage,
               let ocrResults = try? await OCRReader.recognize(image: image) {
                // Gate per-element dHash on the app profile's `needsOCR`
                // signal. Apps like Figma / Blender / DaVinci where OCR is
                // load-bearing are exactly the ones where Tier-6 visual
                // identity matters; for AX-rich apps the dHash loop is
                // pure overhead. Matches plan §6 C.3: "AX-sparse apps
                // get dHash, others skip." Closes critic M4.
                let dHashImage: CGImage? = profileNeedsOCR ? image : nil
                finalElements = Fusion.merge(
                    ax: axElements,
                    ocr: ocrResults,
                    imageWidth: image.width,
                    imageHeight: image.height,
                    refStabilizer: refStabilizer,
                    appBundleID: axResult?.appBundleID,
                    windowIndex: 0,
                    displayScaleFactor: scaleFactor,
                    displays: displays,
                    sourceDisplayIndex: mainDisplayIndex,
                    screenshotForDHash: dHashImage
                )
                ocrUsed = true
            }
            ocrMs = Int((CFAbsoluteTimeGetCurrent() - ocrT0) * 1000)

        case .mergePendingOnly:
            // Merge pending OCR from a previous background run; do NOT schedule
            // a new one — the hasPending branch in decide() only fires when AX
            // is insufficient, so downstream should still get enriched output.
            if let pending = await ocrState.takePending() {
                finalElements = Fusion.merge(
                    ax: axElements,
                    ocr: pending.results,
                    imageWidth: pending.imageWidth,
                    imageHeight: pending.imageHeight,
                    refStabilizer: refStabilizer,
                    appBundleID: axResult?.appBundleID,
                    windowIndex: 0,
                    displayScaleFactor: scaleFactor,
                    displays: displays,
                    sourceDisplayIndex: mainDisplayIndex
                )
                ocrUsed = true
            }
            // Kick off a fresh background OCR for the NEXT capture so the
            // pending pool stays warm.
            scheduleBackgroundOCR(
                axElements: axElements,
                appBundleID: axResult?.appBundleID,
                displays: displays,
                scaleFactor: scaleFactor,
                mainDisplayIndex: mainDisplayIndex
            )

        case .scheduleBackground:
            // AX-only return this capture; schedule OCR to populate the
            // pending pool for the next one. If we already have pending
            // results waiting, fold them in on the way out.
            if !axSufficient, let pending = await ocrState.takePending() {
                finalElements = Fusion.merge(
                    ax: axElements,
                    ocr: pending.results,
                    imageWidth: pending.imageWidth,
                    imageHeight: pending.imageHeight,
                    refStabilizer: refStabilizer,
                    appBundleID: axResult?.appBundleID,
                    windowIndex: 0,
                    displayScaleFactor: scaleFactor,
                    displays: displays,
                    sourceDisplayIndex: mainDisplayIndex
                )
                ocrUsed = true
            }
            scheduleBackgroundOCR(
                axElements: axElements,
                appBundleID: axResult?.appBundleID,
                displays: displays,
                scaleFactor: scaleFactor,
                mainDisplayIndex: mainDisplayIndex
            )
        }

        // Safety scan runs concurrently with the temporal/off-screen detectors.
        // It consumes `finalElements` so it happens after OCR resolves; still
        // runs off the driver thread through `Self.runPhase`.
        let windowTitle = axResult?.windowTitle ?? windows.first(where: { $0.isFocused })?.title ?? ""
        let safetyT0 = CFAbsoluteTimeGetCurrent()
        let (safetyReport, sensitiveResults) = SafetyScanner.scanWithSensitiveResults(
            elements: finalElements,
            appBundleID: axResult?.appBundleID,
            windowTitle: windowTitle
        )

        // Redact sensitive field values, reusing the scan results from above.
        if !sensitiveResults.isEmpty {
            SafetyScanner.redactSensitiveValues(
                elements: &finalElements,
                sensitiveResults: sensitiveResults
            )
        }
        let safetyMs = Int((CFAbsoluteTimeGetCurrent() - safetyT0) * 1000)

        // Join the detectors.
        let temporalBox = await temporalTask
        let offScreenBox = await offScreenTask
        let temporalInfo = temporalBox.value
        let offScreenInfo = offScreenBox.value

        if !temporalInfo.progressIndicators.isEmpty {
            TemporalState.annotateLoadingState(elements: &finalElements, info: temporalInfo)
        }

        // MARK: Phase C — assemble the ScreenMap.

        let captureMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        let focusedApp = AppInfo(
            name: axResult?.appName ?? frontAppSnapshot?.localizedName ?? "Unknown",
            bundleID: axResult?.appBundleID ?? frontAppSnapshot?.bundleIdentifier,
            pid: axResult?.pid ?? frontPid
        )

        let axCoverage: Float
        if finalElements.isEmpty {
            axCoverage = 0
        } else {
            let axCount = Float(finalElements.filter { $0.source == .accessibility }.count)
            axCoverage = axCount / Float(finalElements.count)
        }

        // Fusion time for the breakdown is the wall-clock spent between the
        // phase-A join and the end of ScreenMap construction — i.e. phase-B
        // work the driver does serially (OCR merge, safety, temporal wiring,
        // etc.), minus the already-broken-out `ocrMs` / `safetyMs` phases.
        let fusionWallMs = Int((CFAbsoluteTimeGetCurrent() - fusionT0) * 1000)
        let fusionMs = max(0, fusionWallMs - ocrMs - safetyMs)

        let timing = TimingBreakdown(
            totalMs: captureMs,
            axMs: axBox.ms,
            windowsMs: windowsBox.ms,
            displaysMs: displaysBox.ms,
            menusMs: menusOptimisticBox.ms + menusMsExtra,
            dHashMs: dhashBox.ms,
            ocrMs: ocrMs,
            fusionMs: fusionMs,
            safetyMs: safetyMs
        )

        let metadata = CaptureMetadata(
            axCoveragePercent: axCoverage,
            ocrUsed: ocrUsed,
            elementCount: finalElements.count,
            interactiveCount: finalElements.filter { $0.role.isInteractive }.count,
            offScreenHint: offScreenInfo.hint,
            timing: timing
        )

        let map = ScreenMap(
            timestamp: Date(),
            captureMs: captureMs,
            displays: displays,
            focusedApp: focusedApp,
            windows: windows,
            elements: finalElements,
            navigation: NavigationContext.build(
                appName: focusedApp.name,
                windowTitle: windowTitle,
                elements: finalElements
            ),
            safety: safetyReport,
            metadata: metadata,
            menus: menus
        )

        // Commit refs for next snapshot stability. `RefStabilizer` is
        // internally thread-safe; this is a no-op if no elements changed.
        refStabilizer.commitSnapshot()

        let snapshot = Snapshot(id: Snapshot.contentHash(of: finalElements), map: map)
        await cache.store(snapshot, at: Date())

        // Rank 8 — retain the full-res image so VisionDiffer can crop without
        // re-capturing. Non-blocking (detached) so it doesn't slow `capture()`.
        //
        // Gated on an active vision-diff session: the 10 Hz PerceptionLoop
        // drives this path continuously, so retaining a full-screen CGImage on
        // every tick would pin ~33–59 MB in memory for the app's lifetime even
        // when nobody ever calls `visionDiff()`. `VisualDiffState` only flips
        // active once a consumer fetches, and the consumers fall back to a
        // fresh `ScreenCapture.captureDisplay()` when `fetch()` returns nil —
        // so dropping the frame here costs at most one extra screenshot on the
        // first vision-diff of a session.
        if let retainedImage = dhashResult.image, await visualDiffState.isActive {
            let state = visualDiffState
            Task.detached(priority: .utility) { [state] in
                await state.store(retainedImage, displayIndex: mainDisplayIndex)
            }
        }

        return map
    }

    // MARK: - Lane-Partial Capture (Wave 6)

    /// Lane-partial capture. Runs only the phase-A subtasks whose lanes are
    /// present in `lanes`, then patches those results over `base`. When `base`
    /// is `nil`, behaves like a minimal full capture restricted to those lanes.
    ///
    /// **Cache policy**: if `base` is non-nil, is no older than `cacheTTL`, and
    /// the requested lanes are a subset of what `base` already covers (all phase-A
    /// lanes), the method returns `base` unchanged — saving all work.
    ///
    /// **OCR / safety / temporal (phase B/C)** are skipped unless `.ocr` is
    /// explicitly in `lanes`.  Callers that need a safety-scanned result should
    /// use the full `capture()` entry point instead.
    public func capture(lanes: LaneSet, base: ScreenMap?) async -> ScreenMap {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Cache short-circuit: if base is fresh and covers everything we need.
        if let base = base {
            let baseAge = Date().timeIntervalSince(base.timestamp)
            // All phase-A lanes that this method can update:
            let phaseALanes: LaneSet = [.focus, .windows, .displays, .axTree, .menus, .dHash, .browserDOM]
            let requestedPhaseA = lanes.intersection(phaseALanes)
            if baseAge < cacheTTL && requestedPhaseA.isEmpty {
                return base
            }
        }

        // Snapshot NSScreen values on calling thread (same as the full capture).
        let frontAppSnapshot = NSWorkspace.shared.frontmostApplication
        let frontPid: pid_t = frontAppSnapshot?.processIdentifier ?? 0

        // Run only the requested phase-A subtasks in parallel.
        // Each task is guarded by a lane-membership check; non-requested tasks
        // produce nil/empty and are merged by copying from `base` at the end.

        async let axTask: PhaseAResult<AXReader.AXReadResult?> = Self.runPhase {
            guard lanes.contains(.axTree) || lanes.contains(.focus) else { return nil }
            return AXReader.readFrontmostApp(viewport: nil)
        }

        async let windowsTask: PhaseAResult<[WindowInfo]?> = Self.runPhase {
            guard lanes.contains(.windows) else { return nil }
            return WindowEnumerator.allWindows()
        }

        async let displaysTask: PhaseAResult<[DisplayInfo]?> = Self.runPhase {
            guard lanes.contains(.displays) else { return nil }
            return WindowEnumerator.allDisplays()
        }

        async let dhashTask: PhaseAResult<DHashResult?> = Self.runPhase {
            guard lanes.contains(.dHash) else { return nil }
            guard let cgImage = ScreenCapture.captureMainDisplay() else {
                return DHashResult(hash: nil, image: nil)
            }
            return DHashResult(hash: ScreenCapture.dHash(cgImage), image: SendableImage(cgImage))
        }

        async let menusTask: PhaseAResult<[MenuItem]?> = Self.runPhase {
            guard lanes.contains(.menus) else { return nil }
            guard frontPid > 0 else { return [] }
            return MenuBarReader.readMenuBar(pid: frontPid)
        }

        async let browserDOMTask: PhaseAResult<BrowserDOMCapture?> = Self.runPhase {
            guard lanes.contains(.browserDOM) else { return nil }
            guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
            let info = AppInfo(
                name: frontApp.localizedName ?? "Unknown",
                bundleID: frontApp.bundleIdentifier,
                pid: frontApp.processIdentifier
            )
            return await BrowserDOMFetcher.shared.fetchIfBrowserFrontmost(info)
        }

        // Join phase A.
        let axBox       = await axTask
        let windowsBox  = await windowsTask
        let displaysBox = await displaysTask
        _ = await dhashTask   // dHash lane: hash+image captured but not merged here
        let menusBox    = await menusTask
        let domBox      = await browserDOMTask

        let captureMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        // Resolve values: use fresh result when available, otherwise copy from base.
        let axResult    = axBox.value
        let newWindows  = windowsBox.value
        let newDisplays = displaysBox.value
        let newMenus    = menusBox.value
        let newDOM      = domBox.value  // nil means "not requested"

        let resolvedDisplays: [DisplayInfo] = newDisplays
            ?? base?.displays
            ?? WindowEnumerator.allDisplays()

        let resolvedWindows: [WindowInfo] = newWindows
            ?? base?.windows
            ?? []

        let resolvedMenus: [MenuItem] = newMenus
            ?? base?.menus
            ?? []

        // DOM: only replace when we actually fetched it this call.
        let resolvedDOM: BrowserDOMCapture?
        if lanes.contains(.browserDOM) {
            resolvedDOM = newDOM  // may be nil if browser isn't frontmost
        } else {
            resolvedDOM = base?.browserDOM
        }

        // AX elements — skip OCR entirely (no .ocr lane shortcut requested).
        // Phase-B safety/temporal are omitted for speed; callers needing them
        // should use the full capture() entry point.
        let builtElements: [ScreenElement]
        let focusedApp: AppInfo
        if let ax = axResult {
            builtElements = buildElements(from: ax, displays: resolvedDisplays)
            focusedApp = AppInfo(
                name: ax.appName,
                bundleID: ax.appBundleID,
                pid: ax.pid
            )
        } else if let base = base {
            builtElements = base.elements
            focusedApp = base.focusedApp
        } else {
            builtElements = []
            focusedApp = AppInfo(
                name: frontAppSnapshot?.localizedName ?? "Unknown",
                bundleID: frontAppSnapshot?.bundleIdentifier,
                pid: frontPid
            )
        }

        // Phase C joiner — when a browser is frontmost and DOM capture
        // resolved, annotate matching AX elements with domSelector/domNodeId
        // so `SemanticExecutor.press` can take the CDP path. Skipped for
        // non-browser frontmost apps (fetchInteractiveNodes early-returns),
        // and the fetcher's fingerprint cache makes repeated calls cheap.
        let resolvedElements: [ScreenElement]
        if resolvedDOM != nil, lanes.contains(.browserDOM) {
            let focusedWindowBounds = resolvedWindows.first(where: { $0.isFocused })?.bounds
            resolvedElements = await BrowserDOMJoiner.enrichElements(
                in: builtElements,
                focusedApp: focusedApp,
                focusedWindowBounds: focusedWindowBounds
            )
        } else {
            resolvedElements = builtElements
        }

        // Minimal metadata — timing only covers phase-A work done this call.
        let metadata = CaptureMetadata(
            axCoveragePercent: base?.metadata.axCoveragePercent ?? 0,
            ocrUsed: false,
            elementCount: resolvedElements.count,
            interactiveCount: resolvedElements.filter { $0.role.isInteractive }.count,
            offScreenHint: base?.metadata.offScreenHint,
            timing: nil
        )

        return ScreenMap(
            timestamp: Date(),
            captureMs: captureMs,
            displays: resolvedDisplays,
            focusedApp: focusedApp,
            windows: resolvedWindows,
            elements: resolvedElements,
            navigation: base?.navigation,
            safety: base?.safety ?? .empty,
            metadata: metadata,
            browserDOM: resolvedDOM,
            menus: resolvedMenus
        )
    }

    // MARK: - Background OCR

    /// Schedules OCR to run in the background. Results are stored in the
    /// `AsyncOCRState` actor and merged into the next `capture()` call.
    private func scheduleBackgroundOCR(
        axElements: [ScreenElement],
        appBundleID: String?,
        displays: [DisplayInfo],
        scaleFactor: Int,
        mainDisplayIndex: Int
    ) {
        // Snapshot callbacks + stabilizer up front so the detached task body
        // doesn't capture `self` (which would force `@unchecked Sendable`
        // semantics on an already-isolated actor call).
        let stabilizer = refStabilizer
        let callback = self.onOCREnrichment
        let state = self.ocrState

        Task.detached(priority: .utility) { [state, stabilizer, displays] in
            await state.cancelActive()
            let task = Task.detached(priority: .utility) { [displays] in
                guard let cgImage = ScreenCapture.captureMainDisplay() else { return }
                guard !Task.isCancelled else { return }

                guard let ocrResults = try? await OCRReader.recognize(image: cgImage) else { return }
                guard !Task.isCancelled else { return }

                await state.storePending(
                    results: ocrResults,
                    imageWidth: cgImage.width,
                    imageHeight: cgImage.height
                )

                if let callback = callback {
                    let enriched = Fusion.merge(
                        ax: axElements,
                        ocr: ocrResults,
                        imageWidth: cgImage.width,
                        imageHeight: cgImage.height,
                        refStabilizer: stabilizer,
                        appBundleID: appBundleID,
                        windowIndex: 0,
                        displayScaleFactor: scaleFactor,
                        displays: displays,
                        sourceDisplayIndex: mainDisplayIndex
                    )
                    callback(enriched)
                }
            }
            await state.setActive(task)
        }
    }

    // MARK: - Phase helper

    /// Wraps a Sendable synchronous closure in a measured phase. The closure
    /// runs on a detached background task (priority: userInitiated) so the
    /// driver task can proceed to fan out the next `async let` without being
    /// pinned to the current executor. Returns a `PhaseAResult` carrying the
    /// value and the phase's wall-clock duration in ms.
    private static func runPhase<T: Sendable>(
        _ body: @Sendable @escaping () -> T
    ) async -> PhaseAResult<T> {
        let t0 = CFAbsoluteTimeGetCurrent()
        let value = await Task.detached(priority: .userInitiated) {
            body()
        }.value
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        return PhaseAResult(value: value, ms: ms)
    }

    private static func runPhase<T: Sendable>(
        _ body: @Sendable @escaping () async -> T
    ) async -> PhaseAResult<T> {
        let t0 = CFAbsoluteTimeGetCurrent()
        let value = await Task.detached(priority: .userInitiated) {
            await body()
        }.value
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        return PhaseAResult(value: value, ms: ms)
    }

    // MARK: - Build Elements

    /// Convert raw AX elements into ScreenElements with stable refs and parent tracking.
    ///
    /// Each element's ref comes from `RefStabilizer.assign` with a fully-populated
    /// `RefAssignment` — ancestry chain, parent bounds, sibling ordinal — so the
    /// stabilizer can pick the strongest identity tier available (identifier → label →
    /// parent-anchored position → coarse fallback).
    ///
    /// `displays` is the display snapshot captured for this frame; each element
    /// is tagged with the index of the display containing its center (AX bounds
    /// are in top-left, Y-down space, matching `DisplayInfo.topLeftBounds`).
    /// Elements without bounds inherit `displayIndex` from the most recent
    /// ancestor that had one, falling back to `0`.
    private func buildElements(
        from axResult: AXReader.AXReadResult,
        displays: [DisplayInfo]
    ) -> [ScreenElement] {
        // parentStack tracks (depth, ref) for parent lookup on the ScreenElement.
        var parentStack: [(depth: Int, ref: ElementRef)] = []
        // ancestryStack mirrors parentStack and carries role+label for ancestry hashing,
        // plus the parent's bounds so tier-3 anchored-position keys can be computed,
        // plus the parent's resolved displayIndex so elements without bounds inherit
        // from the nearest ancestor that had them.
        var ancestryStack: [(depth: Int, role: ElementRole, label: String, bounds: CGRect?, displayIndex: Int)] = []
        // siblingCounter: key is (parentRef.index, role) packed into a single UInt64;
        // value is the next ordinal to assign. Reset implicitly when parent is popped
        // (we simply allocate fresh counters for newly-pushed parents by key).
        var siblingCounter: [UInt64: Int] = [:]
        var elements: [ScreenElement] = []

        for raw in axResult.elements {
            let role = ElementRole.from(axRole: raw.role)
            let bestLabel = [raw.title, raw.description, raw.label]
                .first(where: { !$0.isEmpty }) ?? raw.value

            let clickPoint: CGPoint?
            let bounds: CGRect?
            if let pos = raw.position, let size = raw.size {
                clickPoint = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                bounds = CGRect(origin: pos, size: size)
            } else {
                clickPoint = nil
                bounds = nil
            }

            // Pop stacks until we find a strictly-shallower parent. We pop BEFORE
            // computing the sibling index so the counter scope matches the correct
            // parent. siblingCounter entries for popped parents are dropped so a
            // re-visit of the same parent hash in a later burst starts fresh.
            while let last = parentStack.last, last.depth >= raw.depth {
                let poppedRef = last.ref
                parentStack.removeLast()
                ancestryStack.removeLast()
                // Drop any sibling counters scoped to this popped parent. Cheap: the
                // map is small (depth 12 × ~5 roles ≈ 60 entries max).
                let dropKey = Self.siblingCounterKey(parentRefIndex: poppedRef.index, role: role)
                siblingCounter.removeValue(forKey: dropKey)
                // Also drop counters for OTHER roles under this parent — any role can
                // have children. Walk the dictionary once; small N so linear is fine.
                siblingCounter = siblingCounter.filter { key, _ in
                    !Self.siblingKeyBelongsToParent(key, parentRefIndex: poppedRef.index)
                }
            }
            let parentRef = parentStack.last?.ref
            let parentBounds = ancestryStack.last?.bounds

            // Build the ancestry chain root-first. AncestryHash.compute keeps the last
            // `maxDepth` entries internally, so no need to truncate here.
            let chain = ancestryStack.map { ($0.role, $0.label) }
            let ancestryHash = AncestryHash.compute(from: chain)

            // Compute sibling index BEFORE assigning this element's ref, then bump.
            let siblingKey = Self.siblingCounterKey(
                parentRefIndex: parentRef?.index ?? 0,
                role: role
            )
            let siblingIndex = siblingCounter[siblingKey, default: 0]
            siblingCounter[siblingKey] = siblingIndex + 1

            let assignment = RefAssignment(
                bundleID: axResult.appBundleID,
                role: role,
                label: bestLabel,
                identifier: raw.identifier,
                bounds: bounds,
                parentBounds: parentBounds,
                ancestryHash: ancestryHash,
                depth: raw.depth,
                siblingIndex: siblingIndex
            )
            let ref = refStabilizer.assign(assignment)

            // Resolve which display this element belongs to. Preferred input is
            // the click point (already in screen coordinates via AX). If there
            // isn't one, fall back to the bounds center. If neither is
            // available, inherit from the nearest ancestor with a resolved
            // displayIndex.
            let displayIndex: Int
            if let pt = clickPoint {
                displayIndex = WindowEnumerator.displayIndexForTopLeftPoint(pt, displays: displays)
            } else if let b = bounds {
                displayIndex = WindowEnumerator.displayIndexForTopLeftPoint(
                    CGPoint(x: b.midX, y: b.midY),
                    displays: displays
                )
            } else {
                displayIndex = ancestryStack.last?.displayIndex ?? 0
            }

            parentStack.append((depth: raw.depth, ref: ref))
            ancestryStack.append((
                depth: raw.depth,
                role: role,
                label: bestLabel,
                bounds: bounds,
                displayIndex: displayIndex
            ))

            elements.append(ScreenElement(
                ref: ref,
                role: role,
                subrole: raw.subrole,
                label: bestLabel,
                value: raw.value,
                bounds: bounds,
                clickPoint: clickPoint,
                state: raw.state,
                actions: raw.actions,
                parentRef: parentRef,
                depth: raw.depth,
                source: .accessibility,
                confidence: 1.0,
                appBundleID: axResult.appBundleID,
                windowIndex: 0,
                displayIndex: displayIndex
            ))
        }

        return elements
    }

    /// Packs (parentRefIndex, role) into a single UInt64 key for sibling counters.
    /// Upper 32 bits = parent index (0 for top-level), lower 32 = role hash.
    private static func siblingCounterKey(parentRefIndex: Int, role: ElementRole) -> UInt64 {
        let parentBits = UInt64(UInt32(truncatingIfNeeded: parentRefIndex)) << 32
        var roleHash: UInt32 = 5381
        for byte in role.rawValue.utf8 {
            roleHash = (roleHash &<< 5) &+ roleHash &+ UInt32(byte)
        }
        return parentBits | UInt64(roleHash)
    }

    /// True if a sibling-counter key belongs to the given parent (upper 32 bits match).
    private static func siblingKeyBelongsToParent(_ key: UInt64, parentRefIndex: Int) -> Bool {
        let parentBits = UInt64(UInt32(truncatingIfNeeded: parentRefIndex)) << 32
        return (key & 0xFFFF_FFFF_0000_0000) == parentBits
    }
}

// MARK: - Phase A result wrapper

/// Carries a phase's value plus its wall-clock duration.
private struct PhaseAResult<T: Sendable>: Sendable {
    let value: T
    let ms: Int
}

// MARK: - Capture cache (actor-isolated)

/// Serializes access to `lastSnapshot`/`lastSnapshotTime`. Ten concurrent
/// `capture()` callers run through `hit(ttl:)` / `store(_:at:)` sequentially,
/// producing a single canonical (snapshot, time) pair with no aliasing races.
private actor CaptureCache {
    private var snapshot: Snapshot?
    private var time: Date = .distantPast

    func hit(ttl: TimeInterval) -> Snapshot? {
        guard let snapshot = snapshot else { return nil }
        guard Date().timeIntervalSince(time) < ttl else { return nil }
        return snapshot
    }

    func store(_ snapshot: Snapshot, at time: Date) {
        self.snapshot = snapshot
        self.time = time
    }

    func clear() {
        snapshot = nil
        time = .distantPast
    }
}

// MARK: - Async OCR state (actor-isolated)

/// Serializes access to the background OCR's pending results + running task.
/// Ensures cancel/schedule/take-results operations are atomic.
private actor AsyncOCRState {
    private var pendingResults: [OCRReader.OCRResult]?
    private var pendingWidth: Int = 0
    private var pendingHeight: Int = 0
    private var active: Task<Void, Never>?

    struct Pending: Sendable {
        let results: [OCRReader.OCRResult]
        let imageWidth: Int
        let imageHeight: Int
    }

    func takePending() -> Pending? {
        guard let results = pendingResults else { return nil }
        let out = Pending(results: results, imageWidth: pendingWidth, imageHeight: pendingHeight)
        pendingResults = nil
        pendingWidth = 0
        pendingHeight = 0
        return out
    }

    /// Non-destructive existence check — used by the Rank 7 decision matrix so
    /// `OCRDecision.decide` can branch on pending state before we commit to
    /// consuming it with `takePending()`.
    func hasPending() -> Bool {
        pendingResults != nil
    }

    func clearPending() {
        pendingResults = nil
        pendingWidth = 0
        pendingHeight = 0
    }

    func storePending(results: [OCRReader.OCRResult], imageWidth: Int, imageHeight: Int) {
        pendingResults = results
        pendingWidth = imageWidth
        pendingHeight = imageHeight
    }

    /// Cancel the currently-running detached OCR task (if any), but don't await
    /// its completion — it will finish on its own and the next `setActive` will
    /// replace it.
    func cancelActive() {
        active?.cancel()
        active = nil
    }

    func setActive(_ task: Task<Void, Never>) {
        active = task
    }

    func cancelAndClear() {
        active?.cancel()
        active = nil
        pendingResults = nil
        pendingWidth = 0
        pendingHeight = 0
    }
}

// MARK: - dHash phase result (Rank 7)

/// Carries the dHash value plus the full-resolution image captured on the
/// same round-trip. The OCR branch can reuse `image` to avoid a second
/// `CGWindowListCreateImage` call — saves ~15–30 ms on the sync-OCR path.
/// `hash == nil` and `image == nil` both indicate the capture failed (e.g.
/// missing screen-recording permission).
private struct DHashResult: Sendable {
    let hash: UInt64?
    let image: SendableImage?
}

/// `CGImage` is an immutable Core Foundation type — the runtime treats it as
/// Sendable in Swift 5.10+, but we wrap it for explicit boundary-crossing so
/// the compiler doesn't complain about the transition into `PhaseAResult<T:
/// Sendable>`. The wrapper has no mutable state; `@unchecked Sendable` is
/// safe here.
///
/// Public so downstream ranks (Rank 8 vision diffs) can reuse the retained
/// full-resolution screenshot without re-capturing.
public struct SendableImage: @unchecked Sendable {
    public let value: CGImage

    public init(_ value: CGImage) {
        self.value = value
    }
}

// MARK: - Visual Diff State (Rank 8)

/// Retains the most-recent full-resolution screenshot per display so
/// `VisionDiffer` can crop a diff region without issuing a second
/// `CGWindowListCreateImage` call. Populated from the tail of
/// `PerceptionPipeline.capture()` via a detached task — the store is
/// non-blocking and never stalls the capture pipeline.
///
/// Bounded: at most `maxDisplays` entries retained. Rank 8 only needs the
/// freshest frame per display; we intentionally don't keep history.
public actor VisualDiffState {
    /// Upper bound on per-display image retention. 8 covers every real-world
    /// multi-display rig; beyond that the LRU eviction drops stale entries.
    public static let maxDisplays = 8

    private struct Entry {
        let image: SendableImage
        let storedAt: Date
    }

    private var entriesByDisplay: [Int: Entry] = [:]
    private var lastTimestamp: Date = .distantPast

    /// Whether a vision-diff consumer has run this session. Retention is pure
    /// overhead for the common path (agent perception / OCR / delta encoding)
    /// that never invokes the Rank 8 vision-diff API, so `store(...)` is gated
    /// on this flag. The first `fetch`/`fetchAll` call flips it on — that call
    /// returns nil and the consumer falls back to a fresh capture, but every
    /// subsequent capture in the session then retains its frame here.
    public private(set) var isActive = false

    public init() {}

    /// Store the freshest image for this display. Replaces any prior retention.
    /// Evicts the oldest entry when the per-display cap is exceeded. No-op until
    /// a vision-diff consumer has activated retention (see `isActive`).
    public func store(_ image: SendableImage, displayIndex: Int) {
        guard isActive else { return }
        let now = Date()
        entriesByDisplay[displayIndex] = Entry(image: image, storedAt: now)
        lastTimestamp = now
        evictLRUIfNeeded()
    }

    /// Fetch the retained image for this display, or nil if nothing is
    /// currently retained (first capture, or the store hasn't completed yet).
    /// Also activates retention so subsequent captures begin storing frames.
    public func fetch(displayIndex: Int) -> SendableImage? {
        isActive = true
        return entriesByDisplay[displayIndex]?.image
    }

    /// Timestamp of the most recent store (`.distantPast` if never stored).
    public func mostRecentTimestamp() -> Date {
        lastTimestamp
    }

    /// Fetch every retained image keyed by display index. Used by
    /// `VisionDiffer.diffMultiDisplay` to build per-display crops. Also
    /// activates retention so subsequent captures begin storing frames.
    public func fetchAll() -> [Int: SendableImage] {
        isActive = true
        var out: [Int: SendableImage] = [:]
        for (idx, entry) in entriesByDisplay {
            out[idx] = entry.image
        }
        return out
    }

    /// Drop every retained image and stop retaining until the next vision-diff
    /// consumer activates again. Safe to call from any task.
    public func clear() {
        entriesByDisplay.removeAll(keepingCapacity: true)
        lastTimestamp = .distantPast
        isActive = false
    }

    private func evictLRUIfNeeded() {
        guard entriesByDisplay.count > Self.maxDisplays else { return }
        while entriesByDisplay.count > Self.maxDisplays {
            guard let victimKey = entriesByDisplay.min(by: {
                $0.value.storedAt < $1.value.storedAt
            })?.key else { break }
            entriesByDisplay.removeValue(forKey: victimKey)
        }
    }
}
