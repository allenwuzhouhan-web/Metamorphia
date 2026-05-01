/*
 * Metamorphia
 * Bridges BatteryActivityManager → MetamorphiaPerception.BatteryStateProvider.
 *
 * PerceptionBudget needs a BatteryStateProvider so it can park expensive
 * perception lanes on low battery. BatteryActivityManager owns the IOKit
 * power-source loop; this thin adapter translates its BatteryInfo/event API
 * into the protocol PerceptionBudget expects without adding an IOKit dependency
 * to the Computer package.
 */

import Foundation
import MetamorphiaPerception

// MARK: - BatteryStateAdapter

/// Adapts `BatteryActivityManager` to `MetamorphiaPerception.BatteryStateProvider`
/// so `PerceptionBudget.shared` can drive tier decisions from real battery state.
///
/// Usage (in MetamorphiaBootstrap):
/// ```swift
/// Task { await PerceptionBudget.shared.attach(battery: BatteryStateAdapter()) }
/// Task { await PerceptionBudget.shared.start() }
/// ```
public final class BatteryStateAdapter: BatteryStateProvider, @unchecked Sendable {

    private let manager: BatteryActivityManager

    public init() {
        self.manager = .shared
    }

    init(manager: BatteryActivityManager) {
        self.manager = manager
    }

    // MARK: - BatteryStateProvider

    public func currentBatteryState() -> BatteryStateSnapshot {
        let info = manager.initializeBatteryInfo()
        return BatteryStateSnapshot(
            onAC: info.isPluggedIn,
            isCharging: info.isCharging,
            percent: Double(info.currentCapacity),   // BatteryInfo.currentCapacity is 0–100 Float
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    public func observeBatteryChanges(_ onChange: @escaping @Sendable () -> Void) -> Any {
        // Register a BatteryActivityManager observer that fires onChange on any
        // power-source or charging event. The returned Int token is opaque to
        // PerceptionBudget; it holds it only to prevent deallocation.
        let token = manager.addObserver { event in
            switch event {
            case .powerSourceChanged, .batteryLevelChanged,
                 .isChargingChanged, .lowPowerModeChanged:
                onChange()
            default:
                break
            }
        }
        return token
    }
}
