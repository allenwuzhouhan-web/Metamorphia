import Foundation
import CoreGraphics

// MARK: - BudgetTier

public enum BudgetTier: Int, Sendable, Comparable, Codable {
    case parked = 0, minimal = 1, reduced = 2, full = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - PerceptionLane

public enum PerceptionLane: String, Sendable, CaseIterable, Codable {
    case axPoll, dhashDiff, ocrFallback, browserDOM, menuBarRead,
         windowEnum, clipboardWatch, screenHarvest, driftScan,
         selection, documentWatch
}

// MARK: - BatteryStateSnapshot

public struct BatteryStateSnapshot: Sendable {
    public let onAC: Bool
    public let isCharging: Bool
    /// 0..100. Supply 100 if unknown (safest assumption — won't artificially park).
    public let percent: Double
    public let isLowPowerMode: Bool

    public init(onAC: Bool, isCharging: Bool, percent: Double, isLowPowerMode: Bool) {
        self.onAC = onAC
        self.isCharging = isCharging
        self.percent = percent
        self.isLowPowerMode = isLowPowerMode
    }
}

// MARK: - BatteryStateProvider

/// Role interface injected at bootstrap by the host-app target.
/// Designed so BatteryActivityManager can conform from inside the Metamorphia
/// target, keeping this package independent of IOKit.
public protocol BatteryStateProvider: AnyObject, Sendable {
    func currentBatteryState() -> BatteryStateSnapshot
    func observeBatteryChanges(_ onChange: @escaping @Sendable () -> Void) -> Any
}

// MARK: - TierStore

/// Lock-backed reference container. Stored as a nonisolated let on the actor
/// so nonisolated callers can read the tier without crossing the isolation boundary.
private final class TierStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _tier: BudgetTier = .full

    var tier: BudgetTier {
        get { lock.withLock { _tier } }
        set { lock.withLock { _tier = newValue } }
    }

    func exchange(_ newTier: BudgetTier) -> BudgetTier {
        lock.withLock {
            let old = _tier
            _tier = newTier
            return old
        }
    }
}

// MARK: - PerceptionBudget

/// Thermal / battery / user-presence-aware tier publisher.
///
/// Every perception lane consults this actor before doing expensive work.
/// Wiring (host-app bootstrap):
/// ```swift
/// await PerceptionBudget.shared.attach(battery: BatteryActivityManager.shared)
/// await PerceptionBudget.shared.start()
/// ```
public actor PerceptionBudget {

    // MARK: Shared instance

    public static let shared = PerceptionBudget()

    // MARK: Tier store (nonisolated; lock-protected)

    nonisolated private let store = TierStore()

    // MARK: Hysteresis

    private var lastLowerAt: Date = .distantPast
    private var pendingLower: BudgetTier?
    private var pendingLowerTask: Task<Void, Never>?

    // MARK: Injected signals

    private var battery: BatteryStateProvider?
    private var batteryToken: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var injectedThermal: ProcessInfo.ThermalState?
    private var injectedIdleSeconds: TimeInterval?

    // MARK: Polling

    private var idlePollTask: Task<Void, Never>?

    // MARK: Per-lane resnapshot

    private var wasParked: [PerceptionLane: Bool] = [:]
    private var pendingResnapshot: Set<PerceptionLane> = []

    // MARK: Test configuration

    /// When true, hysteresis delays are bypassed and tiers commit immediately.
    private var immediateTransitions: Bool = false

    /// Seconds a lowering signal must persist before the tier drops. Production
    /// default: 5 s. Tests may shrink this via ``configureHysteresis(lowerDelay:raiseCooldown:)``
    /// to exercise timing without paying the full production budget.
    private var hysteresisLowerDelay: TimeInterval = 5.0

    /// Seconds after a lower before a raise is permitted. Production default: 10 s.
    private var hysteresisRaiseCooldown: TimeInterval = 10.0

    // MARK: Subscribers

    private var tierContinuations: [UUID: AsyncStream<BudgetTier>.Continuation] = [:]

    // MARK: Init

    public init() {}

    // MARK: Public nonisolated

    /// Lock-free tier read; safe from any context.
    public nonisolated var current: BudgetTier { store.tier }

    /// Hot stream of tier changes. Call current for the latest value on subscription.
    public nonisolated var tierChanges: AsyncStream<BudgetTier> {
        AsyncStream<BudgetTier>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let id = UUID()
            Task { [weak self] in
                await self?.registerContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterContinuation(id: id) }
            }
        }
    }

    // MARK: Actor-isolated API

    /// Lane-specific tier, clipped at the global tier.
    public func tier(for lane: PerceptionLane) -> BudgetTier {
        let global = store.tier
        let laneTier = Self.laneTierTable[lane]?[global] ?? global
        return min(laneTier, global)
    }

    /// True once per lane on park → unpark; resets after each call.
    public func shouldForceResnapshot(lane: PerceptionLane) -> Bool {
        if pendingResnapshot.contains(lane) {
            pendingResnapshot.remove(lane)
            return true
        }
        return false
    }

    // MARK: Wiring

    public func attach(battery: BatteryStateProvider) {
        batteryToken = nil
        self.battery = battery
        batteryToken = battery.observeBatteryChanges { [weak self] in
            Task { await self?.signalBatteryChanged() }
        }
    }

    public func start() {
        // Idempotency: a double start (without an intervening stop) must not
        // stack observers. If already started, this is a no-op.
        guard notificationTokens.isEmpty else { return }

        let thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in Task { await self?.recompute() } }

        let powerToken = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in Task { await self?.recompute() } }

        notificationTokens = [thermalToken, powerToken]

        startIdlePolling()
        recompute()
    }

    public func stop() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        batteryToken = nil
        battery = nil
        idlePollTask?.cancel(); idlePollTask = nil
        pendingLowerTask?.cancel(); pendingLowerTask = nil
    }

    // MARK: Test seams

    /// Disable hysteresis delays entirely. Call before injecting state in unit tests
    /// so tier changes take effect synchronously without 5 s / 10 s waits.
    public func enableImmediateTransitions() {
        immediateTransitions = true
    }

    /// Configure hysteresis timing for tests. Production code should never call this.
    /// Passing values at least 10× smaller than production keeps the hysteresis logic
    /// exercised while preventing flakes on busy CI machines.
    public func configureHysteresis(lowerDelay: TimeInterval, raiseCooldown: TimeInterval) {
        hysteresisLowerDelay = lowerDelay
        hysteresisRaiseCooldown = raiseCooldown
    }

    public func injectThermalState(_ state: ProcessInfo.ThermalState) {
        injectedThermal = state
        recompute()
    }

    public func injectUserIdleSeconds(_ seconds: TimeInterval) {
        injectedIdleSeconds = seconds
        recompute()
    }

    // MARK: Internal

    private func signalBatteryChanged() { recompute() }

    private func startIdlePolling() {
        idlePollTask?.cancel()
        idlePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.recompute()
            }
        }
    }

    private func recompute() {
        let raw = computeRaw()
        applyHysteresis(raw: raw)
    }

    private func computeRaw() -> BudgetTier {
        let thermal = injectedThermal ?? ProcessInfo.processInfo.thermalState
        let sysLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let snap = battery?.currentBatteryState()
            ?? BatteryStateSnapshot(onAC: true, isCharging: false, percent: 100, isLowPowerMode: sysLowPower)
        let idle: TimeInterval = (injectedIdleSeconds.map { $0 >= 0 ? $0 : nil } ?? nil)
            ?? Self.queryCGIdleSeconds()

        if thermal == .critical { return .parked }
        if snap.percent < 10 && !snap.onAC { return .parked }

        if snap.percent < 20 || thermal == .serious || snap.isLowPowerMode || sysLowPower || idle >= 300 {
            return .minimal
        }

        let batteryReduced = snap.percent >= 20 && snap.percent < 50
        let idleReduced = idle >= 60 && idle < 300
        if batteryReduced || thermal == .fair || idleReduced { return .reduced }

        if (snap.onAC || snap.percent >= 50) && idle < 60 { return .full }

        return .reduced
    }

    private func applyHysteresis(raw: BudgetTier) {
        let committed = store.tier

        if immediateTransitions {
            // Bypass all delay/cooldown constraints in test mode.
            if raw != committed { commitTier(raw) }
            return
        }

        if raw < committed {
            if pendingLower == nil || raw < pendingLower! {
                pendingLower = raw
                pendingLowerTask?.cancel()
                let capturedRaw = raw
                let delayNanos = UInt64(max(0, hysteresisLowerDelay) * 1_000_000_000)
                pendingLowerTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: delayNanos)
                    guard !Task.isCancelled else { return }
                    await self?.commitPendingLower(expected: capturedRaw)
                }
            }
        } else if raw > committed {
            guard Date().timeIntervalSince(lastLowerAt) >= hysteresisRaiseCooldown else { return }
            pendingLower = nil
            pendingLowerTask?.cancel(); pendingLowerTask = nil
            commitTier(raw)
        } else {
            if pendingLower != nil {
                pendingLower = nil
                pendingLowerTask?.cancel(); pendingLowerTask = nil
            }
        }
    }

    private func commitPendingLower(expected: BudgetTier) {
        let committed = store.tier
        guard expected < committed, pendingLower == expected else { return }
        pendingLower = nil; pendingLowerTask = nil
        lastLowerAt = Date()
        commitTier(expected)
    }

    private func commitTier(_ tier: BudgetTier) {
        let previous = store.exchange(tier)
        guard tier != previous else { return }
        updateResnapshot(previous: previous, next: tier)
        for (_, cont) in tierContinuations { cont.yield(tier) }
    }

    private func updateResnapshot(previous: BudgetTier, next: BudgetTier) {
        if next == .parked {
            for lane in PerceptionLane.allCases { wasParked[lane] = true }
        } else if previous == .parked {
            for lane in PerceptionLane.allCases {
                let prev = min(Self.laneTierTable[lane]?[previous] ?? previous, previous)
                let nxt  = min(Self.laneTierTable[lane]?[next] ?? next, next)
                if prev == .parked && nxt != .parked {
                    pendingResnapshot.insert(lane)
                    wasParked[lane] = false
                }
            }
        }
    }

    private func registerContinuation(id: UUID, continuation: AsyncStream<BudgetTier>.Continuation) {
        tierContinuations[id] = continuation
    }

    private func unregisterContinuation(id: UUID) {
        tierContinuations.removeValue(forKey: id)
    }

    private static func queryCGIdleSeconds() -> TimeInterval {
        let eventType = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: eventType)
    }

    // MARK: Lane × tier table

    private static let laneTierTable: [PerceptionLane: [BudgetTier: BudgetTier]] = {
        func row(_ f: BudgetTier, _ r: BudgetTier, _ m: BudgetTier, _ p: BudgetTier) -> [BudgetTier: BudgetTier] {
            [.full: f, .reduced: r, .minimal: m, .parked: p]
        }
        return [
            .axPoll:         row(.full, .reduced, .minimal, .parked),
            .dhashDiff:      row(.full, .reduced, .minimal, .parked),
            .ocrFallback:    row(.full, .reduced, .minimal, .parked),
            .browserDOM:     row(.full, .reduced, .parked,  .parked),
            .menuBarRead:    row(.full, .reduced, .reduced, .minimal),
            .windowEnum:     row(.full, .reduced, .minimal, .minimal),
            .clipboardWatch: row(.full, .full,    .reduced, .reduced),
            .screenHarvest:  row(.full, .reduced, .parked,  .parked),
            .driftScan:      row(.full, .reduced, .parked,  .parked),
            .selection:      row(.full, .reduced, .minimal, .parked),
            .documentWatch:  row(.full, .reduced, .minimal, .parked),
        ]
    }()
}
