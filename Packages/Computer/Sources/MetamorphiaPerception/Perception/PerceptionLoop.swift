import CoreGraphics
import Foundation

// MARK: - LoopMode

/// Controls whether `PerceptionLoop` drives perception itself (pull) or
/// hands that responsibility to a push driver (push).
public enum LoopMode: String, Sendable, Codable {
    /// Default. The loop captures at ~10 Hz / 2 Hz idle and yields frames
    /// directly. All existing behavior is preserved in this mode.
    case pull
    /// Push mode. The loop tick becomes a heartbeat only — it posts
    /// `.heartbeat(sinceLast:)` to `TriggerBus.shared` every 2 s and does
    /// NOT call `capture()`. Actual perception work is performed by
    /// `PushPerceptionDriver` (Wave 7) which registers bus handlers and
    /// writes frames to this loop's continuations via `yieldSnapshot(_:)`.
    case push
}

// MARK: - PerceptionLoop

/// Background 10 Hz perception loop.
///
/// Drives `PerceptionPipeline.shared.capture()` on a tick, enriches the result with a
/// full browser DOM capture when the frontmost app is a supported browser, gates on a
/// dHash + content-hash change detector, and fans the result out to any number of
/// `AsyncStream<ScreenMap>` subscribers with latest-wins semantics.
///
/// Design properties:
///  - **No Claude / no Anthropic calls.** Entirely local. No network traffic except
///    `localhost:11434` (Ollama, by downstream consumers) and `localhost:9222` (Chrome
///    DevTools Protocol, by `BrowserDOMFetcher`).
///  - **Cheap on idle screens.** When nothing changes, the loop still ticks but no
///    subscriber receives a frame — the content-hash gate short-circuits emission.
///  - **Adaptive throttle.** After 1 s of unchanged frames the loop drops to 2 Hz;
///    on the next change it snaps back to the configured target rate for 3 s.
///  - **Latest-wins backpressure.** Slow consumers see only the newest frame, not a
///    backlog — implemented with `AsyncStream.Continuation.bufferingPolicy(.bufferingNewest(1))`.
///  - **Fair cooperation with the shared pipeline.** Uses the pipeline's 200 ms cache
///    without mutation, so concurrent callers in the same process are unaffected.
public actor PerceptionLoop {
    public static let shared = PerceptionLoop()

    // MARK: - Configuration

    /// Target tick rate. Default 10 Hz. Actual capture frequency is capped by the
    /// `PerceptionPipeline` cache TTL (200 ms) — a 10 Hz tick therefore triggers ~5
    /// fresh captures per second, with the remaining ticks served from cache. The
    /// effective *emission* rate is bounded by how often the screen actually changes.
    public private(set) var targetHz: Double = 10.0

    /// Fallback probe rate after a period of no change. 2 Hz keeps the loop responsive
    /// without burning CPU when the user isn't doing anything.
    public private(set) var idleHz: Double = 2.0

    /// How long (seconds) of no emissions before dropping to `idleHz`.
    public private(set) var idleThreshold: TimeInterval = 1.0

    /// How long (seconds) to hold the active rate after a change.
    public private(set) var activeHoldDuration: TimeInterval = 3.0

    // MARK: - State

    /// The running loop's Task, or `nil` if stopped.
    private var runTask: Task<Void, Never>?

    /// Continuations for every active subscriber. Appended to on `observe()`,
    /// removed on stream cancellation.
    private var continuations: [UUID: AsyncStream<ScreenMap>.Continuation] = [:]

    /// Content hash of the last *emitted* ScreenMap. Used as the change gate.
    private var lastEmittedContentHash: UInt64 = 0

    /// When we last emitted a frame. Drives the idle→active→idle throttle.
    private var lastEmissionTime: Date = .distantPast

    /// Last-known bundleID we saw. Used to invalidate the browser-DOM cache when
    /// focus jumps to a different app.
    private var lastFocusedBundleID: String?

    // MARK: - Public API

    public init() {}

    /// Start the loop. Safe to call when already running — a second `start` just
    /// updates `targetHz` and keeps the existing task alive.
    public func start(targetHz: Double = 10.0) {
        self.targetHz = max(1.0, min(targetHz, 30.0))
        if runTask != nil { return }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop the loop. Any in-flight capture is allowed to finish. All subscribers
    /// continue to see buffered frames but no new ones.
    public func stop() {
        runTask?.cancel()
        runTask = nil
    }

    /// Subscribe to the perception stream. Each call returns a fresh `AsyncStream`
    /// with latest-wins backpressure (slow consumers see only the newest frame).
    /// Cancelling the stream (by terminating its `for await` loop or dropping the
    /// iterator) automatically unregisters the subscriber.
    public nonisolated func observe() -> AsyncStream<ScreenMap> {
        return AsyncStream<ScreenMap>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            Task { [weak self] in
                await self?.registerContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.unregisterContinuation(id: id)
                }
            }
        }
    }

    // MARK: - Internal (actor-isolated)

    private func registerContinuation(id: UUID, continuation: AsyncStream<ScreenMap>.Continuation) {
        continuations[id] = continuation
    }

    private func unregisterContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// The main tick loop. Runs until `stop()` cancels the task.
    private func runLoop() async {
        while !Task.isCancelled {
            let tickStart = Date()

            // Decide the effective rate for this tick based on recent activity.
            let timeSinceLastEmission = Date().timeIntervalSince(lastEmissionTime)
            let effectiveHz: Double
            if timeSinceLastEmission < activeHoldDuration {
                effectiveHz = targetHz
            } else if timeSinceLastEmission < idleThreshold + activeHoldDuration {
                effectiveHz = targetHz
            } else {
                effectiveHz = idleHz
            }
            let tickInterval = 1.0 / effectiveHz

            // Wave 6 — push mode: tick is a heartbeat only. Post to TriggerBus
            // so PushPerceptionDriver can schedule partial-lane captures as needed.
            // Subscribers receive frames via yieldSnapshot(_:) from the driver.
            if mode == .push {
                let sinceLast = Date().timeIntervalSince(lastEmissionTime)
                let reason = TriggerReason.heartbeat(sinceLast: sinceLast)
                // `post(_:)` is nonisolated; hop to MainActor only to read
                // the `shared` singleton (which is @MainActor-isolated).
                Task { @MainActor in TriggerBus.shared.post(reason) }
                // Watchdog: if push has starved for 15 s while the user is
                // active, swap back to pull. Cheap: one counter read +
                // one `secondsSinceLastEventType` call per heartbeat.
                checkPushHealth()
                let heartbeatInterval = 2.0
                let heartbeatElapsed = Date().timeIntervalSince(tickStart)
                let heartbeatRemaining = heartbeatInterval - heartbeatElapsed
                if heartbeatRemaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(heartbeatRemaining * 1_000_000_000))
                }
                continue
            }

            // Capture one frame (reuses the pipeline's 200 ms cache for cheapness).
            let map = await PerceptionPipeline.shared.capture(forceOCR: false, appFilter: nil)

            // If the frontmost app changed, invalidate the browser-DOM cache so the
            // next fetch sees the new tab cleanly.
            let currentBundle = map.focusedApp.bundleID
            if currentBundle != lastFocusedBundleID {
                await BrowserDOMFetcher.shared.invalidateCache()
                lastFocusedBundleID = currentBundle
            }

            // Enrich with a full DOM fetch if the frontmost window is a supported
            // browser. The fetcher has its own (url, title)-fingerprint cache so this
            // is cheap when the tab is unchanged.
            let domCapture = await BrowserDOMFetcher.shared.fetchIfBrowserFrontmost(map.focusedApp)

            // Rebuild the ScreenMap with the DOM attached. ScreenMap is immutable,
            // so we construct a new one — this is a shallow copy, not a deep clone.
            // Reuse `map.displays` so the enriched copy keeps the full display
            // array (not just the primary).
            //
            // If a DOM capture resolved, run `BrowserDOMJoiner` to annotate
            // matching AX elements with their `domSelector`/`domNodeId`. This
            // lights up the CDP execution path in `SemanticExecutor.press` —
            // without this wire-through, `element.domSelector` is always nil
            // and the CDP branch silently short-circuits to cursor. The join
            // is cheap (first-hit-wins, small n) and DOM-fetcher caching
            // means the node-enumeration call is a no-op when the tab
            // hasn't changed.
            let enrichedMap: ScreenMap
            if let domCapture = domCapture {
                let focusedWindowBounds = map.windows.first(where: { $0.isFocused })?.bounds
                let annotated = await BrowserDOMJoiner.enrichElements(
                    in: map.elements,
                    focusedApp: map.focusedApp,
                    focusedWindowBounds: focusedWindowBounds
                )
                enrichedMap = ScreenMap(
                    timestamp: map.timestamp,
                    captureMs: map.captureMs,
                    displays: map.displays,
                    focusedApp: map.focusedApp,
                    windows: map.windows,
                    elements: annotated,
                    navigation: map.navigation,
                    safety: map.safety,
                    metadata: map.metadata,
                    browserDOM: domCapture,
                    menus: map.menus
                )
            } else {
                enrichedMap = map
            }

            // Change gate: compute the content hash and compare to the last emitted one.
            // The dHash is *also* available on the pipeline's internal snapshot, but the
            // content hash over element refs + labels + states is what subscribers actually
            // care about — and it's cheap.
            let hash = Snapshot.contentHash(of: enrichedMap.elements)

            // If the DOM changed while the element list did not (e.g., a browser tab
            // that updates its innerHTML without new AX elements), still emit — the
            // subscriber may care about the DOM.
            let domChanged: Bool = {
                guard let dom = enrichedMap.browserDOM else { return false }
                // Hash the URL + byte count; full HTML hashing would be O(html size).
                var h: UInt64 = 5381
                for byte in dom.url.utf8 { h = ((h &<< 5) &+ h) &+ UInt64(byte) }
                h ^= UInt64(dom.html.utf8.count)
                return h != lastDomHash
            }()

            if hash != lastEmittedContentHash || domChanged {
                lastEmittedContentHash = hash
                lastEmissionTime = Date()
                if let dom = enrichedMap.browserDOM {
                    var h: UInt64 = 5381
                    for byte in dom.url.utf8 { h = ((h &<< 5) &+ h) &+ UInt64(byte) }
                    h ^= UInt64(dom.html.utf8.count)
                    lastDomHash = h
                } else {
                    lastDomHash = 0
                }
                // Fan out to every subscriber.
                for (_, continuation) in continuations {
                    continuation.yield(enrichedMap)
                }
            }

            // Sleep the remainder of the tick budget. If the capture took longer than
            // the interval (e.g., first call, OCR fallback), skip the sleep entirely —
            // we're already late.
            let elapsed = Date().timeIntervalSince(tickStart)
            let remaining = tickInterval - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        // Loop exiting — terminate all subscriber streams cleanly.
        for (_, continuation) in continuations {
            continuation.finish()
        }
        continuations.removeAll()
    }

    /// Hash fingerprint of the last emitted browser DOM (url + byte count).
    /// Declared after the loop for readability; colocated with the gate that uses it.
    private var lastDomHash: UInt64 = 0

    // MARK: - Mode (Wave 6)

    /// Current operating mode. Starts in `.pull` to preserve all existing behavior.
    public private(set) var mode: LoopMode = .pull

    /// Switch the loop between pull and push modes. Safe to call while the loop
    /// is running — the next tick will observe the new mode.
    public func setMode(_ new: LoopMode) {
        mode = new
    }

    /// Yield a snapshot directly to all active subscribers. Used by
    /// `PushPerceptionDriver` (Wave 7) when operating in `.push` mode so that
    /// existing `observe()` consumers receive frames without any code changes.
    /// Internal scope only — the driver lives in the same package.
    internal func yieldSnapshot(_ map: ScreenMap) {
        pushFramesProduced += 1
        lastPushYieldAt = Date()
        for continuation in continuations.values {
            continuation.yield(map)
        }
    }

    // MARK: - Push-mode failback

    /// Count of frames the push driver has delivered since the last watchdog
    /// reset. Zero at boot; incremented in `yieldSnapshot`. Examined by
    /// `checkPushHealth()` every 15 s — if the count stays at zero while
    /// the user is active, the loop assumes the AX-observer fleet is broken
    /// for this app session and swaps back to pull so perception keeps
    /// moving.
    private var pushFramesProduced: Int = 0
    private var lastPushYieldAt: Date = .distantPast

    /// Runs a lightweight 15 s watchdog when the loop is in push mode. If the
    /// driver has not produced a frame in the last 15 s AND the user has been
    /// active (not idle) in the same window, we declare push mode degraded
    /// for this session and swap back to pull. Pull will re-drive the 10 Hz
    /// capture loop so `observe()` subscribers keep seeing frames.
    ///
    /// Called from the heartbeat branch inside `runLoop` on the tick that
    /// crosses the 15 s boundary; cheap (one Date comparison + one counter
    /// read). Not a per-bundle demotion — that's a follow-up that needs
    /// persistent AppProfile storage.
    public func checkPushHealth() {
        guard mode == .push else { return }
        let now = Date()
        let sinceLastYield = now.timeIntervalSince(lastPushYieldAt)
        guard sinceLastYield > 15 else { return }
        // Push drove no frames for 15 s. If the user has engaged with their
        // machine in that window (any HID input recently), the AX observers
        // are failing silently — fall back to pull. `.mouseMoved` covers
        // the common "user is moving the cursor / typing" case without
        // requiring event-tap permissions.
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .mouseMoved
        )
        if idleSeconds < 15 {
            mode = .pull
            // Reset counters so we don't immediately re-evaluate.
            pushFramesProduced = 0
            lastPushYieldAt = now
        }
    }
}
