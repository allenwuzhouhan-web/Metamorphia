import Foundation
import AppKit

/// Tracks the active window, app, and monitor. Detects switches between snapshots.
public class FocusTracker: @unchecked Sendable {
    public static let shared = FocusTracker()

    private let lock = NSLock()
    private var _lastFocusedApp: FocusState?
    private var _history: [FocusEvent] = []
    private let maxHistory = 50

    public init() {}

    // MARK: - State

    /// Current focus state.
    public struct FocusState: Sendable {
        public let appName: String
        public let bundleID: String?
        public let pid: pid_t
        public let windowTitle: String?
        public let timestamp: Date

        public init(appName: String, bundleID: String?, pid: pid_t, windowTitle: String?, timestamp: Date) {
            self.appName = appName
            self.bundleID = bundleID
            self.pid = pid
            self.windowTitle = windowTitle
            self.timestamp = timestamp
        }
    }

    /// A recorded focus change event.
    public struct FocusEvent: Sendable {
        public let from: FocusState?
        public let to: FocusState
        public let timestamp: Date

        public init(from: FocusState?, to: FocusState, timestamp: Date) {
            self.from = from
            self.to = to
            self.timestamp = timestamp
        }
    }

    // MARK: - Tracking

    /// Get the current focus state by querying the system.
    public func currentFocus() -> FocusState {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return FocusState(appName: "Unknown", bundleID: nil, pid: 0, windowTitle: nil, timestamp: Date())
        }

        // Get window title via AX
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        let windowTitle = AXAttributes.getFocusedWindow(appElement).flatMap { AXAttributes.getTitle($0) }

        return FocusState(
            appName: frontApp.localizedName ?? "Unknown",
            bundleID: frontApp.bundleIdentifier,
            pid: frontApp.processIdentifier,
            windowTitle: windowTitle,
            timestamp: Date()
        )
    }

    /// Update tracking with current state. Returns a FocusEvent if the focus changed.
    @discardableResult
    public func update() -> FocusEvent? {
        let current = currentFocus()

        lock.lock()
        defer { lock.unlock() }

        // Check if anything changed
        if let last = _lastFocusedApp {
            let appChanged = last.pid != current.pid
            let windowChanged = last.windowTitle != current.windowTitle

            if appChanged || windowChanged {
                let event = FocusEvent(from: last, to: current, timestamp: Date())
                _history.append(event)
                if _history.count > maxHistory {
                    _history.removeFirst(_history.count - maxHistory)
                }
                _lastFocusedApp = current
                return event
            }
        } else {
            // First update — just record, no event
            _lastFocusedApp = current
        }

        return nil
    }

    /// Last known focus state (without querying the system).
    public var lastFocusedApp: FocusState? {
        lock.lock()
        defer { lock.unlock() }
        return _lastFocusedApp
    }

    /// Recent focus change history.
    public var history: [FocusEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _history
    }

    /// Was there an app switch since the last update?
    public func didAppSwitch(since previousPID: pid_t) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        return frontApp.processIdentifier != previousPID
    }

    /// Get the frontmost app's bundle ID (fast, no AX query).
    public var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Get all visible app names and PIDs.
    public func visibleApps() -> [(name: String, bundleID: String?, pid: pid_t)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden }
            .map { (name: $0.localizedName ?? "Unknown", bundleID: $0.bundleIdentifier, pid: $0.processIdentifier) }
    }
}
