import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - BrowserDOMCapture

/// Full browser DOM snapshot — captured entirely locally, never transmitted to remote APIs.
/// Populated by `BrowserDOMFetcher` when the frontmost app is a supported browser.
/// The full `html` field is preserved so local decision engines (e.g., a Gemma/Qwen
/// Ollama model in Executer) can read every tag, attribute, and text node; the compact
/// LLM-facing formatter at `TextFormatter` emits only url/title/byte-count.
public struct BrowserDOMCapture: Sendable {
    public let url: String
    public let title: String
    public let html: String
    public let fetchedAt: Date
    public let source: Source

    public enum Source: String, Sendable {
        case safariAppleScript = "safari-as"
        case chromeCDP = "chrome-cdp"
    }

    public init(url: String, title: String, html: String, fetchedAt: Date, source: Source) {
        self.url = url
        self.title = title
        self.html = html
        self.fetchedAt = fetchedAt
        self.source = source
    }
}

// MARK: - BrowserDOMFetcher

/// Fetches the full DOM of the frontmost browser, entirely locally.
///
/// Strategies per browser:
///  - **Safari** (`com.apple.Safari`, `com.apple.SafariTechnologyPreview`): AppleScript
///    `do JavaScript "document.documentElement.outerHTML"` via `NSAppleScript`. First call
///    triggers a one-time Automation permission prompt (the containing app's Info.plist
///    must declare `NSAppleEventsUsageDescription`).
///  - **Chrome-family** (`com.google.Chrome`, `com.microsoft.edgemac`, `company.thebrowser.Browser`,
///    `com.brave.Browser`, `org.chromium.Chromium`, `com.vivaldi.Vivaldi`): Chrome DevTools
///    Protocol over localhost:9222. Requires the browser to have been launched with
///    `--remote-debugging-port=9222`. Launching/restarting with that flag is Executer's
///    responsibility (see `ChromeCDPLauncher`) — this fetcher is read-only.
///
/// WebKit-embedded apps (Messages, Mail rich view, Notes web snippets) and Electron/CEF
/// apps (VS Code, Slack, Discord, Notion desktop) are out of scope for phase 1. They return
/// `nil` and the caller falls back to the AX-tree-only perception path.
public actor BrowserDOMFetcher {
    public static let shared = BrowserDOMFetcher()

    /// Safari bundle IDs.
    private static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    /// Chrome-family bundle IDs — all speak the Chrome DevTools Protocol.
    private static let chromeFamilyBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",     // Arc
        "com.brave.Browser",
        "org.chromium.Chromium",
        "com.vivaldi.Vivaldi"
    ]

    /// Fingerprint cache: `(bundleID, url, title)` → last capture. Skips re-fetching HTML
    /// when the browser tab is visually the same. HTML fetch is 20–100 ms per browser,
    /// so this gate matters at 10 Hz.
    private struct Fingerprint: Hashable {
        let bundleID: String
        let url: String
        let title: String
    }
    private var cachedFingerprint: Fingerprint?
    private var cachedCapture: BrowserDOMCapture?

    /// Monotonic per-call CDP request id. Actor isolation makes the increment
    /// race-free, so parallel calls to the four Phase-C dispatch methods can
    /// run without stepping on each other's response matching. Never reset —
    /// overflow at 2^63 is not a real concern.
    private var cdpRequestCounter: Int = 0

    /// Persistent WebSocket pool keyed by target URL. Phase-D PROMAX pass
    /// replaced the per-call ephemeral session model. Rationale (critic H2):
    /// each ephemeral session paid a 20-60 ms WebSocket handshake AND capped
    /// read at 10 frames — on moderately active tabs (Gmail with live chat,
    /// pages with WebSocket listeners) the reply could be evicted by
    /// unrelated events (Runtime.executionContextCreated, Network.*). The
    /// shared-receive-loop design keeps one socket open per tab target and
    /// routes responses by id, so handshake cost amortizes and we never
    /// lose a reply to unrelated interleaved events.
    private var cdpSockets: [URL: CDPSocket] = [:]

    /// Last-use timestamp per pooled socket, used to evict idle/stale entries
    /// and to pick the LRU victim when the pool is at capacity. Kept in lockstep
    /// with `cdpSockets` — every insert/remove updates both.
    private var cdpSocketLastUse: [URL: Date] = [:]

    /// Idle entries older than this are torn down on the next `socketForWS`
    /// call. A tab the user stopped interacting with goes quiet within seconds,
    /// so 30 s comfortably covers an active tab between dispatches while still
    /// reclaiming the socket/URLSession/receive-loop of an abandoned tab.
    private static let cdpSocketIdleTimeout: TimeInterval = 30

    /// Hard cap on live pooled sockets. The user only has one frontmost tab at
    /// a time; a few slots absorb rapid tab toggling without letting one socket
    /// per visited tab accumulate over a browsing session.
    private static let cdpSocketPoolLimit = 6

    // MARK: - Public API

    /// True when `bundleID` is a browser this fetcher knows how to drive.
    /// Exposed as a static probe so `SemanticExecutor` can gate the CDP
    /// execution path without re-implementing the bundle-id lists.
    public static func isBrowserBundle(_ bundleID: String) -> Bool {
        safariBundleIDs.contains(bundleID) || chromeFamilyBundleIDs.contains(bundleID)
    }

    /// Returns a DOM capture if the given app is a supported browser, otherwise `nil`.
    /// Safe to call at 10 Hz: on unchanged (bundle, url, title) the cached capture is returned
    /// without re-reading the DOM.
    public func fetchIfBrowserFrontmost(_ focusedApp: AppInfo) async -> BrowserDOMCapture? {
        guard let bundleID = focusedApp.bundleID else { return nil }

        if Self.safariBundleIDs.contains(bundleID) {
            return await fetchSafari(bundleID: bundleID)
        }
        if Self.chromeFamilyBundleIDs.contains(bundleID) {
            return await fetchChromeCDP(bundleID: bundleID)
        }
        return nil
    }

    /// Drops the cache. Call when focus changes apps or when forcing a refresh.
    /// Also tears down any pooled CDP sockets — a tab switch typically means
    /// the `webSocketDebuggerUrl` we were holding is no longer the frontmost
    /// target, and the next `dispatchClick` needs to re-discover via
    /// `cdpListTargets`.
    public func invalidateCache() {
        cachedFingerprint = nil
        cachedCapture = nil
        let toTeardown = Array(cdpSockets.values)
        cdpSockets.removeAll()
        cdpSocketLastUse.removeAll()
        Task { for s in toTeardown { await s.teardown() } }
    }

    // MARK: - Phase C Dispatch + Enumeration

    /// Click a DOM element by CSS selector. Returns a structured result
    /// rather than throwing because callers (`SemanticExecutor.press`) always
    /// have a CGEvent fallback — on any failure the executor retries via the
    /// cursor path, so the tighter contract here is "try fast, report how it
    /// went, never block the caller's Task".
    ///
    /// Chrome path: `Runtime.evaluate` with `userGesture: true` so the click
    /// bypasses popup-blocker / trust gates (navigation clicks, form submit
    /// triggers, window.open) that would silently no-op on a scripted click.
    ///
    /// Safari path: `do JavaScript` — no `userGesture` equivalent exists, so
    /// some Safari clicks may silently fail on sites with strict CSP. Agents
    /// should detect failure via `result.succeeded == false` and retry via
    /// cursor.
    public func dispatchClick(
        focusedApp: AppInfo,
        selector: String
    ) async -> DispatchResult {
        guard let bundleID = focusedApp.bundleID else {
            return DispatchResult(selector: selector, succeeded: false,
                                  error: .browserNotFrontmost, detail: nil)
        }
        let js = Self.clickJS(selector: selector)
        return await dispatchJS(bundleID: bundleID, selector: selector, js: js,
                                userGesture: true)
    }

    /// Focus a DOM element. Same semantics as `dispatchClick` but runs
    /// `el.focus()` — used as the focus prelude to `dispatchInput` and as a
    /// standalone primitive for tab-stop / caret-placement flows.
    public func dispatchFocus(
        focusedApp: AppInfo,
        selector: String
    ) async -> DispatchResult {
        guard let bundleID = focusedApp.bundleID else {
            return DispatchResult(selector: selector, succeeded: false,
                                  error: .browserNotFrontmost, detail: nil)
        }
        let js = Self.focusJS(selector: selector)
        return await dispatchJS(bundleID: bundleID, selector: selector, js: js,
                                userGesture: false)
    }

    /// Set the value of a DOM input (or textContent of a contenteditable),
    /// fire `input` + `change` events, optionally trigger an Enter keydown
    /// to submit. Skips macOS's Secure Event Input machinery — the OS only
    /// guards CGEvent-based keystrokes, not DOM value assignment — so
    /// callers must still refuse password fields at the SemanticExecutor
    /// level (which today's `type` does via the `.password` state check).
    public func dispatchInput(
        focusedApp: AppInfo,
        selector: String,
        value: String,
        commitWithEnter: Bool
    ) async -> DispatchResult {
        guard let bundleID = focusedApp.bundleID else {
            return DispatchResult(selector: selector, succeeded: false,
                                  error: .browserNotFrontmost, detail: nil)
        }
        let js = Self.inputJS(selector: selector, value: value, commit: commitWithEnter)
        return await dispatchJS(bundleID: bundleID, selector: selector, js: js,
                                userGesture: false)
    }

    /// Enumerate interactive elements in the frontmost tab via in-page JS.
    /// Returns the list with stable selectors (id / data-testid / aria-label
    /// / path fallback) and viewport-relative rects. `BrowserDOMJoiner` uses
    /// this to annotate AX `ScreenElement`s with `domSelector`/`domNodeId`.
    public func fetchInteractiveNodes(
        focusedApp: AppInfo
    ) async -> DOMEnumeration? {
        guard let bundleID = focusedApp.bundleID,
              Self.isBrowserBundle(bundleID) else { return nil }
        let js = Self.interactiveEnumerationJS
        let result: String?
        if Self.safariBundleIDs.contains(bundleID) {
            result = await runSafariJS(js: js)
        } else {
            result = await runChromeJS(js: js, userGesture: false)
        }
        guard let raw = result,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodesRaw = obj["nodes"] as? [[String: Any]] else {
            return nil
        }
        let viewport = obj["viewport"] as? [String: Any]
        let scale = (viewport?["devicePixelRatio"] as? Double) ?? 1.0
        let innerWidth = (viewport?["innerWidth"] as? Double) ?? 0
        let innerHeight = (viewport?["innerHeight"] as? Double) ?? 0

        let nodes: [DOMInteractiveNode] = nodesRaw.compactMap { entry in
            guard let sel = entry["sel"] as? String,
                  let tag = entry["tag"] as? String,
                  let rectDict = entry["rect"] as? [String: Double] else { return nil }
            let rect = CGRect(
                x: rectDict["x"] ?? 0,
                y: rectDict["y"] ?? 0,
                width: rectDict["w"] ?? 0,
                height: rectDict["h"] ?? 0
            )
            return DOMInteractiveNode(
                selector: sel,
                tag: tag,
                id: entry["id"] as? String,
                role: entry["role"] as? String,
                aria: entry["aria"] as? String,
                text: (entry["text"] as? String) ?? "",
                rect: rect,
                nodeId: entry["nodeId"] as? Int,
                isEditable: (entry["isEditable"] as? Bool) ?? false
            )
        }
        return DOMEnumeration(
            nodes: nodes,
            viewportSize: CGSize(width: innerWidth, height: innerHeight),
            scaleFactor: CGFloat(scale)
        )
    }

    // MARK: - Dispatch routing

    private func dispatchJS(
        bundleID: String,
        selector: String,
        js: String,
        userGesture: Bool
    ) async -> DispatchResult {
        let raw: String?
        if Self.safariBundleIDs.contains(bundleID) {
            raw = await runSafariJS(js: js)
        } else if Self.chromeFamilyBundleIDs.contains(bundleID) {
            raw = await runChromeJS(js: js, userGesture: userGesture)
        } else {
            return DispatchResult(selector: selector, succeeded: false,
                                  error: .browserNotFrontmost, detail: nil)
        }
        guard let raw else {
            return DispatchResult(selector: selector, succeeded: false,
                                  error: .cdpUnavailable,
                                  detail: "no response from browser")
        }
        // Dispatch JS returns `{"ok":true}` / `{"ok":false,"reason":"..."}`.
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DispatchResult(selector: selector, succeeded: false,
                                  error: .evalException,
                                  detail: raw.prefix(120).description)
        }
        let ok = (obj["ok"] as? Bool) ?? false
        if ok {
            return DispatchResult(selector: selector, succeeded: true,
                                  error: nil, detail: nil)
        }
        let reason = (obj["reason"] as? String) ?? "unknown"
        let errCase: DispatchError = (reason == "no_match") ? .noMatchingNode : .evalException
        return DispatchResult(selector: selector, succeeded: false,
                              error: errCase, detail: reason)
    }

    private func runChromeJS(js: String, userGesture: Bool) async -> String? {
        guard let targets = await cdpListTargets() else { return nil }
        guard let target = targets.first(where: {
            ($0["type"] as? String) == "page" &&
            !(($0["url"] as? String) ?? "").hasPrefix("chrome-extension://")
        }) else { return nil }
        guard let wsURLString = target["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: wsURLString) else { return nil }
        return await cdpRuntimeEvaluate(
            wsURL: wsURL, expression: js, userGesture: userGesture
        )
    }

    private func runSafariJS(js: String) async -> String? {
        #if canImport(AppKit)
        // `do JavaScript` treats embedded double quotes as script-boundary
        // terminators. Escape them + backslashes before splicing into the
        // AppleScript source.
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Safari"
            try
                return (do JavaScript "\(escaped)" in current tab of front window)
            on error errMsg
                return ""
            end try
        end tell
        """
        return await runAppleScript(source)
        #else
        return nil
        #endif
    }

    private func fetchSafari(bundleID: String) async -> BrowserDOMCapture? {
        #if canImport(AppKit)
        // Quick URL+title probe via AppleScript first — cheaper than full HTML.
        let probe = await runAppleScript("""
            tell application "Safari"
                if (count of windows) is 0 then return ""
                try
                    set theTab to current tab of front window
                    return (URL of theTab) & "|" & (name of theTab)
                on error
                    return ""
                end try
            end tell
            """)
        guard let probe = probe, !probe.isEmpty else { return nil }
        let parts = probe.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        let url = parts[0]
        let title = parts.dropFirst().joined(separator: "|")

        // Cache hit: same tab, return the previous HTML without re-reading.
        let fp = Fingerprint(bundleID: bundleID, url: url, title: title)
        if fp == cachedFingerprint, let cached = cachedCapture {
            return cached
        }

        // Cache miss — fetch the full outerHTML.
        let htmlResult = await runAppleScript("""
            tell application "Safari"
                try
                    return (do JavaScript "document.documentElement.outerHTML" in current tab of front window)
                on error
                    return ""
                end try
            end tell
            """)
        guard let html = htmlResult, !html.isEmpty else {
            // Probe succeeded but HTML read failed — likely Automation permission missing
            // or a privileged page (about:, chrome:, etc.). Return nil; caller falls back to AX.
            return nil
        }

        let capture = BrowserDOMCapture(
            url: url,
            title: title,
            html: html,
            fetchedAt: Date(),
            source: .safariAppleScript
        )
        cachedFingerprint = fp
        cachedCapture = capture
        return capture
        #else
        return nil
        #endif
    }

    // MARK: - Chrome DevTools Protocol

    private func fetchChromeCDP(bundleID: String) async -> BrowserDOMCapture? {
        // 1. Get the list of open tabs via the HTTP discovery endpoint.
        //    If this fails, CDP is not running on port 9222 — the browser was launched
        //    without --remote-debugging-port. We return nil and let the caller fall back.
        guard let targets = await cdpListTargets() else { return nil }

        // Find the active tab for this browser. CDP doesn't expose which tab is frontmost,
        // so we pick the first non-extension 'page' target, which is reliable in practice
        // because Chrome surfaces the current tab first.
        guard let target = targets.first(where: {
            ($0["type"] as? String) == "page" &&
            !(($0["url"] as? String) ?? "").hasPrefix("chrome-extension://")
        }) else { return nil }

        let url = (target["url"] as? String) ?? ""
        let title = (target["title"] as? String) ?? ""

        // Cache hit: same tab, return previous HTML.
        let fp = Fingerprint(bundleID: bundleID, url: url, title: title)
        if fp == cachedFingerprint, let cached = cachedCapture {
            return cached
        }

        guard let wsURLString = target["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: wsURLString) else {
            return nil
        }

        // 2. Open a WebSocket to the tab and send Runtime.evaluate.
        guard let html = await cdpEvaluate(wsURL: wsURL, expression: "document.documentElement.outerHTML") else {
            return nil
        }

        let capture = BrowserDOMCapture(
            url: url,
            title: title,
            html: html,
            fetchedAt: Date(),
            source: .chromeCDP
        )
        cachedFingerprint = fp
        cachedCapture = capture
        return capture
    }

    /// GET http://localhost:9222/json — returns an array of target dictionaries.
    private func cdpListTargets() async -> [[String: Any]]? {
        guard let url = URL(string: "http://localhost:9222/json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            return arr
        } catch {
            return nil
        }
    }

    /// Legacy entrypoint — kept as a thin wrapper so existing `fetchChromeCDP`
    /// callers don't churn. New Phase-C code should call
    /// `cdpRuntimeEvaluate(wsURL:expression:userGesture:)` directly.
    private func cdpEvaluate(wsURL: URL, expression: String) async -> String? {
        await cdpRuntimeEvaluate(wsURL: wsURL, expression: expression, userGesture: false)
    }

    /// Send a `Runtime.evaluate` over the given tab WebSocket and return the
    /// string result. `userGesture: true` marks the evaluation as
    /// user-initiated so `.click()` / `window.open` / navigation calls aren't
    /// sandboxed. Bounded by the URLSession request timeout (2 s) so a hung
    /// tab cannot stall the perception loop. Reads up to 10 messages — CDP
    /// interleaves unrelated events (console, network) before our reply, so
    /// we loop until we see the matching id.
    private func cdpRuntimeEvaluate(
        wsURL: URL,
        expression: String,
        userGesture: Bool
    ) async -> String? {
        cdpRequestCounter &+= 1
        let requestID = cdpRequestCounter
        let params: [String: Any] = [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": false,
            "userGesture": userGesture
        ]
        guard let obj = await cdpSendCommand(
            wsURL: wsURL,
            method: "Runtime.evaluate",
            params: params,
            requestID: requestID
        ) else { return nil }

        // Runtime.evaluate with returnByValue=true nests the value at
        // `result.result.value`. For string results it's a plain String;
        // for numeric / JSON results callers pass a JS expression that
        // calls JSON.stringify so the string reaches us intact.
        guard let result = obj["result"] as? [String: Any],
              let inner = result["result"] as? [String: Any],
              let value = inner["value"] as? String else {
            return nil
        }
        return value
    }

    /// Send one arbitrary CDP command over a pooled WebSocket. Returns the
    /// full decoded response object (including `id` and `result`) so callers
    /// can reach into domain-specific fields. Nil on any transport failure
    /// or timeout.
    ///
    /// Pool lifecycle:
    ///  - Get-or-create a `CDPSocket` keyed by `wsURL`.
    ///  - Socket opens the WebSocket, resumes, and starts a single receive
    ///    loop that routes replies by `id`.
    ///  - Send registers a continuation under `requestID` and sleeps on a
    ///    2 s timeout; the receive loop resumes whichever continuation
    ///    matches when the reply lands. First-to-resume wins under the
    ///    socket's internal lock so double-resume is impossible.
    ///  - Failed sends close the socket — the next call gets a fresh
    ///    connection. Self-healing without an explicit eviction timer.
    private func cdpSendCommand(
        wsURL: URL,
        method: String,
        params: [String: Any],
        requestID: Int
    ) async -> [String: Any]? {
        let socket = socketForWS(wsURL)
        let payload: [String: Any] = [
            "id": requestID,
            "method": method,
            "params": params
        ]
        let response = await socket.send(payload: payload, requestID: requestID)
        if response == nil && socket.isBroken {
            // Transport went south — drop the cached entry so the next
            // caller re-establishes cleanly.
            cdpSockets.removeValue(forKey: wsURL)
            cdpSocketLastUse.removeValue(forKey: wsURL)
            await socket.teardown()
        }
        return response
    }

    private func socketForWS(_ wsURL: URL) -> CDPSocket {
        let now = Date()
        pruneSockets(now: now, keeping: wsURL)
        if let existing = cdpSockets[wsURL], !existing.isBroken {
            cdpSocketLastUse[wsURL] = now
            return existing
        }
        // The entry may exist but be broken — drop it before re-creating.
        if let stale = cdpSockets.removeValue(forKey: wsURL) {
            cdpSocketLastUse.removeValue(forKey: wsURL)
            Task { await stale.teardown() }
        }
        let socket = CDPSocket(wsURL: wsURL)
        cdpSockets[wsURL] = socket
        cdpSocketLastUse[wsURL] = now
        socket.start()
        return socket
    }

    /// Bound the pooled-socket count and reclaim stale ones. Evicts (a) any
    /// socket whose transport is broken, (b) any socket idle longer than
    /// `cdpSocketIdleTimeout`, and (c) the least-recently-used socket(s) until
    /// the pool fits under `cdpSocketPoolLimit` once `wsURL` is accounted for.
    /// `wsURL` is never evicted, so the caller's about-to-be-used entry always
    /// survives. Every evicted socket is `teardown()`-ed (in a detached Task,
    /// since this runs on the synchronous get-or-create path) so its
    /// URLSession and receive-loop Task are actually released — `removeValue`
    /// alone would leak them.
    private func pruneSockets(now: Date, keeping wsURL: URL) {
        var victims: [URL] = []
        for (key, socket) in cdpSockets where key != wsURL {
            if socket.isBroken {
                victims.append(key)
            } else if let last = cdpSocketLastUse[key],
                      now.timeIntervalSince(last) > Self.cdpSocketIdleTimeout {
                victims.append(key)
            }
        }

        // LRU-evict survivors until the pool fits. After this call exactly one
        // entry for `wsURL` is present (kept or freshly inserted), so the other
        // sockets must number at most `poolLimit - 1`.
        let limit = max(Self.cdpSocketPoolLimit - 1, 0)
        var survivorCount = cdpSockets.keys.filter { $0 != wsURL && !victims.contains($0) }.count
        if survivorCount > limit {
            let lruOrder = cdpSockets.keys
                .filter { $0 != wsURL && !victims.contains($0) }
                .sorted { (cdpSocketLastUse[$0] ?? .distantPast) < (cdpSocketLastUse[$1] ?? .distantPast) }
            for key in lruOrder where survivorCount > limit {
                victims.append(key)
                survivorCount -= 1
            }
        }

        guard !victims.isEmpty else { return }
        var toTeardown: [CDPSocket] = []
        for key in victims {
            if let socket = cdpSockets.removeValue(forKey: key) {
                toTeardown.append(socket)
            }
            cdpSocketLastUse.removeValue(forKey: key)
        }
        Task { for s in toTeardown { await s.teardown() } }
    }

    // MARK: - AppleScript helper (Safari path)

    #if canImport(AppKit)
    /// Runs an AppleScript string on a detached actor so `NSAppleScript.executeAndReturnError`
    /// (which blocks the calling thread) doesn't stall the concurrency pool.
    private func runAppleScript(_ source: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else { return nil }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error != nil { return nil }
            return result.stringValue
        }.value
    }
    #endif

    // MARK: - In-page JS payloads

    /// Enumeration payload. Runs inside the page, returns a JSON envelope
    /// with `{nodes, viewport}`. Nodes contain a best-effort stable selector
    /// (id → data-testid → aria-label → tag:text → path) plus the element's
    /// viewport-relative rect so the joiner can match against AX bounds.
    /// Hard-capped at 500 nodes so DOM-heavy pages (Gmail threads, GitHub
    /// search results) can't blow the round-trip.
    fileprivate static let interactiveEnumerationJS: String = """
    (() => {
      const selectors = ['a[href]', 'button', 'input', 'textarea', 'select',
        '[role="button"]', '[role="link"]', '[role="textbox"]', '[role="checkbox"]',
        '[role="menuitem"]', '[role="tab"]', '[contenteditable="true"]',
        'summary', 'label[for]'];
      const nodes = document.querySelectorAll(selectors.join(','));
      const out = [];
      // Security: if CSS.escape isn't available, do NOT fall back to a weak
      // polyfill. A partial polyfill that handled only double-quotes left
      // hostile input (brackets, parens, whitespace) free to break out of
      // the selector string and inject into the surrounding
      // querySelector() / value assignment. The sound behavior is to
      // refuse to emit a selector — the joiner then produces no annotation
      // and the executor falls through to CGEvent, which is always safe.
      const cssSupported = !!(window.CSS && CSS.escape);
      const esc = (s) => cssSupported ? CSS.escape(s) : null;
      const best = (el) => {
        if (!cssSupported) return null;
        if (el.id) return '#' + esc(el.id);
        const t = el.getAttribute('data-testid');
        if (t) return '[data-testid="' + esc(t) + '"]';
        const a = el.getAttribute('aria-label');
        if (a) return el.tagName.toLowerCase() + '[aria-label="' + esc(a) + '"]';
        const path = [];
        for (let n = el; n && n.nodeType === 1 && path.length < 8; n = n.parentElement) {
          let seg = n.tagName.toLowerCase();
          if (n.className && typeof n.className === 'string') {
            const c = n.className.trim().split(/\\s+/)[0];
            if (c) seg += '.' + esc(c);
          }
          const sib = n.parentElement ? Array.from(n.parentElement.children).indexOf(n) + 1 : 1;
          seg += ':nth-child(' + sib + ')';
          path.unshift(seg);
        }
        return path.join(' > ');
      };
      for (const el of nodes) {
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue;
        const sel = best(el);
        if (sel === null) continue; // CSS.escape missing — refuse rather than emit an unsafe selector.
        out.push({
          sel: sel,
          tag: el.tagName.toLowerCase(),
          id: el.id || null,
          role: el.getAttribute('role') || null,
          aria: el.getAttribute('aria-label') || null,
          text: (el.innerText || el.textContent || '').trim().slice(0, 120),
          rect: { x: r.x, y: r.y, w: r.width, h: r.height },
          isEditable: el.isContentEditable || ['INPUT','TEXTAREA','SELECT'].includes(el.tagName)
        });
        if (out.length >= 500) break;
      }
      return JSON.stringify({
        nodes: out,
        viewport: { scrollX: window.scrollX, scrollY: window.scrollY,
                    innerWidth: window.innerWidth, innerHeight: window.innerHeight,
                    devicePixelRatio: window.devicePixelRatio }
      });
    })()
    """

    /// `document.querySelector(sel).click()` with a matched/no-match envelope.
    fileprivate static func clickJS(selector: String) -> String {
        let escSel = escapeJSString(selector)
        return """
        (() => { try { const el = document.querySelector("\(escSel)"); \
        if (!el) return JSON.stringify({ok:false,reason:"no_match"}); \
        el.click(); return JSON.stringify({ok:true}); } \
        catch (e) { return JSON.stringify({ok:false,reason:"exception:"+String(e).slice(0,80)}); } })()
        """
    }

    fileprivate static func focusJS(selector: String) -> String {
        let escSel = escapeJSString(selector)
        return """
        (() => { try { const el = document.querySelector("\(escSel)"); \
        if (!el) return JSON.stringify({ok:false,reason:"no_match"}); \
        el.focus(); return JSON.stringify({ok:true}); } \
        catch (e) { return JSON.stringify({ok:false,reason:"exception:"+String(e).slice(0,80)}); } })()
        """
    }

    fileprivate static func inputJS(selector: String, value: String, commit: Bool) -> String {
        let escSel = escapeJSString(selector)
        let escVal = escapeJSString(value)
        let commitLine = commit
            ? "el.dispatchEvent(new KeyboardEvent(\"keydown\",{key:\"Enter\",keyCode:13,bubbles:true}));"
            : ""
        return """
        (() => { try { const el = document.querySelector("\(escSel)"); \
        if (!el) return JSON.stringify({ok:false,reason:"no_match"}); \
        el.focus(); \
        if (el.isContentEditable) { el.textContent = "\(escVal)"; } \
        else { el.value = "\(escVal)"; } \
        el.dispatchEvent(new Event("input",{bubbles:true})); \
        el.dispatchEvent(new Event("change",{bubbles:true})); \
        \(commitLine) \
        return JSON.stringify({ok:true}); } \
        catch (e) { return JSON.stringify({ok:false,reason:"exception:"+String(e).slice(0,80)}); } })()
        """
    }

    /// Escape a user-supplied string for splicing into a JS double-quoted
    /// literal. Order matters: backslash first, then quote, then newlines.
    fileprivate static func escapeJSString(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        return out
    }
}

// MARK: - Phase C Public Types

/// Outcome envelope for `dispatchClick`/`dispatchFocus`/`dispatchInput`.
/// Never throws — callers (e.g., `SemanticExecutor.press`) use the error
/// reason to decide whether to fall back to CGEvent rather than bailing.
public struct DispatchResult: Sendable {
    public let selector: String
    public let succeeded: Bool
    public let error: DispatchError?
    public let detail: String?

    public init(selector: String, succeeded: Bool, error: DispatchError?, detail: String?) {
        self.selector = selector; self.succeeded = succeeded
        self.error = error; self.detail = detail
    }
}

public enum DispatchError: String, Sendable {
    case browserNotFrontmost
    case cdpUnavailable
    case noMatchingNode
    case safariAutomationDenied
    case evalException
    case timeout
}

/// One interactive element discovered by `fetchInteractiveNodes`. Rects are
/// viewport-relative CSS pixels; the joiner translates to AX-space screen
/// coords via the browser window's AX `webArea` bounds + `scaleFactor`.
public struct DOMInteractiveNode: Sendable {
    public let selector: String
    public let tag: String
    public let id: String?
    public let role: String?
    public let aria: String?
    public let text: String
    public let rect: CGRect
    public let nodeId: Int?
    public let isEditable: Bool

    public init(
        selector: String, tag: String, id: String?, role: String?,
        aria: String?, text: String, rect: CGRect, nodeId: Int?,
        isEditable: Bool
    ) {
        self.selector = selector; self.tag = tag; self.id = id; self.role = role
        self.aria = aria; self.text = text; self.rect = rect; self.nodeId = nodeId
        self.isEditable = isEditable
    }
}

/// Result of `fetchInteractiveNodes`: the node list plus the viewport
/// metadata the joiner needs to translate rects into AX space.
public struct DOMEnumeration: Sendable {
    public let nodes: [DOMInteractiveNode]
    public let viewportSize: CGSize
    public let scaleFactor: CGFloat

    public init(nodes: [DOMInteractiveNode], viewportSize: CGSize, scaleFactor: CGFloat) {
        self.nodes = nodes
        self.viewportSize = viewportSize
        self.scaleFactor = scaleFactor
    }
}

// MARK: - CDPSocket (persistent pooled WebSocket)

/// Single-target persistent WebSocket with a shared receive loop.
///
/// Owns one `URLSessionWebSocketTask`, one URLSession, and a map from CDP
/// request id → pending continuation. The receive loop parses every
/// incoming frame and, when it carries an `id`, resumes the matching
/// continuation with the full response object. Unrelated CDP events
/// (console.log, Page.frameNavigated, Runtime.executionContextCreated) are
/// ignored by the id-match path — no 10-frame eviction cap, no reply ever
/// gets lost behind noise.
///
/// Thread model: `@unchecked Sendable` plus an NSLock around the pending
/// map. All mutation goes through the lock; the send/teardown methods are
/// safe from any context. Matches the pattern used elsewhere in
/// MetamorphiaPerception for classes crossing actor boundaries (e.g.
/// `RefStabilizer`).
fileprivate final class CDPSocket: @unchecked Sendable {

    private let wsURL: URL
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]
    private var closed: Bool = false
    private var transportFailed: Bool = false
    private var receiveLoopTask: Task<Void, Never>?

    init(wsURL: URL) {
        self.wsURL = wsURL
        let config = URLSessionConfiguration.ephemeral
        // Long server timeout so the socket itself stays up; per-request
        // timeouts are implemented in `send(...)` via Task.sleep so the
        // lifetime of an individual command is bounded even if the socket
        // is long-lived.
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 30.0
        self.session = URLSession(configuration: config)
        self.task = session.webSocketTask(with: wsURL)
    }

    /// True when the receive loop has observed a transport error. The
    /// owning pool checks this after a failed send and drops the entry,
    /// forcing the next caller to establish a fresh connection.
    var isBroken: Bool {
        lock.lock()
        defer { lock.unlock() }
        return transportFailed || closed
    }

    func start() {
        task.resume()
        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    /// Cancel the receive loop, invalidate the session, and resume any
    /// pending continuations with nil so callers don't hang.
    func teardown() async {
        let toFail: [CheckedContinuation<[String: Any]?, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            closed = true
            let snapshot = Array(pending.values)
            pending.removeAll()
            return snapshot
        }()
        receiveLoopTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        for cont in toFail { cont.resume(returning: nil) }
    }

    /// Send one CDP frame and await its matching reply. Per-command 2 s
    /// watchdog — if the reply doesn't arrive by then the continuation is
    /// resumed with nil (first-to-remove-wins under the lock so the
    /// receive loop's later resume is a no-op).
    func send(
        payload: [String: Any],
        requestID: Int,
        timeout: TimeInterval = 2.0
    ) async -> [String: Any]? {
        guard !isBroken,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return await withCheckedContinuation { cont in
            lock.lock()
            pending[requestID] = cont
            lock.unlock()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.task.send(.string(text))
                } catch {
                    // Send failed — mark transport as failed and resume the
                    // caller so they don't hang. Receive loop will observe
                    // the error too and tear us down.
                    self.markTransportFailed()
                    self.resumeIfPresent(requestID: requestID, with: nil)
                    return
                }
                // Timeout watchdog. Sleeps independently; the first path
                // (watchdog or receive loop) to reach the pending map wins.
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resumeIfPresent(requestID: requestID, with: nil)
            }
        }
    }

    // MARK: - Private

    private func markTransportFailed() {
        lock.lock(); transportFailed = true; lock.unlock()
    }

    /// Atomically remove the pending continuation for `requestID` and
    /// resume it with `payload`. First caller wins; subsequent calls
    /// observe a nil removeValue and no-op.
    private func resumeIfPresent(requestID: Int, with payload: [String: Any]?) {
        lock.lock()
        let cont = pending.removeValue(forKey: requestID)
        lock.unlock()
        cont?.resume(returning: payload)
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            let received: URLSessionWebSocketTask.Message
            do {
                received = try await task.receive()
            } catch {
                markTransportFailed()
                // Fail all outstanding requests so callers unblock.
                let toFail: [CheckedContinuation<[String: Any]?, Never>] = {
                    lock.lock()
                    defer { lock.unlock() }
                    let snapshot = Array(pending.values)
                    pending.removeAll()
                    return snapshot
                }()
                for cont in toFail { cont.resume(returning: nil) }
                return
            }
            let text: String
            switch received {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any] else { continue }
            if let id = obj["id"] as? Int {
                resumeIfPresent(requestID: id, with: obj)
            }
            // Unrelated CDP events (no id) are dropped; the per-request
            // continuation is what cares about them, not this loop.
        }
    }
}
