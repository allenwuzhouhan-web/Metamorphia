import Foundation

/// Provides platform-specific context (frontmost app, clipboard preview, system state)
/// to the agent loop without the agent loop importing AppKit.
///
/// Replaces direct `NSWorkspace.shared.frontmostApplication` reads and
/// `AppState.lastCapturedAppName` lookups inside Executer.
///
/// The app target supplies a concrete implementation that uses AppKit, AppleScript,
/// and other system APIs; the agent package sees only this protocol.
///
/// All methods are async because implementations may query system services.
public protocol SystemContextProvider: Sendable {
    /// Fetch a snapshot of the current system context.
    func currentContext() async -> SystemContextSnapshot

    /// Name of the frontmost application, if captured. May return `nil` if
    /// accessibility permissions aren't granted or no app is frontmost.
    var lastCapturedAppName: String? { get async }
}

/// A point-in-time snapshot of the user's desktop state.
///
/// Mirrors the public surface of Executer's `SystemContext` struct but lives in
/// the pure-Swift package. All fields are optional so implementations can fill in
/// only what they have cheap access to.
public struct SystemContextSnapshot: Sendable {
    public let frontmostApp: String?
    public let currentTime: String
    public let isDarkMode: Bool?
    public let volumeLevel: Int?
    public let clipboardPreview: String?
    public let frontmostWindowTitle: String?
    public let terminalCWD: String?
    public let finderSelection: String?
    public let batteryLevel: Int?
    public let wifiNetworkName: String?
    public let activeDisplayCount: Int?
    public let focusMode: String?
    /// Phase 4: ambient perception summary populated by the host when a
    /// `PerceptionLoop` is running. When present, the agent sees a condensed
    /// view of the current screen in every turn — without having to call
    /// `screen_perceive` first.
    public let perceptionSummary: PerceptionSummary?
    /// Island state — a short (~40-token) line describing Metamorphia's own
    /// UI state (current tab, active timer, shelf count). Populated by
    /// `IslandStateContextProvider` in the app target. Nil when that decorator
    /// is not in the chain or the app hasn't bootstrapped yet.
    public let islandState: String?

    public init(
        frontmostApp: String? = nil,
        currentTime: String = ISO8601DateFormatter().string(from: Date()),
        isDarkMode: Bool? = nil,
        volumeLevel: Int? = nil,
        clipboardPreview: String? = nil,
        frontmostWindowTitle: String? = nil,
        terminalCWD: String? = nil,
        finderSelection: String? = nil,
        batteryLevel: Int? = nil,
        wifiNetworkName: String? = nil,
        activeDisplayCount: Int? = nil,
        focusMode: String? = nil,
        perceptionSummary: PerceptionSummary? = nil,
        islandState: String? = nil
    ) {
        self.frontmostApp = frontmostApp
        self.currentTime = currentTime
        self.isDarkMode = isDarkMode
        self.volumeLevel = volumeLevel
        self.clipboardPreview = clipboardPreview
        self.frontmostWindowTitle = frontmostWindowTitle
        self.terminalCWD = terminalCWD
        self.finderSelection = finderSelection
        self.batteryLevel = batteryLevel
        self.wifiNetworkName = wifiNetworkName
        self.activeDisplayCount = activeDisplayCount
        self.focusMode = focusMode
        self.perceptionSummary = perceptionSummary
        self.islandState = islandState
    }

    /// Textual addendum suitable for inclusion in an LLM system prompt.
    /// Only fields that are populated appear in the output.
    public var systemPromptAddendum: String {
        var lines: [String] = ["Current system state:"]
        if let app = frontmostApp { lines.append("- Frontmost app: \(app)") }
        lines.append("- Time: \(currentTime)")
        if let dark = isDarkMode { lines.append("- Appearance: \(dark ? "dark" : "light")") }
        if let vol = volumeLevel { lines.append("- Volume: \(vol)%") }
        if let clip = clipboardPreview, !clip.isEmpty {
            lines.append("- Clipboard: \(clip.prefix(120))")
        }
        if let title = frontmostWindowTitle { lines.append("- Window: \(title)") }
        if let cwd = terminalCWD { lines.append("- Terminal cwd: \(cwd)") }
        if let sel = finderSelection { lines.append("- Finder selection: \(sel)") }
        if let battery = batteryLevel { lines.append("- Battery: \(battery)%") }
        if let wifi = wifiNetworkName { lines.append("- Wi-Fi: \(wifi)") }
        if let n = activeDisplayCount { lines.append("- Displays: \(n)") }
        if let mode = focusMode { lines.append("- Focus: \(mode)") }
        if let p = perceptionSummary {
            lines.append(contentsOf: p.promptLines)
        }
        if let island = islandState {
            lines.append("- Metamorphia: \(island)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Condensed view of the current screen, derived from a full `ScreenMap` by
/// the host's perception service (typically backed by Computer's
/// `PerceptionLoop` running at 10 Hz). Deliberately small — around 80 tokens
/// when serialized — so it's cheap to inject into every agent turn.
///
/// Consumers that need richer structure should call the `screen_perceive`
/// tool; this summary is only for ambient awareness.
public struct PerceptionSummary: Sendable {
    /// When the source `ScreenMap` was captured.
    public let capturedAt: Date
    /// Bundle ID or name of the frontmost app at capture time.
    public let focusedApp: String?
    /// Title of the focused window.
    public let focusedWindowTitle: String?
    /// Short role+label strings for the most salient visible elements
    /// (e.g. `"button:Send"`, `"field:Email"`). Capped at ~5 entries.
    public let topElements: [String]
    /// True when any visible element reports `.loading` state — the agent
    /// should typically wait before taking action.
    public let loadingIndicatorPresent: Bool
    /// True when the focused element is a password / credit-card / SSN /
    /// API-key field. Agents should decline to echo the user's text back.
    public let focusedFieldIsSensitive: Bool
    /// Sensitivity kind (`"password"`, `"creditCard"`, `"ssn"`, `"apiKey"`)
    /// when `focusedFieldIsSensitive` is true; nil otherwise.
    public let sensitiveKind: String?

    public init(
        capturedAt: Date,
        focusedApp: String?,
        focusedWindowTitle: String?,
        topElements: [String],
        loadingIndicatorPresent: Bool,
        focusedFieldIsSensitive: Bool,
        sensitiveKind: String?
    ) {
        self.capturedAt = capturedAt
        self.focusedApp = focusedApp
        self.focusedWindowTitle = focusedWindowTitle
        self.topElements = topElements
        self.loadingIndicatorPresent = loadingIndicatorPresent
        self.focusedFieldIsSensitive = focusedFieldIsSensitive
        self.sensitiveKind = sensitiveKind
    }

    /// Rendered lines for inclusion in `SystemContextSnapshot.systemPromptAddendum`.
    public var promptLines: [String] {
        var lines: [String] = []
        lines.append("- Screen (ambient):")
        if let app = focusedApp {
            lines.append("  · Focused app: \(app)")
        }
        if let title = focusedWindowTitle, !title.isEmpty {
            lines.append("  · Window: \(title)")
        }
        if !topElements.isEmpty {
            lines.append("  · Visible: \(topElements.joined(separator: ", "))")
        }
        if loadingIndicatorPresent {
            lines.append("  · A loading indicator is visible; prefer waiting before acting.")
        }
        if focusedFieldIsSensitive, let kind = sensitiveKind {
            lines.append("  · Focused input is sensitive (\(kind)); never echo or type values here without explicit user permission.")
        }
        return lines
    }
}

/// A null-object provider for tests and contexts where no real system data is needed.
public struct NullSystemContextProvider: SystemContextProvider {
    public init() {}

    public func currentContext() async -> SystemContextSnapshot {
        SystemContextSnapshot()
    }

    public var lastCapturedAppName: String? {
        get async { nil }
    }
}
