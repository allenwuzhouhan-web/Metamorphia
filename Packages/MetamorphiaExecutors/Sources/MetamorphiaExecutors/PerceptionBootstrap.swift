import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception
import MetamorphiaToolProtocol

/// Thin façade over `ComputerLib.PerceptionRuntime` so the main Metamorphia app
/// target can wire up ComputerLib's persistence layer without importing
/// ComputerLib directly. The app calls `PerceptionBootstrap.configure(...)`
/// exactly once during launch; every subsequent access to `ElementDatabase.shared`,
/// `DefaultComputerPerception.shared`, etc. routes through the host configuration
/// installed here.
public enum PerceptionBootstrap {

    /// Install the Metamorphia-flavored perception host. Idempotent — the
    /// underlying `PerceptionRuntime.bootstrap` call is a no-op on subsequent
    /// invocations.
    ///
    /// - Parameter applicationSupportDir: Metamorphia's app-support root
    ///   (typically `~/Library/Application Support/Metamorphia`). A `perception`
    ///   subdirectory is created inside this for the SQLite learning database.
    /// - Parameter enablePerceptionLoop: Whether the 10 Hz ambient perception
    ///   loop may be started by the host. Defaults to true.
    /// - Parameter loopCadenceHz: Target tick rate for the ambient loop when
    ///   enabled. Defaults to 10 Hz.
    /// - Parameter enableBrowserDOM: Whether AppleScript-driven browser DOM
    ///   capture is permitted (requires `NSAppleEventsUsageDescription`).
    public static func configure(
        applicationSupportDir: URL,
        enablePerceptionLoop: Bool = true,
        loopCadenceHz: Double = 10,
        enableBrowserDOM: Bool = true
    ) {
        let perceptionDir = applicationSupportDir
            .appendingPathComponent("perception", isDirectory: true)
        PerceptionRuntime.bootstrap(PerceptionHost(
            applicationSupportDir: perceptionDir,
            databaseFilename: "perception.db",
            enablePerceptionLoop: enablePerceptionLoop,
            loopCadenceHz: loopCadenceHz,
            enableBrowserDOM: enableBrowserDOM
        ))
    }

    /// Whether `configure` has been called at least once this process lifetime.
    public static var isConfigured: Bool {
        PerceptionRuntime.isBootstrapped
    }

    /// Build the perception-backed argument safety inspector. The app target
    /// registers the returned value on its `ToolSafetyGate` so gesture clicks
    /// on destructive elements (Delete account, Erase all, …) and typing into
    /// sensitive form fields auto-escalate to `.critical`. See
    /// ``PerceptionSafetyInspector`` for the full classification rules.
    public static func makeSafetyInspector() -> any ToolArgumentSafetyInspector {
        PerceptionSafetyInspector()
    }

    /// Build a `SystemContextProvider` that injects an ambient
    /// `PerceptionSummary` into every agent turn. Wraps the supplied `inner`
    /// provider so the host's existing context (clipboard preview, focus mode,
    /// battery, …) is preserved.
    ///
    /// Call `start()` on the returned provider after accessibility permission
    /// has been granted. When the configured host disables the perception loop
    /// (`PerceptionHost.enablePerceptionLoop == false`), the provider still
    /// works as a passthrough for `inner`.
    public static func makeContextProvider(
        wrapping inner: any SystemContextProvider = NullSystemContextProvider()
    ) -> PerceptionContextProvider {
        PerceptionContextProvider(inner: inner)
    }
}
