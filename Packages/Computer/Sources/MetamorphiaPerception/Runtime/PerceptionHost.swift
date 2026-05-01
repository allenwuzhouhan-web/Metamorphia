import Foundation

/// Host-provided configuration injected into ComputerLib at app launch.
/// The host (e.g. Metamorphia) decides where persistent state lives and
/// which subsystems to enable. All ComputerLib singletons that require
/// filesystem paths or tunable defaults pull them from `PerceptionRuntime.host`.
public struct PerceptionHost: Sendable {
    /// Directory in which ComputerLib may create files (SQLite DB, caches, profiles).
    /// Typically `~/Library/Application Support/Metamorphia/perception/`.
    public let applicationSupportDir: URL

    /// Filename for the learning SQLite database, placed inside `applicationSupportDir`.
    public let databaseFilename: String

    /// When true, `PerceptionLoop` may be started by the host.
    public let enablePerceptionLoop: Bool

    /// Target cadence for `PerceptionLoop` when enabled.
    public let loopCadenceHz: Double

    /// When true, `BrowserDOMCapture` / `BrowserDOMFetcher` may issue AppleScript
    /// calls to Safari / Chrome / Arc / Edge / Brave / Vivaldi.
    public let enableBrowserDOM: Bool

    public init(
        applicationSupportDir: URL,
        databaseFilename: String = "perception.db",
        enablePerceptionLoop: Bool = true,
        loopCadenceHz: Double = 10,
        enableBrowserDOM: Bool = true
    ) {
        self.applicationSupportDir = applicationSupportDir
        self.databaseFilename = databaseFilename
        self.enablePerceptionLoop = enablePerceptionLoop
        self.loopCadenceHz = loopCadenceHz
        self.enableBrowserDOM = enableBrowserDOM
    }
}

/// Global runtime anchor for host-provided perception configuration.
/// The host application calls `PerceptionRuntime.bootstrap(_:)` exactly once,
/// before any `.shared` singleton inside ComputerLib is touched. Tests call
/// `bootstrapForTests()` instead.
public enum PerceptionRuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _host: PerceptionHost?

    /// Install the host configuration. Safe to call exactly once per process.
    /// Performs a one-shot migration from the legacy `~/Library/Application Support/Computer/`
    /// directory on first launch.
    public static func bootstrap(_ host: PerceptionHost) {
        lock.lock()
        defer { lock.unlock() }
        if _host != nil { return }
        _host = host
        Self.migrateLegacyStateIfNeeded(host: host)
    }

    /// Host accessor. Crashes if `bootstrap` has not been called — by design: all
    /// ComputerLib consumers must be routed through the host's application-support dir.
    public static var host: PerceptionHost {
        lock.lock()
        defer { lock.unlock() }
        guard let h = _host else {
            preconditionFailure("PerceptionRuntime.bootstrap(_:) must be called before accessing any ComputerLib perception API.")
        }
        return h
    }

    /// Test hook. Creates a unique temporary directory and registers it as the host.
    /// Safe to call multiple times; each call overwrites the host in-place.
    @discardableResult
    public static func bootstrapForTests() -> PerceptionHost {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-perception-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let host = PerceptionHost(
            applicationSupportDir: tmp,
            databaseFilename: "test.db",
            enablePerceptionLoop: false,
            enableBrowserDOM: false
        )
        lock.lock()
        _host = host
        lock.unlock()
        return host
    }

    public static var isBootstrapped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _host != nil
    }

    /// If `~/Library/Application Support/Computer/elements.db` exists and the new
    /// location is empty, atomically move the DB and its WAL sidecars into place.
    /// Runs once during bootstrap, before any SQLite connection opens.
    private static func migrateLegacyStateIfNeeded(host: PerceptionHost) {
        let fm = FileManager.default
        let legacyDir = URL.applicationSupportDirectory
            .appendingPathComponent("Computer", isDirectory: true)
        let legacyDB = legacyDir.appendingPathComponent("elements.db")
        let newDB = host.applicationSupportDir.appendingPathComponent(host.databaseFilename)

        guard fm.fileExists(atPath: legacyDB.path),
              !fm.fileExists(atPath: newDB.path) else {
            return
        }

        do {
            try fm.createDirectory(at: host.applicationSupportDir, withIntermediateDirectories: true)
            // Main DB + WAL + SHM sidecars.
            let moves: [(URL, URL)] = [
                (legacyDB, newDB),
                (legacyDir.appendingPathComponent("elements.db-wal"),
                 host.applicationSupportDir.appendingPathComponent("\(host.databaseFilename)-wal")),
                (legacyDir.appendingPathComponent("elements.db-shm"),
                 host.applicationSupportDir.appendingPathComponent("\(host.databaseFilename)-shm")),
            ]
            for (src, dst) in moves where fm.fileExists(atPath: src.path) {
                try fm.moveItem(at: src, to: dst)
            }
            print("[PerceptionRuntime] Migrated legacy DB → \(newDB.path)")
        } catch {
            print("[PerceptionRuntime] Migration failed (\(error)); continuing with fresh DB at \(newDB.path).")
        }
    }
}
