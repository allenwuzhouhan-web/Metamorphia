import Foundation

/// Bootstrap app profiles — Rank 7.
///
/// Seeds `ElementDatabase` with known-good `AppProfileRecord` rows for well-known apps
/// so the first capture doesn't have to pay the "no profile → AX-only → maybe schedule
/// background OCR" round trip. Two lists:
///
/// - `axRichApps` — AX tree is authoritative. Seeded with `needsOCR = false` so the
///   `.auto` OCR policy branch can skip the screenshot + OCR entirely when AX
///   is sufficient.
/// - `ocrRequiredApps` — canvas or pixel-heavy UIs. Seeded with `needsOCR = true`
///   so the pipeline takes the synchronous OCR path on first capture rather than
///   waiting a round for background OCR to seed.
///
/// Seeds are tagged `profiledBy = "seed-v1"`. `installIfNeeded(into:)` is idempotent
/// and **never clobbers a user-refined profile** (`profiledBy == "user"`) or an
/// auto-profile with more than one capture under its belt — see the implementation
/// comments for the exact rule.
public enum AppProfileSeeds {
    /// Version tag for this generation of seed data. Bump to `"seed-v2"` when you
    /// want `installIfNeeded` to overwrite stale seed rows without touching user
    /// or auto-refined profiles.
    public static let seedVersion: String = "seed-v1"

    /// Known AX-rich apps that rarely benefit from OCR. Seeded with `needsOCR = false`.
    public static let axRichApps: [SeedEntry] = [
        SeedEntry(bundleID: "com.apple.Safari",              name: "Safari",                 axCoverage: 0.95),
        SeedEntry(bundleID: "com.apple.finder",              name: "Finder",                 axCoverage: 0.98),
        SeedEntry(bundleID: "com.apple.mail",                name: "Mail",                   axCoverage: 0.92),
        SeedEntry(bundleID: "com.apple.Notes",               name: "Notes",                  axCoverage: 0.90),
        SeedEntry(bundleID: "com.apple.MobileSMS",           name: "Messages",               axCoverage: 0.88),
        SeedEntry(bundleID: "com.apple.Preview",             name: "Preview",                axCoverage: 0.85),
        SeedEntry(bundleID: "com.apple.TextEdit",            name: "TextEdit",               axCoverage: 0.95),
        SeedEntry(bundleID: "com.apple.Terminal",            name: "Terminal",               axCoverage: 0.70),
        SeedEntry(bundleID: "com.apple.dt.Xcode",            name: "Xcode",                  axCoverage: 0.92),
        SeedEntry(bundleID: "com.microsoft.VSCode",          name: "Visual Studio Code",     axCoverage: 0.90),
        SeedEntry(bundleID: "com.microsoft.Word",            name: "Microsoft Word",         axCoverage: 0.85),
        SeedEntry(bundleID: "com.microsoft.Excel",           name: "Microsoft Excel",        axCoverage: 0.82),
        SeedEntry(bundleID: "com.microsoft.Powerpoint",      name: "Microsoft PowerPoint",   axCoverage: 0.80),
        SeedEntry(bundleID: "com.tinyspeck.slackmacgap",     name: "Slack",                  axCoverage: 0.88),
        SeedEntry(bundleID: "com.tencent.xinWeChat",        name: "WeChat",                 axCoverage: 0.82),
        SeedEntry(bundleID: "com.tencent.WeChat",           name: "WeChat",                 axCoverage: 0.82),
        SeedEntry(bundleID: "us.zoom.xos",                   name: "Zoom",                   axCoverage: 0.85),
        SeedEntry(bundleID: "com.google.Chrome",             name: "Google Chrome",          axCoverage: 0.92),
        SeedEntry(bundleID: "company.thebrowser.Browser",    name: "Arc",                    axCoverage: 0.92),
        SeedEntry(bundleID: "org.mozilla.firefox",           name: "Firefox",                axCoverage: 0.90),
        SeedEntry(bundleID: "com.apple.iCal",                name: "Calendar",               axCoverage: 0.88),
        SeedEntry(bundleID: "com.apple.AppStore",            name: "App Store",              axCoverage: 0.80),
        SeedEntry(bundleID: "com.apple.Music",               name: "Music",                  axCoverage: 0.80),
        SeedEntry(bundleID: "com.spotify.client",            name: "Spotify",                axCoverage: 0.75),
        SeedEntry(bundleID: "md.obsidian",                   name: "Obsidian",               axCoverage: 0.88),
        SeedEntry(bundleID: "com.notion.id",                 name: "Notion",                 axCoverage: 0.85),
        SeedEntry(bundleID: "com.linear",                    name: "Linear",                 axCoverage: 0.85),
    ]

    /// Canvas / pixel-heavy apps that *must* use OCR for text extraction.
    public static let ocrRequiredApps: [SeedEntry] = [
        SeedEntry(bundleID: "org.blenderfoundation.blender",          name: "Blender",           axCoverage: 0.15),
        SeedEntry(bundleID: "com.blackmagic-design.DaVinciResolve",   name: "DaVinci Resolve",   axCoverage: 0.10),
        SeedEntry(bundleID: "com.lemon.lvoverseas",                   name: "CapCut",            axCoverage: 0.12),
        SeedEntry(bundleID: "com.figma.Desktop",                      name: "Figma",             axCoverage: 0.25),
        SeedEntry(bundleID: "com.seriflabs.affinityphoto",            name: "Affinity Photo",    axCoverage: 0.20),
        SeedEntry(bundleID: "com.adobe.photoshop",                    name: "Adobe Photoshop",   axCoverage: 0.18),
        SeedEntry(bundleID: "com.adobe.illustrator",                  name: "Adobe Illustrator", axCoverage: 0.18),
        SeedEntry(bundleID: "com.adobe.AfterEffects",                 name: "After Effects",     axCoverage: 0.15),
        SeedEntry(bundleID: "com.adobe.Premiere",                     name: "Premiere Pro",      axCoverage: 0.18),
        SeedEntry(bundleID: "com.apple.FinalCutPro",                  name: "Final Cut Pro",     axCoverage: 0.22),
        SeedEntry(bundleID: "com.apple.Motion",                       name: "Motion",            axCoverage: 0.20),
        SeedEntry(bundleID: "com.unity3d.UnityEditor5.x",             name: "Unity",             axCoverage: 0.20),
        SeedEntry(bundleID: "com.apple.iWork.Keynote",                name: "Keynote (canvas)",  axCoverage: 0.45),   // mixed
        SeedEntry(bundleID: "com.apple.shortcuts",                    name: "Shortcuts",         axCoverage: 0.50),   // mixed
        SeedEntry(bundleID: "com.electron.cursor",                    name: "Cursor",            axCoverage: 0.75),   // electron variant
    ]

    public struct SeedEntry: Sendable {
        public let bundleID: String
        public let name: String
        public let axCoverage: Float

        public init(bundleID: String, name: String, axCoverage: Float) {
            self.bundleID = bundleID
            self.name = name
            self.axCoverage = axCoverage
        }
    }

    /// Ensures seeds are installed in the ElementDatabase. Idempotent — does not clobber
    /// user-refined profiles and does not re-bump `profile_version` on re-invocation.
    ///
    /// Rules:
    /// - If no row exists for a bundle, install a fresh seed row.
    /// - If an existing row has `profiledBy == "seed-v1"` with the *current* seed version,
    ///   leave it alone (idempotent no-op).
    /// - If an existing row has `profiledBy == "seed-vN"` for a *previous* seed version,
    ///   overwrite (lets us retune seeds by bumping `seedVersion`).
    /// - If an existing row has `profiledBy == "user"`, leave it alone — users win.
    /// - If an existing row has `profiledBy == "auto"`, leave it alone — live data wins
    ///   over stale seeds once we've seen the app ourselves.
    ///
    /// Call this once at pipeline bootstrap. See `PerceptionPipeline.init()` for the
    /// canonical call site; `DefaultComputerPerception` exposes it as
    /// `installBootstrapProfiles()` for external consumers that build their own stack.
    public static func installIfNeeded(into db: ElementDatabase = .shared) {
        installList(axRichApps, needsOCR: false, into: db)
        installList(ocrRequiredApps, needsOCR: true, into: db)
    }

    /// Returns the seed profile for a bundle ID if it appears in either list, else nil.
    /// Used by `appProfileIsOCRRequired` to answer without a database round-trip when
    /// the caller hasn't installed seeds yet.
    public static func seedFor(bundleID: String) -> (needsOCR: Bool, coverage: Float)? {
        if let ax = axRichApps.first(where: { $0.bundleID == bundleID }) {
            return (false, ax.axCoverage)
        }
        if let ocr = ocrRequiredApps.first(where: { $0.bundleID == bundleID }) {
            return (true, ocr.axCoverage)
        }
        return nil
    }

    // MARK: - Private helpers

    private static func installList(_ seeds: [SeedEntry], needsOCR: Bool, into db: ElementDatabase) {
        for seed in seeds {
            if let existing = db.getAppProfile(bundleID: seed.bundleID) {
                // User-refined profiles always win.
                if existing.profiledBy == "user" { continue }
                // Auto-profiles (built from live captures) win over seeds — the live
                // data reflects reality on this machine better than our seed guess.
                if existing.profiledBy == "auto" { continue }
                // Current-generation seed — nothing to do.
                if existing.profiledBy == seedVersion { continue }
                // Older-generation seed ("seed-v0" or similar) — fall through and
                // overwrite with the current seed.
            }

            let record = AppProfileRecord(
                bundleID: seed.bundleID,
                appName: seed.name,
                appVersion: nil,
                needsOCR: needsOCR,
                axCoveragePct: seed.axCoverage,
                elementCountAvg: nil,
                interactiveCountAvg: nil,
                structuralHash: nil,
                roleDistributionJSON: nil,
                toolbarSignature: nil,
                menuBarItemsJSON: nil,
                customRolesJSON: nil,
                elementAliasesJSON: nil,
                lastProfiled: Date(),
                profiledBy: seedVersion,
                profileVersion: 1
            )
            db.saveAppProfile(record)
        }
    }
}
