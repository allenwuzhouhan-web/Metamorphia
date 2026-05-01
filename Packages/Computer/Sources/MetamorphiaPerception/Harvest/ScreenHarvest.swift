import Foundation
import AppKit
import ApplicationServices
import CryptoKit

// MARK: - ScreenFrame

/// A single textual snapshot of the focused window. Emitted by ``ScreenHarvest``
/// to its ``ScreenHarvestSink`` each time the canonical body changes. The
/// frame carries structured context (bundle, window title, document path, URL,
/// selection) plus the full rendered body — tiny compared to a screenshot.
public struct ScreenFrame: Sendable {
    public let capturedAt: Date
    public let appBundleID: String?
    public let appName: String
    public let pid: pid_t
    public let windowTitle: String?
    public let docPath: String?
    public let url: String?
    public let roleChainSummary: String
    public let body: String
    public let selection: String?
    public let bodyHash: UInt64
    public let byteCount: Int

    public init(
        capturedAt: Date,
        appBundleID: String?,
        appName: String,
        pid: pid_t,
        windowTitle: String?,
        docPath: String?,
        url: String?,
        roleChainSummary: String,
        body: String,
        selection: String?,
        bodyHash: UInt64,
        byteCount: Int
    ) {
        self.capturedAt = capturedAt
        self.appBundleID = appBundleID
        self.appName = appName
        self.pid = pid
        self.windowTitle = windowTitle
        self.docPath = docPath
        self.url = url
        self.roleChainSummary = roleChainSummary
        self.body = body
        self.selection = selection
        self.bodyHash = bodyHash
        self.byteCount = byteCount
    }
}

// MARK: - Sink

/// Downstream receiver of ``ScreenFrame`` values. The app target wires this to
/// a pipeline that: (a) runs entity extraction on the body, (b) inserts into
/// `RetraceIndex` as `ItemKind.screen`, (c) potentiates the interest graph,
/// (d) emits a `screenFrameIngested` `ActivityEvent`.
public protocol ScreenHarvestSink: AnyObject, Sendable {
    func receive(_ frame: ScreenFrame) async
}

// MARK: - Denylist

/// Bundle IDs and role/identifier fragments that MUST NOT be harvested.
/// Expanded at runtime by the host app via ``ScreenHarvest/addDenylistBundleID(_:)``.
public enum ScreenHarvestDenylist {
    public static let builtInBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.1password.1password8",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "com.apple.keychainaccess",
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
        "com.apple.preference.security",
    ]

    /// Window titles containing any of these fragments (case-insensitive) are dropped.
    public static let titleFragments: [String] = [
        "private browsing",
        "incognito",
        "1password",
        "password",
        "keychain",
    ]

    /// Element identifiers matching any of these regex patterns have their
    /// text value zeroed out before inclusion in the body.
    public static let sensitiveIdentifierPatterns: [NSRegularExpression] = {
        let patterns = [
            #"(?i)password"#,
            #"(?i)passcode"#,
            #"(?i)\bssn\b"#,
            #"(?i)credit.?card"#,
            #"(?i)\bcvv\b"#,
            #"(?i)\botp\b"#,
            #"(?i)api[_-]?key"#,
            #"(?i)bearer"#,
            #"(?i)secret"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Role-based block: these AX roles must not contribute text at all.
    public static let blockedRoles: Set<String> = [
        "AXSecureTextField",
        "AXMenuBar",
        "AXMenuItem",
        "AXMenu",
    ]
}

// MARK: - ScreenHarvest

/// Continuous, event-driven accessibility-tree reader. Attaches one
/// `AXObserver` per focused PID, listening to five notifications. Captures are
/// debounced, content-hash deduplicated, and never involve a screenshot.
///
/// Activation policy:
/// - Workspace notifications drive PID binding. When the user switches apps,
///   we detach from the previous PID and bind to the new one.
/// - A 10 s heartbeat re-reads the frontmost app as a safety net for apps
///   (Electron, some web views) that drop AX notifications.
/// - Runaway detection: if one bundle emits >100 events/sec, that bundle is
///   downgraded to heartbeat-only for 60 s.
///
/// The harvest is started by the host app after both accessibility permission
/// and the user's Retrace opt-in have been verified.
public final class ScreenHarvest: @unchecked Sendable {

    public static let shared = ScreenHarvest()

    // Mutable state is serialized through `lock`. NSRecursiveLock is used
    // because a capture callback can legally re-enter (e.g. runaway guard
    // triggering a state update after the caller already holds the lock).
    // The async-context warnings from NSLock are harmless here — the lock
    // spans fast read/write sections only, not actual awaits.
    private let lock = NSRecursiveLock()
    private weak var sink: ScreenHarvestSink?
    private var isRunning = false
    private var workspaceSwitchObserver: NSObjectProtocol?
    private var workspaceTerminateObserver: NSObjectProtocol?
    private var perPIDObservers: [pid_t: AXObserver] = [:]
    private var perPIDFrameDigest: [pid_t: FrameDigest] = [:]
    private var perPIDDebounceTask: [pid_t: Task<Void, Never>] = [:]
    private var perPIDEventCounts: [pid_t: RateTracker] = [:]
    private var perPIDQuarantineUntil: [pid_t: Date] = [:]
    private var extraDenylistBundleIDs: Set<String> = []
    private var heartbeatTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 1.5
    private let heartbeatInterval: TimeInterval = 10.0

    public init() {}

    // MARK: - Public API

    public func attach(sink: ScreenHarvestSink) {
        lock.lock(); defer { lock.unlock() }
        self.sink = sink
    }

    public func addDenylistBundleID(_ bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        extraDenylistBundleIDs.insert(bundleID)
    }

    /// Start harvesting. Requires accessibility permission — caller is
    /// responsible for verifying and prompting.
    public func start() {
        lock.lock()
        if isRunning { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        let center = NSWorkspace.shared.notificationCenter

        let switchObs = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self.onFocusChange(to: app)
            }
        }
        let termObs = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self.onAppTerminate(pid: app.processIdentifier)
            }
        }

        lock.lock()
        workspaceSwitchObserver = switchObs
        workspaceTerminateObserver = termObs
        lock.unlock()

        // Bind the currently-focused app immediately.
        if let front = NSWorkspace.shared.frontmostApplication {
            onFocusChange(to: front)
        }

        // Heartbeat: re-read the frontmost app periodically. Absorbs any
        // apps that drop AX notifications.
        startHeartbeat()
    }

    public func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        let switchObs = workspaceSwitchObserver
        let termObs = workspaceTerminateObserver
        workspaceSwitchObserver = nil
        workspaceTerminateObserver = nil
        let observers = perPIDObservers
        perPIDObservers.removeAll()
        for (_, task) in perPIDDebounceTask { task.cancel() }
        perPIDDebounceTask.removeAll()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lock.unlock()

        if let switchObs { NSWorkspace.shared.notificationCenter.removeObserver(switchObs) }
        if let termObs { NSWorkspace.shared.notificationCenter.removeObserver(termObs) }
        for (_, observer) in observers {
            detachObserver(observer)
        }
    }

    // MARK: - Focus routing

    private func onFocusChange(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier

        // Denylist: bundle-level.
        if let bid = bundleID {
            lock.lock()
            let denied = ScreenHarvestDenylist.builtInBundleIDs.contains(bid) || extraDenylistBundleIDs.contains(bid)
            lock.unlock()
            if denied {
                // Skip binding entirely — also detach any previous observer
                // for this PID to avoid stale harvests.
                detach(pid: pid)
                return
            }
        }

        bindObserver(pid: pid)

        // Immediately capture once on focus change — AX notifications
        // sometimes arrive late; this keeps latency bounded.
        scheduleCapture(pid: pid, bundleID: bundleID, appName: app.localizedName ?? "Unknown", immediate: true)
    }

    private func onAppTerminate(pid: pid_t) {
        detach(pid: pid)
    }

    private func detach(pid: pid_t) {
        lock.lock()
        let observer = perPIDObservers.removeValue(forKey: pid)
        perPIDFrameDigest.removeValue(forKey: pid)
        perPIDDebounceTask.removeValue(forKey: pid)?.cancel()
        perPIDEventCounts.removeValue(forKey: pid)
        perPIDQuarantineUntil.removeValue(forKey: pid)
        lock.unlock()
        if let observer { detachObserver(observer) }
    }

    // MARK: - AXObserver binding

    private func bindObserver(pid: pid_t) {
        lock.lock()
        if perPIDObservers[pid] != nil { lock.unlock(); return }
        lock.unlock()

        var observer: AXObserver?
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let harvest = Unmanaged<ScreenHarvest>.fromOpaque(refcon).takeUnretainedValue()
            let note = notification as String
            harvest.handleAXNotification(note, element: element)
        }

        let rc = AXObserverCreate(pid, callback, &observer)
        guard rc == .success, let observer else {
            return
        }

        let app = AXUIElementCreateApplication(pid)
        let notifications: [String] = [
            kAXFocusedWindowChangedNotification as String,
            kAXMainWindowChangedNotification as String,
            kAXTitleChangedNotification as String,
            kAXSelectedTextChangedNotification as String,
            kAXValueChangedNotification as String,
        ]
        for n in notifications {
            _ = AXObserverAddNotification(observer, app, n as CFString, selfPtr)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        lock.lock()
        perPIDObservers[pid] = observer
        perPIDEventCounts[pid] = RateTracker()
        lock.unlock()
    }

    private func detachObserver(_ observer: AXObserver) {
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    // MARK: - AX callback handling

    private func handleAXNotification(_ notification: String, element: AXUIElement) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier

        // Runaway guard: throttle bundles that spam notifications.
        lock.lock()
        let now = Date()
        if let quarantineUntil = perPIDQuarantineUntil[pid], now < quarantineUntil {
            lock.unlock()
            return
        }
        var tracker = perPIDEventCounts[pid] ?? RateTracker()
        tracker.record(at: now)
        perPIDEventCounts[pid] = tracker
        if tracker.eventsInLastSecond >= 100 {
            perPIDQuarantineUntil[pid] = now.addingTimeInterval(60)
            lock.unlock()
            return
        }
        lock.unlock()

        scheduleCapture(pid: pid, bundleID: front.bundleIdentifier, appName: front.localizedName ?? "Unknown", immediate: false)
    }

    // MARK: - Capture scheduling (debounce)

    private func scheduleCapture(pid: pid_t, bundleID: String?, appName: String, immediate: Bool) {
        lock.lock()
        perPIDDebounceTask[pid]?.cancel()
        let interval = immediate ? 0.05 : debounceInterval
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.capture(pid: pid, bundleID: bundleID, appName: appName)
        }
        perPIDDebounceTask[pid] = task
        lock.unlock()
    }

    private func capture(pid: pid_t, bundleID: String?, appName: String) async {
        // Re-check runtime state under lock.
        lock.lock()
        let running = isRunning
        let denied = (bundleID.map { ScreenHarvestDenylist.builtInBundleIDs.contains($0) || extraDenylistBundleIDs.contains($0) }) ?? false
        lock.unlock()
        guard running, !denied else { return }

        guard let result = AXReader.readApp(pid: pid, name: appName, bundleID: bundleID) else { return }

        // Title-fragment denylist — e.g. "Private Browsing", "Incognito".
        let title = result.windowTitle.isEmpty ? nil : result.windowTitle
        if let title {
            let lower = title.lowercased()
            for fragment in ScreenHarvestDenylist.titleFragments where lower.contains(fragment) {
                return
            }
        }

        // Build canonical body from elements. Sort by depth+y+x for stability.
        let sorted = result.elements.sorted { a, b in
            if a.depth != b.depth { return a.depth < b.depth }
            let ay = a.position?.y ?? 0, by = b.position?.y ?? 0
            if ay != by { return ay < by }
            return (a.position?.x ?? 0) < (b.position?.x ?? 0)
        }

        var parts: [String] = []
        var selection: String?
        parts.reserveCapacity(sorted.count)
        for el in sorted {
            if ScreenHarvestDenylist.blockedRoles.contains(el.role) { continue }
            if el.subrole == "AXSecureTextField" { continue }

            // Identifier-based redaction — if this element's identifier
            // suggests a password/credit-card/etc field, skip its text.
            if !el.identifier.isEmpty {
                let idRange = NSRange(location: 0, length: el.identifier.utf16.count)
                var blocked = false
                for regex in ScreenHarvestDenylist.sensitiveIdentifierPatterns {
                    if regex.firstMatch(in: el.identifier, options: [], range: idRange) != nil {
                        blocked = true; break
                    }
                }
                if blocked { continue }
            }

            let candidates = [el.value, el.title, el.label, el.description]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if candidates.isEmpty { continue }

            let chosen = candidates.first!
            parts.append(chosen)

            // First focused text field's value is considered the active selection.
            if selection == nil,
               (el.role == "AXTextField" || el.role == "AXTextArea"),
               el.state.contains(.focused),
               !el.value.isEmpty {
                selection = el.value
            }
        }

        let body = parts.joined(separator: "\n")
        guard body.count >= 4 else { return }  // filter empty/dead frames

        // Canonical form for hashing: lowercased, whitespace-compressed.
        let canonical = body
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let hashBytes = SHA256.hash(data: Data(canonical.utf8))
        let hash = hashBytes.withUnsafeBytes { raw -> UInt64 in
            var h: UInt64 = 0
            for i in 0..<8 {
                h |= UInt64(raw[i]) << UInt64(i * 8)
            }
            return h
        }

        lock.lock()
        if let digest = perPIDFrameDigest[pid], digest.hash == hash {
            lock.unlock()
            return
        }
        perPIDFrameDigest[pid] = FrameDigest(hash: hash, at: Date())
        lock.unlock()

        // Build role-chain summary (top 3 roles by frequency).
        let chain = sorted.prefix(3).map { $0.role }.joined(separator: ">")

        let frame = ScreenFrame(
            capturedAt: Date(),
            appBundleID: bundleID,
            appName: appName,
            pid: pid,
            windowTitle: title,
            docPath: nil,          // Populated by host if AXDocument read is desired.
            url: extractURL(from: result),
            roleChainSummary: chain,
            body: body,
            selection: selection,
            bodyHash: hash,
            byteCount: body.utf8.count
        )

        if let sink = self.currentSink() {
            await sink.receive(frame)
        }
    }

    private func currentSink() -> ScreenHarvestSink? {
        lock.lock(); defer { lock.unlock() }
        return sink
    }

    private func extractURL(from result: AXReader.AXReadResult) -> String? {
        // Safari/Chrome/Arc expose the active tab URL on the window element
        // via `AXURLAttribute`. We don't currently have the raw window
        // element here; return nil. The host app's browser archive path
        // covers URL capture.
        _ = result
        return nil
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let task = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.heartbeatInterval ?? 10.0) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if let front = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) {
                    self.scheduleCapture(
                        pid: front.processIdentifier,
                        bundleID: front.bundleIdentifier,
                        appName: front.localizedName ?? "Unknown",
                        immediate: true
                    )
                }
            }
        }
        lock.lock()
        heartbeatTask = task
        lock.unlock()
    }
}

// MARK: - FrameDigest / RateTracker

private struct FrameDigest {
    let hash: UInt64
    let at: Date
}

private struct RateTracker {
    private var recent: [Date] = []
    mutating func record(at date: Date) {
        recent.append(date)
        // Drop anything older than 1s.
        let cutoff = date.addingTimeInterval(-1)
        while let first = recent.first, first < cutoff {
            recent.removeFirst()
        }
    }
    var eventsInLastSecond: Int { recent.count }
}
