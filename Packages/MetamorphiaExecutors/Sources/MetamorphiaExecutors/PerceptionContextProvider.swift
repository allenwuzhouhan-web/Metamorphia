import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

/// `SystemContextProvider` decorator that injects a `PerceptionSummary` into
/// every agent turn, derived from a continuously-running `PerceptionLoop`.
///
/// The loop ticks at 10 Hz by default, but only emits a frame when the screen
/// actually changes (see `PerceptionLoop`'s content-hash gating). This
/// provider subscribes to that change stream, derives a compact summary from
/// each new `ScreenMap`, and caches the latest. `currentContext()` is then
/// synchronous-cheap — it just reads the last cached summary.
///
/// The provider wraps (decorates) an inner `SystemContextProvider` so the host
/// can keep whatever non-perception context it was already producing (clipboard
/// previews, focus mode, battery, etc.) and get perception layered on top.
public final class PerceptionContextProvider: SystemContextProvider, @unchecked Sendable {

    private let inner: any SystemContextProvider
    private let perception: DefaultComputerPerception
    private let cache: PerceptionSummaryCache
    private let targetHz: Double

    private let startLock = NSLock()
    private var didStart = false
    private var streamTask: Task<Void, Never>?

    /// - Parameters:
    ///   - inner: The base context provider whose snapshot is augmented with a
    ///     perception summary. Defaults to `NullSystemContextProvider()`.
    ///   - perception: The ComputerLib entry point. Defaults to `.shared`.
    ///   - targetHz: Loop tick rate. Defaults to the value declared in
    ///     `PerceptionRuntime.host.loopCadenceHz`.
    ///   - cacheTTL: How long a cached summary is considered fresh before
    ///     `currentContext()` starts returning `nil` for the perception field.
    ///     Defaults to 2 s — longer than one perception tick but short enough
    ///     that a stale frame can't mislead the agent.
    public init(
        inner: any SystemContextProvider = NullSystemContextProvider(),
        perception: DefaultComputerPerception = .shared,
        targetHz: Double = PerceptionRuntime.host.loopCadenceHz,
        cacheTTL: TimeInterval = 2.0
    ) {
        self.inner = inner
        self.perception = perception
        self.targetHz = targetHz
        self.cache = PerceptionSummaryCache(ttl: cacheTTL)
    }

    /// Begin the perception loop and start consuming its stream. Idempotent.
    /// Callers must invoke this after the host has been bootstrapped and
    /// accessibility permission is in place — otherwise the first capture
    /// will return an empty element list.
    public func start() {
        startLock.lock()
        let shouldStart = !didStart
        if shouldStart { didStart = true }
        startLock.unlock()
        guard shouldStart else { return }

        let perception = self.perception
        let cache = self.cache
        let hz = self.targetHz

        streamTask = Task.detached(priority: .utility) {
            await perception.startPerceptionLoop(targetHz: hz)
            for await map in perception.observePerceptionStream() {
                let summary = Self.makeSummary(from: map)
                await cache.store(summary)
            }
        }
    }

    /// Stop consuming the stream. The underlying `PerceptionLoop` continues
    /// running for other subscribers; only this provider stops updating.
    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        startLock.lock()
        didStart = false
        startLock.unlock()
    }

    // MARK: - SystemContextProvider

    public func currentContext() async -> SystemContextSnapshot {
        let base = await inner.currentContext()
        let summary = await cache.current()
        return SystemContextSnapshot(
            frontmostApp: base.frontmostApp,
            currentTime: base.currentTime,
            isDarkMode: base.isDarkMode,
            volumeLevel: base.volumeLevel,
            clipboardPreview: base.clipboardPreview,
            frontmostWindowTitle: base.frontmostWindowTitle,
            terminalCWD: base.terminalCWD,
            finderSelection: base.finderSelection,
            batteryLevel: base.batteryLevel,
            wifiNetworkName: base.wifiNetworkName,
            activeDisplayCount: base.activeDisplayCount,
            focusMode: base.focusMode,
            perceptionSummary: summary
        )
    }

    public var lastCapturedAppName: String? {
        get async { await inner.lastCapturedAppName }
    }

    // MARK: - Summary derivation

    /// Reduce a full `ScreenMap` to the ~80-token summary that ships with the
    /// agent's per-turn system context. Runs in the consumer task, off the
    /// main actor.
    private static func makeSummary(from map: ScreenMap) -> PerceptionSummary {
        // Top N interactive elements, ranked by a simple heuristic: prefer
        // elements with non-empty labels, visible (has bounds), enabled.
        let topN = 5
        let topElements: [String] = map.elements
            .lazy
            .filter { $0.role.isInteractive && !$0.label.isEmpty && ($0.bounds?.isEmpty == false) }
            .prefix(topN * 4)          // over-fetch, then rank + trim
            .sorted { lhs, rhs in
                let lhsVisible = lhs.state.contains(.offScreen) ? 0 : 1
                let rhsVisible = rhs.state.contains(.offScreen) ? 0 : 1
                if lhsVisible != rhsVisible { return lhsVisible > rhsVisible }
                let lhsEnabled = lhs.state.contains(.disabled) ? 0 : 1
                let rhsEnabled = rhs.state.contains(.disabled) ? 0 : 1
                return lhsEnabled > rhsEnabled
            }
            .prefix(topN)
            .map { el in
                let trimmed = el.label.count > 40 ? String(el.label.prefix(37)) + "…" : el.label
                return "\(el.role.rawValue):\(trimmed)"
            }

        let loading = map.elements.contains { $0.state.contains(.loading) }

        var focusedIsSensitive = false
        var sensitiveKind: String? = nil
        if let focused = map.elements.first(where: { $0.state.contains(.focused) }),
           let result = SensitiveFieldDetector.classify(element: focused, allElements: map.elements) {
            focusedIsSensitive = true
            sensitiveKind = result.type.rawValue
        }

        let focusedApp = map.focusedApp.bundleID ?? map.focusedApp.name
        let windowTitle = map.windows.first(where: { $0.isFocused })?.title
            ?? map.windows.first?.title

        return PerceptionSummary(
            capturedAt: map.timestamp,
            focusedApp: focusedApp,
            focusedWindowTitle: windowTitle,
            topElements: Array(topElements),
            loadingIndicatorPresent: loading,
            focusedFieldIsSensitive: focusedIsSensitive,
            sensitiveKind: sensitiveKind
        )
    }
}

/// Actor-isolated store for the latest `PerceptionSummary`. Drops stale
/// entries at `current()` time rather than on a timer to avoid extra tasks.
private actor PerceptionSummaryCache {
    private var latest: PerceptionSummary?
    private let ttl: TimeInterval

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func store(_ summary: PerceptionSummary) {
        latest = summary
    }

    func current() -> PerceptionSummary? {
        guard let latest else { return nil }
        return Date().timeIntervalSince(latest.capturedAt) <= ttl ? latest : nil
    }
}
