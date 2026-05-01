import Foundation

/// Helper that bundles a `RecallScene` into a concrete "pick it back up"
/// action: a list of files to reopen, a list of URLs to relaunch, and the
/// optional agent-thread session ID to reattach. The host app performs the
/// actual `NSWorkspace.open` / `BrowserTools.openURL` calls — this module
/// stays free of `AppKit`.
public struct ResumeScene: Sendable {

    public let filesToReopen: [String]
    public let urlsToReopen: [String]
    public let agentSessionID: UUID?
    public let headline: String

    public init(filesToReopen: [String], urlsToReopen: [String], agentSessionID: UUID?, headline: String) {
        self.filesToReopen = filesToReopen
        self.urlsToReopen = urlsToReopen
        self.agentSessionID = agentSessionID
        self.headline = headline
    }

    /// Synthesize a resume plan from the members of a scene.
    public static func from(_ scene: RecallScene) -> ResumeScene {
        var files: [String] = []
        var urls: [String] = []
        var agentSession: UUID?

        for hit in scene.members {
            if hit.item.kind == .file, let path = hit.item.docPath, !files.contains(path) {
                files.append(path)
            }
            if let u = hit.item.url, !urls.contains(u) {
                urls.append(u)
            }
            if agentSession == nil, hit.item.kind == .agentTurn, let s = hit.item.sessionID {
                agentSession = s
            }
        }

        let hero = scene.hero.item
        let title = hero.title ?? "(unnamed)"
        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .short
        let whenStr = when.localizedString(for: hero.timestamp, relativeTo: Date())
        let headline = "Resuming “\(title)” — last worked \(whenStr)"

        return ResumeScene(
            filesToReopen: files,
            urlsToReopen: urls,
            agentSessionID: agentSession,
            headline: headline
        )
    }
}
