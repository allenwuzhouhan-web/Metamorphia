import Foundation
import IOKit.pwr_mgt

/// Holds an in-process power assertion that prevents the system from sleeping.
///
/// Uses `IOPMAssertionCreateWithName` so the assertion lives and dies with the
/// Metamorphia process — no `caffeinate` subprocess to leak across crashes.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    var isEnabled: Bool { isHeld }

    func setEnabled(_ on: Bool) {
        if on { hold() } else { release() }
    }

    private func hold() {
        guard !isHeld else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Metamorphia Keep Awake (remote)" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isHeld = true
            Logger.log("[RemoteCommands] KeepAwake on", category: .network)
        } else {
            Logger.log("[RemoteCommands] IOPMAssertionCreateWithName failed: \(result)", category: .error)
        }
    }

    private func release() {
        guard isHeld else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            Logger.log("[RemoteCommands] KeepAwake off", category: .network)
        } else {
            Logger.log("[RemoteCommands] IOPMAssertionRelease failed: \(result)", category: .error)
        }
        assertionID = 0
        isHeld = false
    }
}
