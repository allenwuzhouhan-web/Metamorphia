import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

// MARK: - SessionSegmenter

/// Consumes ``ActivityEvent`` values from an ``ActivityStream`` and emits
/// `.sessionClosed` events back into the same stream when a coherent work
/// session ends.
///
/// ## Session lifecycle
/// A session begins on the first `.focusChanged` event received after start or
/// after a previous session closes.  It ends when:
/// - The user switches to a different application (after a 30-second flicker
///   window to absorb quick cmd-tab round-trips), or
/// - The user goes idle and then resumes input.
///
/// ## Privacy
/// `docHint` is derived from the window title but stripped of URLs, passwords,
/// and incognito indicators before being emitted.  If any sensitive pattern is
/// detected the field is set to `nil`.
///
/// ## Thread safety
/// `SessionSegmenter` is a Swift actor; all state mutations are actor-isolated.
public actor SessionSegmenter {

    // MARK: - Public types

    /// Returns the current input cadence tier.  Injected at construction so the
    /// segmenter (which lives in the package) does not need to import the host
    /// app's `InputCadenceTracker`.
    public typealias CadenceProvider = @Sendable () -> CadenceTier

    // MARK: - Configuration

    /// Sessions shorter than this threshold are silently discarded.
    static let minimumDurationSeconds: TimeInterval = 120

    /// Production flicker window (30 s).  Override via the internal init for
    /// tests so they don't have to sleep 30 s per case.
    static let defaultFlickerWindowSeconds: TimeInterval = 30

    // Instance-level flicker window so tests can inject a shorter value.
    let flickerWindowSeconds: TimeInterval

    // MARK: - State

    private let stream: ActivityStream
    private let cadenceProvider: CadenceProvider

    /// The active (currently focused) session.
    private var current: OpenSession?

    /// The session that was displaced but is pending a delayed close.
    /// If the user returns to this session's bundleID within the flicker
    /// window we cancel the close and make it `current` again.
    private var staged: OpenSession?

    /// The Task managing the flicker-window delay.  Cancel to abort the close.
    private var flickerTask: Task<Void, Never>?

    /// When set, the user went idle at this time.  Used to anchor the session
    /// end-time at `current.lastActiveAt` rather than resume time.
    private var idleSince: Date?

    /// The Combine subscription to `ActivityStream.events`.
    private var subscription: AnyCancellable?

    // MARK: - Init

    public init(stream: ActivityStream, cadenceProvider: @escaping CadenceProvider) {
        self.stream = stream
        self.cadenceProvider = cadenceProvider
        self.flickerWindowSeconds = Self.defaultFlickerWindowSeconds
    }

    /// Internal initialiser that allows tests to inject a shorter flicker window.
    init(
        stream: ActivityStream,
        cadenceProvider: @escaping CadenceProvider,
        flickerWindowSeconds: TimeInterval
    ) {
        self.stream = stream
        self.cadenceProvider = cadenceProvider
        self.flickerWindowSeconds = flickerWindowSeconds
    }

    // MARK: - Lifecycle

    /// Begin consuming events from the stream.
    ///
    /// Idempotent — calling `start()` while already running replaces the
    /// previous subscription.
    public func start() {
        subscription = stream.events
            .sink { [weak self] event in
                guard let self else { return }
                Task { await self.handle(event) }
            }
    }

    /// Stop consuming events.  Any in-progress session is abandoned (not closed).
    public func stop() {
        flickerTask?.cancel()
        flickerTask = nil
        subscription = nil
        current = nil
        staged = nil
        idleSince = nil
    }

    // MARK: - Dispatch

    private func handle(_ event: ActivityEvent) async {
        switch event {
        case let .focusChanged(bundleID, appName, windowTitle, _, at):
            await onFocusChanged(bundleID: bundleID, appName: appName, windowTitle: windowTitle, at: at)
        case let .inputIdle(_, at):
            onIdle(at: at)
        case let .inputResumed(_, at):
            await onResumed(at: at)
        default:
            break
        }
    }

    // MARK: - focusChanged

    private func onFocusChanged(
        bundleID: String,
        appName: String,
        windowTitle: String?,
        at: Date
    ) async {

        // ── Case 1: user returns to a bundle that has a staged (pending) close ──
        if let s = staged, s.bundleID == bundleID {
            flickerTask?.cancel()
            flickerTask = nil
            // Bring the staged session back as current, updating activity time.
            var restored = s
            restored.lastWindowTitle = windowTitle ?? s.lastWindowTitle
            restored.lastActiveAt = at
            current = restored
            staged = nil
            idleSince = nil
            return
        }

        // ── Case 2: no active session yet ──
        guard let session = current else {
            current = OpenSession(
                bundleID: bundleID,
                appName: appName,
                startedAt: at,
                lastWindowTitle: windowTitle,
                lastActiveAt: at
            )
            idleSince = nil
            return
        }

        // ── Case 3: same bundle, different window ──
        if bundleID == session.bundleID {
            current?.lastWindowTitle = windowTitle
            current?.lastActiveAt = at
            idleSince = nil
            return
        }

        // ── Case 4: switched to a new bundle ──

        // If there was already a staged close (for a different bundle), commit it
        // now immediately — we moved to a third app.
        if let s = staged {
            flickerTask?.cancel()
            flickerTask = nil
            staged = nil
            await emitClose(session: s, at: at)
        }

        // Stage the current session for a delayed close.
        // Update lastActiveAt to the focus-change timestamp: the user was
        // active in this app right up until they switched away.
        var departing = session
        departing.lastActiveAt = at
        staged = departing
        current = OpenSession(
            bundleID: bundleID,
            appName: appName,
            startedAt: at,
            lastWindowTitle: windowTitle,
            lastActiveAt: at
        )
        idleSince = nil

        // Start the flicker-window countdown.
        flickerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.flickerWindowSeconds * 1_000_000_000))
            } catch {
                return  // cancelled — user returned to the staged bundle
            }
            await self.commitStagedClose(session: departing, at: at)
        }
    }

    // MARK: - Flicker window expiry

    private func commitStagedClose(session: OpenSession, at: Date) async {
        // Only proceed if `staged` still holds this exact session (not replaced).
        guard let s = staged, s.bundleID == session.bundleID, s.startedAt == session.startedAt else {
            return
        }
        flickerTask = nil
        staged = nil
        await emitClose(session: s, at: at)
    }

    // MARK: - inputIdle

    private func onIdle(at: Date) {
        guard current != nil else { return }
        if idleSince == nil { idleSince = at }
    }

    // MARK: - inputResumed

    private func onResumed(at: Date) async {
        guard let session = current, idleSince != nil else {
            idleSince = nil
            return
        }

        // Cancel any staged flicker close — idle/resume supersedes it.
        if let s = staged {
            flickerTask?.cancel()
            flickerTask = nil
            staged = nil
            await emitClose(session: s, at: session.lastActiveAt)
        }

        // Close the current session at the time the user last was active
        // (before going idle).
        await emitClose(session: session, at: session.lastActiveAt)
        current = nil
        idleSince = nil

        // Try to seed a new session from the frontmost application.
        #if canImport(AppKit)
        if let info = await frontmostApplication() {
            current = OpenSession(
                bundleID: info.bundleID,
                appName: info.appName,
                startedAt: at,
                lastWindowTitle: nil,
                lastActiveAt: at
            )
        }
        #endif
    }

    // MARK: - Emit

    private func emitClose(session: OpenSession, at endTime: Date) async {
        let duration = session.lastActiveAt.timeIntervalSince(session.startedAt)

        guard duration >= Self.minimumDurationSeconds else { return }

        let tier = cadenceProvider()
        guard tier != .idle else { return }

        await stream.emit(.sessionClosed(
            bundleID: session.bundleID,
            docHint: sanitize(session.lastWindowTitle),
            durationSeconds: Int(duration),
            cadenceTier: tier,
            at: endTime
        ))
    }

    // MARK: - Sanitization

    private func sanitize(_ title: String?) -> String? {
        guard let title else { return nil }
        let lower = title.lowercased()

        let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        if let detector = linkDetector,
           !detector.matches(in: title, options: [], range: NSRange(title.startIndex..., in: title)).isEmpty {
            return nil
        }

        let blocklist = ["password", "incognito", "private"]
        for term in blocklist where lower.contains(term) { return nil }

        return title.count <= 80 ? title : String(title.prefix(80))
    }

    // MARK: - AppKit helper

    #if canImport(AppKit)
    private struct AppInfo { let bundleID: String; let appName: String }

    private func frontmostApplication() async -> AppInfo? {
        let result = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
                AppInfo(bundleID: $0.bundleIdentifier ?? "", appName: $0.localizedName ?? "")
            }
        }
        return result
    }
    #endif
}

// MARK: - OpenSession

private struct OpenSession {
    let bundleID: String
    let appName: String
    let startedAt: Date
    var lastWindowTitle: String?
    var lastActiveAt: Date
}
