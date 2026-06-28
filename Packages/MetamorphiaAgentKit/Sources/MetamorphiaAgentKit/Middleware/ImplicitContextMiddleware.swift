import Foundation

/// Injects unspoken context from the observation layer — "what's not said."
///
/// When a user says "fix this" while staring at an error in Xcode, the word "this"
/// carries meaning only if the system knows what app is frontmost and what's on screen.
/// This middleware gathers implicit context from:
///   1. **Frontmost app** — via ``SystemContextProvider``
///   2. **Clipboard metadata** — via ``ClipboardProvider`` (type, not content)
///   3. **Active session** — via ``SessionProvider``
///   4. **Recent file activity** — via `FileManager` scans (no AppKit needed)
///
/// Context is injected only when it appears relevant to the query, to avoid
/// noise in the system prompt.
///
/// All three providers are injected via the initializer; the package itself
/// never imports AppKit. Use `NullSystemContextProvider`, `NullClipboardProvider`,
/// and `NullSessionProvider` in tests or when a capability is disabled.
public final class ImplicitContextMiddleware: AgentMiddleware {
    public let name = "ImplicitContext"

    // MARK: - Dependencies

    private let systemContext: SystemContextProvider
    private let clipboard: ClipboardProvider
    private let session: SessionProvider
    /// Directories to scan for recently-modified files. Defaults to Desktop / Documents / Downloads.
    private let recentFileSearchDirs: [URL]

    public init(
        systemContext: SystemContextProvider,
        clipboard: ClipboardProvider = NullClipboardProvider(),
        session: SessionProvider = NullSessionProvider(),
        recentFileSearchDirs: [URL]? = nil
    ) {
        self.systemContext = systemContext
        self.clipboard = clipboard
        self.session = session
        if let dirs = recentFileSearchDirs {
            self.recentFileSearchDirs = dirs
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.recentFileSearchDirs = [
                home.appendingPathComponent("Desktop"),
                home.appendingPathComponent("Documents"),
                home.appendingPathComponent("Downloads"),
            ]
        }
    }

    // MARK: - Storage Keys

    private static let injectedKey = "ImplicitContext.injected"

    /// Storage key under which the agent loop stashes a pre-resolved frontmost
    /// app name (read once per task, off the synchronous middleware chain). The
    /// hook reads this cached value instead of blocking a cooperative-pool
    /// thread on an actor-isolated `await`. See `AgentLoop.submit`.
    public static let appNameKey = "ImplicitContext.appName"

    // MARK: - Relevance Signals

    private static let deicticWords: Set<String> = [
        "this", "that", "it", "here", "there", "these", "those",
        "current", "now", "above", "below",
    ]

    private static let clipboardSignals: Set<String> = [
        "copied", "pasted", "clipboard", "paste", "copy",
    ]

    private static let screenSignals: Set<String> = [
        "screen", "window", "page", "showing", "displayed", "visible",
        "look at", "see", "what's on", "currently",
    ]

    private static let vaguePatterns: [String] = [
        "fix this", "do this", "help with this", "what is this",
        "handle this", "finish this", "continue", "keep going",
        "what happened", "what's wrong", "why", "how",
    ]

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        let alreadyInjected = ctx.storage[Self.injectedKey] as? Bool ?? false
        guard !alreadyInjected else { return .continue }
        ctx.storage[Self.injectedKey] = true

        let query = ctx.command
        let lower = query.lowercased()

        let relevance = assessContextNeed(lower)
        guard relevance > 0.0 else { return .continue }

        var contextParts: [String] = []

        if let app = gatherAppContext(query: lower, ctx: ctx) {
            contextParts.append(app)
        }

        if let clip = gatherClipboardContext(query: lower) {
            contextParts.append(clip)
        }

        if relevance >= 0.5, let sess = gatherSessionContext() {
            contextParts.append(sess)
        }

        if relevance >= 0.3, let files = gatherRecentFileContext() {
            contextParts.append(files)
        }

        guard !contextParts.isEmpty else { return .continue }

        let section = formatImplicitContext(contextParts, relevance: relevance)

        if let sysIdx = ctx.messages.firstIndex(where: { $0.role == "system" }),
           let existing = ctx.messages[sysIdx].content {
            ctx.messages[sysIdx] = ChatMessage(role: "system", content: existing + "\n\n" + section)
        }

        return .continue
    }

    // MARK: - Relevance Assessment

    private func assessContextNeed(_ lower: String) -> Double {
        var score = 0.0
        let words = Set(lower.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty })

        let deicticCount = words.intersection(Self.deicticWords).count
        score += Double(deicticCount) * 0.25

        if lower.count < 20 {
            score += 0.3
        } else if lower.count < 40 {
            score += 0.15
        }

        for pattern in Self.vaguePatterns {
            if lower.contains(pattern) {
                score += 0.4
                break
            }
        }

        if !words.intersection(Self.clipboardSignals).isEmpty {
            score += 0.3
        }

        if !words.intersection(Self.screenSignals).isEmpty {
            score += 0.3
        }

        return min(score, 1.0)
    }

    // MARK: - Context Gathering

    private func gatherAppContext(query: String, ctx: MiddlewareContext) -> String? {
        // The frontmost app name is resolved once per task by `AgentLoop.submit`
        // (an `await` on the actor-isolated provider) and stashed in storage.
        // Reading it here is a plain synchronous lookup — no `Task`/semaphore,
        // so this hook never blocks a cooperative-pool thread waiting on a
        // child task that needs that same pool to make progress.
        let appName = ctx.storage[Self.appNameKey] as? String

        guard let name = appName, !name.isEmpty, name != "Metamorphia", name != "Executer" else {
            return nil
        }

        var context = "**Active app:** \(name)"

        let words = Set(query.components(separatedBy: .alphanumerics.inverted))
        if !words.intersection(Self.screenSignals).isEmpty {
            context += " (the user may be referring to something visible in \(name))"
        }

        return context
    }

    private func gatherClipboardContext(query: String) -> String? {
        guard let inspection = clipboard.inspect() else { return nil }

        let typeDesc: String
        switch inspection.kind {
        case .file(let fileName):
            typeDesc = "a file (\(fileName))"
        case .url:
            typeDesc = "a URL"
        case .image:
            typeDesc = "an image"
        case .text(let length):
            if length < 50 { typeDesc = "a short text snippet (\(length) chars)" }
            else if length < 500 { typeDesc = "a text passage (\(length) chars)" }
            else { typeDesc = "a long text block (\(length) chars)" }
        }

        let words = Set(query.components(separatedBy: .alphanumerics.inverted))
        let explicitRef = !words.intersection(Self.clipboardSignals).isEmpty
        let implicitRef = words.intersection(Self.deicticWords).count >= 1

        if explicitRef || implicitRef {
            return "**Clipboard:** Contains \(typeDesc)"
        }

        return nil
    }

    private func gatherSessionContext() -> String? {
        guard let info = session.currentSession() else { return nil }

        let minutes = Int(info.duration / 60)
        if minutes < 2 { return nil }

        var context = "**Current session:** \(info.title)"
        if minutes > 5 {
            context += " (\(minutes) min"
            if !info.apps.isEmpty {
                context += ", using \(info.apps.prefix(3).joined(separator: ", "))"
            }
            context += ")"
        }
        return context
    }

    private func gatherRecentFileContext() -> String? {
        let recentFiles = findRecentFiles(minutes: 5)
        guard !recentFiles.isEmpty else { return nil }

        let fileList = recentFiles.prefix(3).map { $0.lastPathComponent }.joined(separator: ", ")
        return "**Recent files:** \(fileList)"
    }

    // MARK: - Formatting

    private func formatImplicitContext(_ parts: [String], relevance: Double) -> String {
        var lines = ["## Current Context"]
        if relevance < 0.5 {
            lines.append("(This context may or may not be relevant to your request)")
        }
        lines.append(contentsOf: parts)
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func findRecentFiles(minutes: Int) -> [URL] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))

        var results: [URL] = []

        for dir in recentFileSearchDirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for url in contents {
                guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = attrs.contentModificationDate,
                      modDate > cutoff else { continue }
                results.append(url)
            }
        }

        results.sort { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }

        return Array(results.prefix(5))
    }
}
