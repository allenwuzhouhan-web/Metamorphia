import Foundation

/// Supplies information about the user's current "work session" — a loose
/// grouping of related activity (app usage + topic) detected by the app target.
///
/// Replaces Executer's `SessionDetector.shared.currentSession()`. The agent
/// package sees only this protocol.
public protocol SessionProvider: Sendable {
    /// Returns the currently active session, or `nil` if none is active
    /// (e.g., the user just sat down) or session detection is disabled.
    func currentSession() -> SessionInfo?
}

/// Summary of the user's current work session.
public struct SessionInfo: Sendable {
    /// Human-readable title for the session (e.g., "Writing Q3 report").
    public let title: String
    /// How long this session has been active.
    public let duration: TimeInterval
    /// Apps the user has engaged with during this session, ordered by recency.
    public let apps: [String]

    public init(title: String, duration: TimeInterval, apps: [String]) {
        self.title = title
        self.duration = duration
        self.apps = apps
    }
}

/// A provider that returns no session info. Used in tests and when the user
/// has opted out of session detection.
public struct NullSessionProvider: SessionProvider {
    public init() {}
    public func currentSession() -> SessionInfo? { nil }
}
