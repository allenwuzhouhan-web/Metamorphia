/*
 * Metamorphia
 * App-level coordinator for Retrace. Owns the `RetraceIndex`, `QueryRank`,
 * `RetraceIngest`, and all archivers. Bootstrapped once at app launch from
 * `MetamorphiaBootstrap`. The UI (RichTurnContentView + NotchRetraceView)
 * calls `RetraceSurface.shared.search(_:)` without caring about plumbing.
 */

import Foundation
import AppKit
import MetamorphiaAgentKit
import MetamorphiaPerception

@MainActor
public final class RetraceSurface: ObservableObject {

    public static let shared = RetraceSurface()

    // Core
    public private(set) var index: RetraceIndex?
    public private(set) var ingest: RetraceIngest?
    public private(set) var queryRank: QueryRank?
    public private(set) var timeResolver: TimeResolver?

    // Archivers
    public private(set) var clipArchive: ClipArchive?
    public private(set) var browserArchive: BrowserArchive?
    public private(set) var calendarArchive: CalendarArchive?
    public private(set) var agentTurnArchive: AgentTurnArchive?
    public private(set) var messageArchive: MessageArchive?
    public private(set) var mailArchive: MailArchive?
    public private(set) var fileHarvest: FileHarvest?

    // Dependency injection hooks — set by bootstrap before `start()`.
    public var aliasStore: EntityAliasStore?
    public var termFrequency: RollingTermFrequency?
    public var interestGraph: InterestGraphStore?
    public var activityStream: ActivityStream?
    public var anchorLookup: TimeResolver.AnchorLookup = .empty

    private var screenSink: ScreenSinkAdapter?
    private var started = false

    public init() {}

    // MARK: - Bootstrap

    public func start() {
        guard !started else { return }
        started = true

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Metamorphia/retrace", isDirectory: true)

        let idx = RetraceIndex.configureShared(directory: appSupport)
        self.index = idx

        let ingest = RetraceIngest.configureShared(
            index: idx,
            aliasStore: aliasStore,
            termFrequency: termFrequency,
            interestGraph: interestGraph,
            activityStream: activityStream,
            embed: Embed.shared
        )
        self.ingest = ingest

        self.timeResolver = TimeResolver(anchorLookup: anchorLookup)

        self.queryRank = QueryRank(
            index: idx,
            resolver: self.timeResolver ?? TimeResolver(),
            embed: Embed.shared,
            aliasStore: aliasStore,
            interestGraph: interestGraph
        )

        // Archivers
        self.clipArchive = ClipArchive(ingest: ingest)
        self.browserArchive = BrowserArchive(ingest: ingest)
        self.calendarArchive = CalendarArchive(ingest: ingest)
        self.agentTurnArchive = AgentTurnArchive(ingest: ingest)
        self.messageArchive = MessageArchive(ingest: ingest)
        self.mailArchive = MailArchive(ingest: ingest)
        self.fileHarvest = FileHarvest(ingest: ingest)

        // Screen harvest — the biggest source. Attach sink before starting.
        let adapter = ScreenSinkAdapter(ingest: ingest)
        self.screenSink = adapter
        ScreenHarvest.shared.attach(sink: adapter)
    }

    // MARK: - Search (called by the UI)

    public struct SearchSummary: Sendable {
        public let scenes: [RecallScene]
        public let window: TimeWindow?
        public let autoNarrowed: Bool
    }

    public func search(_ query: String) async -> SearchSummary? {
        guard let rank = queryRank else { return nil }
        let result = await rank.search(query)
        return SearchSummary(
            scenes: result.scenes,
            window: result.window,
            autoNarrowed: result.autoNarrowed
        )
    }
}

// MARK: - Screen harvest → RetraceIngest adapter

/// Receives `ScreenFrame` from `ScreenHarvest` and translates to a Retrace
/// `Draft` on the ingest path. The adapter owns a weak reference to the
/// actor so deinit is clean.
private final class ScreenSinkAdapter: ScreenHarvestSink {
    let ingest: RetraceIngest

    init(ingest: RetraceIngest) {
        self.ingest = ingest
    }

    func receive(_ frame: ScreenFrame) async {
        let draft = RetraceIngest.Draft(
            kind: .screen,
            timestamp: frame.capturedAt,
            appBundleID: frame.appBundleID,
            docPath: frame.docPath,
            url: frame.url,
            title: frame.windowTitle,
            body: frame.body,
            confidence: 1.0,
            sourceMeta: [
                "appName": frame.appName,
                "roleChain": frame.roleChainSummary,
                "bodyHash": String(frame.bodyHash),
            ],
            interestEvent: .longDwell,
            interestScale: 0.2
        )
        _ = await ingest.ingest(draft)
    }
}
