import XCTest
@testable import MetamorphiaPerception

// MARK: - MockBatteryStateProvider

final class MockBatteryStateProvider: BatteryStateProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: BatteryStateSnapshot
    private var callbacks: [@Sendable () -> Void] = []

    init(snapshot: BatteryStateSnapshot = BatteryStateSnapshot(
        onAC: true, isCharging: true, percent: 100, isLowPowerMode: false)
    ) {
        _snapshot = snapshot
    }

    func currentBatteryState() -> BatteryStateSnapshot {
        lock.withLock { _snapshot }
    }

    func observeBatteryChanges(_ onChange: @escaping @Sendable () -> Void) -> Any {
        lock.withLock { callbacks.append(onChange) }
        return onChange as Any
    }

    func update(_ snapshot: BatteryStateSnapshot) {
        lock.withLock { _snapshot = snapshot }
        let cbs = lock.withLock { callbacks }
        for cb in cbs { cb() }
    }
}

// MARK: - Helpers

/// Build a budget in immediate-transition mode (hysteresis bypassed).
/// All tier reads settle synchronously after inject calls.
private func makeBudget(
    onAC: Bool = true,
    percent: Double = 100,
    isLowPower: Bool = false,
    thermal: ProcessInfo.ThermalState = .nominal,
    idleSeconds: TimeInterval = 0
) async -> (PerceptionBudget, MockBatteryStateProvider) {
    let battery = MockBatteryStateProvider(snapshot: BatteryStateSnapshot(
        onAC: onAC, isCharging: onAC, percent: percent, isLowPowerMode: isLowPower
    ))
    let budget = PerceptionBudget()
    await budget.enableImmediateTransitions()
    await budget.attach(battery: battery)
    await budget.injectThermalState(thermal)
    await budget.injectUserIdleSeconds(idleSeconds)
    return (budget, battery)
}

// MARK: - PerceptionBudgetTests

final class PerceptionBudgetTests: XCTestCase {

    // MARK: - Global tier transitions

    func testFullTier_acPlugged_nominalThermal_activeUser() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .full)
    }

    func testFullTier_batteryAbove50_nominalThermal() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 60, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .full)
    }

    func testReducedTier_batteryIn20to50Range() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 35, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .reduced)
    }

    func testReducedTier_fairThermal() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .fair, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .reduced)
    }

    func testReducedTier_idleIn60to300Range() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .nominal, idleSeconds: 120)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .reduced)
    }

    func testMinimalTier_seriousThermal() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .serious, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .minimal)
    }

    func testMinimalTier_lowPowerMode() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, isLowPower: true, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .minimal)
    }

    func testMinimalTier_batteryBelow20_notAC() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 15, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .minimal)
    }

    func testMinimalTier_userIdleOver300() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .nominal, idleSeconds: 400)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .minimal)
    }

    func testParkedTier_criticalThermal() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .critical, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .parked)
    }

    func testParkedTier_batteryBelow10_notAC() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 8, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .axPoll)
        XCTAssertEqual(t, .parked)
    }

    // MARK: - Per-lane × tier matrix

    func testLaneMatrix_browserDOM_atGlobalMinimal_returnsParked() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 15, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .browserDOM)
        // global = minimal; browserDOM at minimal → parked; clipped at global minimal → parked (parked < minimal)
        XCTAssertEqual(t, .parked)
    }

    func testLaneMatrix_browserDOM_atGlobalReduced_returnsReduced() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 35, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .browserDOM)
        XCTAssertEqual(t, .reduced)
    }

    func testLaneMatrix_clipboardWatch_atGlobalFull_returnsFull() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .clipboardWatch)
        XCTAssertEqual(t, .full)
    }

    func testLaneMatrix_clipboardWatch_atGlobalReduced_returnsReduced() async {
        // clipboardWatch table says .full at reduced; but clip at global (.reduced) → .reduced
        let (budget, _) = await makeBudget(onAC: false, percent: 35, thermal: .nominal, idleSeconds: 0)
        let global = budget.current
        XCTAssertEqual(global, .reduced, "Precondition: global should be reduced")
        let t = await budget.tier(for: .clipboardWatch)
        XCTAssertEqual(t, .reduced, "clipboardWatch clipped from table-.full down to global-.reduced")
    }

    func testLaneMatrix_menuBarRead_atGlobalParked_returnsMinimal() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 8, thermal: .nominal, idleSeconds: 0)
        let global = budget.current
        XCTAssertEqual(global, .parked, "Precondition")
        let t = await budget.tier(for: .menuBarRead)
        // table says .minimal at parked; clip at global .parked → min(.minimal, .parked) = .parked
        XCTAssertEqual(t, .parked)
    }

    func testLaneMatrix_windowEnum_atGlobalParked_returnsParked() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 8, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .windowEnum)
        // table says .minimal at parked; clipped at global .parked → .parked
        XCTAssertEqual(t, .parked)
    }

    func testLaneMatrix_screenHarvest_atGlobalMinimal_returnsParked() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 15, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .screenHarvest)
        XCTAssertEqual(t, .parked)
    }

    func testLaneMatrix_driftScan_atGlobalMinimal_returnsParked() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 15, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .driftScan)
        XCTAssertEqual(t, .parked)
    }

    func testLaneMatrix_selection_atGlobalMinimal_returnsMinimal() async {
        let (budget, _) = await makeBudget(onAC: false, percent: 15, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .selection)
        XCTAssertEqual(t, .minimal)
    }

    func testLaneMatrix_documentWatch_atGlobalFull_returnsFull() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .nominal, idleSeconds: 0)
        let t = await budget.tier(for: .documentWatch)
        XCTAssertEqual(t, .full)
    }

    // MARK: - Hysteresis
    // These tests build budgets WITHOUT immediate-transition mode so real timing is exercised.

    /// Production hysteresis is 5 s / 10 s. For tests we scale both by 50×
    /// (0.1 s / 0.2 s) — small enough to not flake on busy CI, large enough
    /// to meaningfully exercise the same transition code paths.
    private static let testLowerDelay: TimeInterval = 0.1
    private static let testRaiseCooldown: TimeInterval = 0.2

    private func makeHysteresisBudget() async -> PerceptionBudget {
        let battery = MockBatteryStateProvider(snapshot: BatteryStateSnapshot(
            onAC: true, isCharging: true, percent: 100, isLowPowerMode: false
        ))
        let budget = PerceptionBudget()
        // Do NOT call enableImmediateTransitions — hysteresis is required here.
        await budget.configureHysteresis(
            lowerDelay: Self.testLowerDelay,
            raiseCooldown: Self.testRaiseCooldown
        )
        await budget.attach(battery: battery)
        await budget.injectThermalState(.nominal)
        await budget.injectUserIdleSeconds(0)
        // The first recompute from inject calls schedules a pending lower when
        // going from the default .full with nominal/100% to the same .full —
        // no pending lower is created since raw == committed. All good.
        return budget
    }

    func testHysteresis_rapidNominalSeriousFlip_doesNotFlap() async {
        let budget = await makeHysteresisBudget()
        // Default store tier is .full; injected nominal+100% also produces .full —
        // so no pending lower exists and current is .full.
        XCTAssertEqual(budget.current, .full)

        // Flip nominal ↔ serious faster than the lower delay (0.1 s). Every
        // nominal injection cancels the pending lower; result: no commit.
        // 10 flips × 20 ms = 200 ms total, which is > lowerDelay but the
        // cancels always arrive before the commit task fires.
        for i in 0..<10 {
            if i % 2 == 0 {
                await budget.injectThermalState(.serious)
            } else {
                await budget.injectThermalState(.nominal)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(budget.current, .full, "Hysteresis should prevent tier flap during rapid oscillation")
    }

    func testHysteresis_stableDropPersists() async throws {
        let budget = await makeHysteresisBudget()
        XCTAssertEqual(budget.current, .full)

        // Inject a stable serious thermal and hold for well over the lower delay.
        await budget.injectThermalState(.serious)
        try await Task.sleep(nanoseconds: UInt64(Self.testLowerDelay * 3 * 1_000_000_000))

        XCTAssertEqual(budget.current, .minimal, "Stable lower signal should commit after lowerDelay")
    }

    func testHysteresis_raise_blocked_by_cooldown() async throws {
        let budget = await makeHysteresisBudget()
        XCTAssertEqual(budget.current, .full)

        // Commit a lower via stable serious thermal. Wait just past the lower
        // delay so the commit has fired but we've spent almost no cooldown budget.
        await budget.injectThermalState(.serious)
        try await Task.sleep(nanoseconds: UInt64(Self.testLowerDelay * 1.2 * 1_000_000_000))
        XCTAssertEqual(budget.current, .minimal)

        // Immediately recover to nominal — raise must be blocked for raiseCooldown.
        // At this point elapsed-since-lower ≈ 0.02 s, well under 0.2 s cooldown.
        await budget.injectThermalState(.nominal)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(budget.current, .minimal, "Raise should be blocked by raiseCooldown window")
    }

    // MARK: - shouldForceResnapshot

    func testShouldForceResnapshot_firesOncePerLaneOnUnpark() async throws {
        // Immediate-transition mode: park and unpark happen synchronously.
        let (budget, battery) = await makeBudget(onAC: false, percent: 8, thermal: .nominal, idleSeconds: 0)
        XCTAssertEqual(budget.current, .parked, "Should start parked (< 10% not on AC)")

        // Recover: AC plugged, full battery.
        battery.update(BatteryStateSnapshot(onAC: true, isCharging: true, percent: 100, isLowPowerMode: false))
        // The battery callback spawns a Task on the actor; give it time to execute.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(budget.current, .full, "Should unpark after battery recovery in immediate mode")

        let firstCall = await budget.shouldForceResnapshot(lane: .axPoll)
        let secondCall = await budget.shouldForceResnapshot(lane: .axPoll)
        XCTAssertTrue(firstCall, "First call after park→unpark should return true")
        XCTAssertFalse(secondCall, "Second call should return false")
    }

    func testShouldForceResnapshot_doesNotFireWhenNoParkTransition() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .nominal, idleSeconds: 0)
        // Full → never parked, so resnapshot should not fire.
        let r = await budget.shouldForceResnapshot(lane: .axPoll)
        XCTAssertFalse(r, "No park→unpark transition should produce false")
    }

    // MARK: - nonisolated current

    func testNonisolatedCurrent_readableOffActor() async {
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .nominal, idleSeconds: 0)
        // `current` is nonisolated; verify it's readable synchronously.
        let t = budget.current
        XCTAssertEqual(t, .full)
    }

    // MARK: - tierChanges stream

    func testTierChanges_emitsOnTransition() async throws {
        // Use immediate-transition mode so we don't wait 5 s for the lower to commit.
        let (budget, _) = await makeBudget(onAC: true, percent: 100, thermal: .nominal, idleSeconds: 0)
        XCTAssertEqual(budget.current, .full)

        var received: [BudgetTier] = []
        let stream = budget.tierChanges

        // Subscribe first and let the registration Task run on the actor.
        let collector = Task {
            for await tier in stream {
                received.append(tier)
                if received.count >= 1 { break }
            }
        }

        // Wait for the continuation registration Task to execute on the actor.
        try await Task.sleep(nanoseconds: 50_000_000)

        // In immediate mode, injection commits instantly and fans out to subscribers.
        await budget.injectThermalState(.serious)
        try await Task.sleep(nanoseconds: 50_000_000)

        collector.cancel()
        XCTAssertFalse(received.isEmpty, "tierChanges should emit at least one value after lowering")
        XCTAssertEqual(received.last, .minimal)
    }

    // MARK: - BatteryStateSnapshot injection via provider

    func testBatteryProviderUpdate_triggersRecompute() async throws {
        let battery = MockBatteryStateProvider(snapshot: BatteryStateSnapshot(
            onAC: true, isCharging: true, percent: 100, isLowPowerMode: false
        ))
        let budget = PerceptionBudget()
        await budget.enableImmediateTransitions()
        await budget.attach(battery: battery)
        await budget.injectThermalState(.nominal)
        await budget.injectUserIdleSeconds(0)
        XCTAssertEqual(budget.current, .full)

        // Update battery to simulate cable unplug with low battery. The callback
        // spawns a Task → signalBatteryChanged → recompute; a brief sleep
        // ensures the actor hop completes before we assert.
        battery.update(BatteryStateSnapshot(onAC: false, isCharging: false, percent: 8, isLowPowerMode: false))
        try await Task.sleep(nanoseconds: 50_000_000)
        // Should now be parked (< 10 % and not on AC).
        XCTAssertEqual(budget.current, .parked)
    }
}
