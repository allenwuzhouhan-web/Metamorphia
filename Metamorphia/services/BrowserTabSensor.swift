/*
 * Metamorphia
 * Browser-tab sensor — emits ActivityEvent.urlVisited into the activity spine.
 *
 * Polls the frontmost supported browser at 2 Hz via AppleScript to read the
 * active-tab URL and title. Only runs while a supported browser is frontmost;
 * pauses entirely when any other app is active (battery-friendly).
 *
 * Privacy invariants:
 *  - Full URL is never stored or emitted. Only SHA-256(url)[0..<8 bytes] as hex
 *    and the lowercased public host are recorded.
 *  - Private/incognito windows are detected per-browser and skipped. On any
 *    script error the sensor defaults to skipping (fail-closed).
 *  - Domain allowlist gate: BrowserDomainAllowlist.allows(host:) must return
 *    true before emission. nil allowlist ≡ allow-all.
 *
 * Feature gate: Defaults[.observeBrowserTabs] must be true; start() is a
 * no-op when false. Default is false — the user must explicitly opt in from
 * Settings.
 *
 * AppleEvent authorization: the first script per browser triggers the macOS
 * Automation permission prompt. Denial is logged once per bundle ID and all
 * future attempts for that browser are skipped until the next app launch.
 */

import AppKit
import CryptoKit
import Defaults
import Foundation
import MetamorphiaAgentKit

// MARK: - Defaults key

extension Defaults.Keys {
    /// Master switch for browser-tab observation. Off by default; user opts in
    /// from Privacy settings. When false, BrowserTabSensor.start() is a no-op.
    static let observeBrowserTabs = Key<Bool>(
        "metamorphia.browserTabSensor.enabled",
        default: false
    )

    /// When false, tab titles are suppressed from emitted events (URL hash and
    /// host are still recorded). Default true — titles are included when the
    /// master observeBrowserTabs switch is on.
    static let observeBrowserTabTitles = Key<Bool>(
        "metamorphia.browserTabSensor.includeTitles",
        default: true
    )
}

// MARK: - BrowserDomainAllowlist protocol

/// Minimum interface BrowserTabSensor needs from the domain allowlist.
/// The concrete BrowserDomainAllowlist (owned by Coder B) conforms via the
/// extension below. Tests can inject a lightweight mock instead.
@MainActor
public protocol BrowserDomainAllowlistProtocol: AnyObject {
    func allows(host: String) -> Bool
}

// Wire the concrete class (landed by Coder B) to the protocol.
extension BrowserDomainAllowlist: BrowserDomainAllowlistProtocol {}

// MARK: - BrowserTabSensor

@MainActor
public final class BrowserTabSensor {

    // MARK: - Supported browsers

    private enum SupportedBrowser: String, CaseIterable {
        case safari            = "com.apple.Safari"
        case safariPreview     = "com.apple.SafariTechnologyPreview"
        case chrome            = "com.google.Chrome"
        case chromeCanary      = "com.google.Chrome.canary"
        case arc               = "company.thebrowser.Browser"
        case edge              = "com.microsoft.edgemac"
        case brave             = "com.brave.Browser"

        /// Chromium-derived browsers share the same AppleScript surface name.
        private static let chromiumBundleIDs: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "com.brave.Browser"
        ]

        var isChromiumDerived: Bool {
            Self.chromiumBundleIDs.contains(rawValue)
        }

        /// AppleScript application name used in `tell application "…"` blocks.
        var scriptAppName: String {
            switch self {
            case .safari:        return "Safari"
            case .safariPreview: return "Safari Technology Preview"
            case .chrome:        return "Google Chrome"
            case .chromeCanary:  return "Google Chrome Canary"
            case .arc:           return "Arc"
            case .edge:          return "Microsoft Edge"
            case .brave:         return "Brave Browser"
            }
        }

        static func from(bundleID: String) -> SupportedBrowser? {
            allCases.first { $0.rawValue == bundleID }
        }
    }

    // MARK: - State

    private let stream: ActivityStream
    private let allowlist: any BrowserDomainAllowlistProtocol

    /// Timer for the 2 Hz poll loop. Nil when no supported browser is frontmost.
    private var pollTimer: Timer?

    /// Current frontmost supported browser, set by the workspace notification handler.
    private var activeBrowser: SupportedBrowser?

    /// Last-emitted (urlHash, browserBundleID) pair, keyed by bundle ID.
    /// Prevents duplicate events when the tab hasn't navigated between polls.
    private var lastEmitted: [String: String] = [:]   // bundleID → urlHash

    /// Bundle IDs for which we have already logged an authorization failure.
    /// Entries are never removed within a process lifetime (intentional).
    private var deniedBrowsers: Set<String> = []

    private var workspaceObserver: NSObjectProtocol?

    // MARK: - Init

    public init(stream: ActivityStream, allowlist: any BrowserDomainAllowlistProtocol) {
        self.stream = stream
        self.allowlist = allowlist
    }

    deinit {
        // Tear down the repeating poll timer with the owner regardless of pause
        // state. The main RunLoop strongly retains a scheduled repeating Timer
        // independently of this object, so without this it would keep firing
        // after release. Safe to touch from a nonisolated deinit: this is the
        // last reference and invalidate() is the only access.
        pollTimer?.invalidate()
    }

    // MARK: - Lifecycle

    public func start() {
        guard Defaults[.observeBrowserTabs] else { return }
        // Idempotency: a second start() without an intervening stop() must not
        // orphan the existing observer token (which could never be removed).
        guard workspaceObserver == nil else { return }

        // Subscribe to frontmost-app changes so we can wake/pause the poll loop.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleFrontmostAppChange(notification: notification)
            }
        }

        // Evaluate the currently-frontmost app immediately so the sensor doesn't
        // wait for the next focus-switch if a browser is already active.
        evaluateFrontmostApp()
    }

    public func stop() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        pausePolling()
    }

    // MARK: - Frontmost-app handling

    private func handleFrontmostAppChange(notification: Notification) {
        evaluateFrontmostApp()
    }

    private func evaluateFrontmostApp() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if let browser = SupportedBrowser.from(bundleID: bundleID) {
            activeBrowser = browser
            resumePolling()
        } else {
            activeBrowser = nil
            pausePolling()
        }
    }

    // MARK: - Poll loop

    private func resumePolling() {
        guard pollTimer == nil else { return }
        // 2 Hz = 0.5 s interval
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.poll()
            }
        }
    }

    private func pausePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Single poll

    private func poll() async {
        guard Defaults[.observeBrowserTabs] else {
            pausePolling()
            return
        }
        guard let browser = activeBrowser else { return }
        guard !deniedBrowsers.contains(browser.rawValue) else { return }

        guard let result = await fetchTab(browser: browser) else { return }

        // Private-window check — fail-closed: skip if private.
        guard !result.isPrivate else { return }

        // URL plausibility guard.
        guard let url = URL(string: result.urlString),
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased(),
              !host.isEmpty else { return }

        // Domain allowlist gate.
        guard allowlist.allows(host: host) else { return }

        let urlHash = hash(url: url)

        // Duplicate suppression: same browser + same URL hash → skip.
        if lastEmitted[browser.rawValue] == urlHash { return }
        lastEmitted[browser.rawValue] = urlHash

        let title: String? = Defaults[.observeBrowserTabTitles]
            ? result.title.flatMap { $0.isEmpty ? nil : $0 }.map { String($0.prefix(120)) }
            : nil

        let event = ActivityEvent.urlVisited(
            urlHash: urlHash,
            host: host,
            title: title,
            browserBundleID: browser.rawValue,
            at: Date()
        )

        await stream.emit(event)
    }

    // MARK: - AppleScript fetch

    private struct TabResult {
        let urlString: String
        let title: String?
        let isPrivate: Bool
    }

    /// Runs the browser-specific AppleScript and returns a TabResult, or nil on
    /// any error. Logs authorization failures once and adds the browser to the
    /// denied set.
    private func fetchTab(browser: SupportedBrowser) async -> TabResult? {
        let script: String

        switch browser {
        case .safari, .safariPreview:
            script = safariScript(appName: browser.scriptAppName)

        case .chrome, .chromeCanary, .edge, .brave:
            script = chromiumScript(appName: browser.scriptAppName)

        case .arc:
            script = arcScript()
        }

        do {
            guard let descriptor = try await AppleScriptHelper.execute(script),
                  let raw = descriptor.stringValue, !raw.isEmpty else {
                return nil
            }
            return parseLines(raw)
        } catch {
            let err = error as NSError
            // OSStatus codes that indicate a permanent automation-permission denial:
            //   -1743  errAEEventNotPermitted
            //   -1744  errAEEventWouldRequireUserConsent
            //   -1752  errOSAScriptError (permission context)
            // Substring matching on localizedDescription is intentionally omitted —
            // it is too broad and can permanently silence browsers on unrelated errors.
            let isAuthError = err.code == -1743 || err.code == -1744 || err.code == -1752

            if isAuthError && !deniedBrowsers.contains(browser.rawValue) {
                deniedBrowsers.insert(browser.rawValue)
                print("[BrowserTabSensor] Automation permission denied for \(browser.rawValue) — skipping until next launch.")
            }
            // All errors → skip (fail-closed, no log spam after the first denial).
            return nil
        }
    }

    // MARK: - AppleScript sources

    /// Returns a 3-line linefeed-delimited string: URL, title, isPrivate ("true"/"false").
    /// Empty string signals "no window open" — parseLines will return nil on the empty input.
    private func safariScript(appName: String) -> String {
        """
        tell application "\(appName)"
            if not (exists front window) then return ""
            set theURL to URL of current tab of front window
            set theTitle to name of current tab of front window
            set isPriv to false
            try
                if name of front window contains "Private Browsing" then set isPriv to true
            end try
            return theURL & linefeed & theTitle & linefeed & (isPriv as string)
        end tell
        """
    }

    private func chromiumScript(appName: String) -> String {
        // Chrome and Brave report incognito mode as "incognito";
        // Edge reports InPrivate mode as "private".
        let privateModeValue = (appName == "Microsoft Edge") ? "private" : "incognito"
        return """
        tell application "\(appName)"
            if not (exists front window) then return ""
            set theURL to URL of active tab of front window
            set theTitle to title of active tab of front window
            set isPriv to false
            try
                if mode of front window is "\(privateModeValue)" then set isPriv to true
            end try
            return theURL & linefeed & theTitle & linefeed & (isPriv as string)
        end tell
        """
    }

    private func arcScript() -> String {
        """
        tell application "Arc"
            if not (exists front window) then return ""
            set theURL to URL of active tab of front window
            set theTitle to title of active tab of front window
            set isPriv to false
            try
                if name of front window contains "Private" then set isPriv to true
            end try
            return theURL & linefeed & theTitle & linefeed & (isPriv as string)
        end tell
        """
    }

    // MARK: - Line-string parsing

    /// Parses the 3-line string returned by all browser scripts.
    /// Line 0 = URL, line 1 = title, line 2 = isPrivate ("true" / "false").
    /// Returns nil when fewer than 3 lines are present (fail-closed — no window / bad script result).
    /// isPrivate defaults to true for any value that is not exactly "false" (case-insensitive),
    /// so private-window browsing can never silently leak into the observation stream.
    private func parseLines(_ raw: String) -> TabResult? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.count >= 3 else { return nil }

        let urlString = lines[0].trimmingCharacters(in: .whitespaces)
        let title     = lines[1].trimmingCharacters(in: .whitespaces)
        let privRaw   = lines[2].trimmingCharacters(in: .whitespaces)

        guard !urlString.isEmpty else { return nil }

        // Fail-closed: only "false" (case-insensitive) is treated as non-private.
        let isPrivate = privRaw.lowercased() != "false"

        return TabResult(
            urlString: urlString,
            title: title.isEmpty ? nil : title,
            isPrivate: isPrivate
        )
    }

    #if DEBUG
    /// In-file compile-time-verified parser assertions. Call once in DEBUG
    /// app startup (e.g., AppDelegate) to surface regressions early.
    static func debugParseLines(_ sensor: BrowserTabSensor) {
        // Normal public tab.
        let r1 = sensor.parseLines("https://example.com\nExample\nfalse")
        assert(r1?.urlString == "https://example.com", "parseLines: urlString mismatch")
        assert(r1?.title == "Example",                 "parseLines: title mismatch")
        assert(r1?.isPrivate == false,                 "parseLines: isPrivate should be false")

        // Explicit "true" → private.
        let r2 = sensor.parseLines("https://example.com\nExample\ntrue")
        assert(r2?.isPrivate == true, "parseLines: 'true' should be treated as private")

        // Empty isPrivate field → private (fail-closed).
        let r3 = sensor.parseLines("https://example.com\nExample\n")
        assert(r3?.isPrivate == true, "parseLines: empty isPrivate should be treated as private")

        // Fewer than 3 lines → nil.
        let r4 = sensor.parseLines("https://example.com\nExample")
        assert(r4 == nil, "parseLines: fewer than 3 lines should return nil")

        // Empty URL → nil.
        let r5 = sensor.parseLines("\nExample\nfalse")
        assert(r5 == nil, "parseLines: empty URL should return nil")

        // Empty raw string → nil (no window open path).
        let r6 = sensor.parseLines("")
        assert(r6 == nil, "parseLines: empty raw string should return nil")

        print("[BrowserTabSensor] debugParseLines: all assertions passed")
    }
    #endif

    // MARK: - URL hashing

    func hash(url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
