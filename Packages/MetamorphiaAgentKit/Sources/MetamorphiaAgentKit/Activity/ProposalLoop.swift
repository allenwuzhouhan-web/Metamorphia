import Combine
import Foundation

// MARK: - Proposal

/// A single actionable suggestion surfaced by the ambient agent loop.
///
/// The Whisper Card subscribes to `ProposalLoop.proposals` and renders one
/// rationale line plus a single primary action. Every proposal carries the
/// goal that produced it and the primary target identifier so
/// `AmbientProposalPresenter` can close the loop end-to-end: user taps "Do
/// it" → the presenter looks up the proposal by id → routes to the
/// `computer_batch` or tool call the proposal points at.
///
/// Proposals are immutable. Once published they don't mutate — the loop
/// emits a new one instead, carrying the same id if it's a refreshed
/// version of a still-relevant suggestion.
public struct Proposal: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let goal: ProposalGoal
    public let rationale: String
    public let primaryActionLabel: String
    /// Semantic key used by the novelty gate — equal keys within the 15 min
    /// window collapse to one surface. Encodes goal + the principal target
    /// (e.g. a clipboard URL hash, a pid+window) so unrelated proposals
    /// don't suppress each other.
    public let noveltyKey: String
    public let confidence: Double
    public let surfacedAt: Date

    public init(
        id: UUID = UUID(),
        goal: ProposalGoal,
        rationale: String,
        primaryActionLabel: String,
        noveltyKey: String,
        confidence: Double,
        surfacedAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.rationale = rationale
        self.primaryActionLabel = primaryActionLabel
        self.noveltyKey = noveltyKey
        self.confidence = confidence
        self.surfacedAt = surfacedAt
    }
}

/// Fixed set of proposal goals the loop can infer. Deliberately narrow on
/// first ship — two templates prove the loop end-to-end, more land in
/// follow-up turns without schema churn. Adding a case is cheap; the
/// Whisper Card doesn't switch on goal, only reads the rationale text.
public enum ProposalGoal: String, Sendable, Hashable, Codable {
    /// Clipboard holds a URL and the user is focused in a text-input
    /// inside a messaging / chat / compose surface. Suggest pasting.
    case pasteLink
    /// A `.meetingStarted` event fired and the user is still lingering on
    /// a calendar / browser tab. Surface a one-tap "Join now" so the user
    /// doesn't have to hunt for the meeting link.
    case joinMeeting
    /// A large document was opened recently from the Downloads folder.
    /// Surface "Save to Documents?" — addresses the common Downloads-folder
    /// sprawl habit without being intrusive.
    case saveDownload
    /// The user focused a chat / messaging surface after an inbound
    /// activity signal (VC app, unread notification). Surface "Draft a
    /// reply?" so the workflow recorder can jump-start a template.
    case replyToMessage
}

// MARK: - ProposalLoop

/// Ambient agent loop. Subscribes to `ActivityStream` events, polls
/// `AttentionModel.currentScore` and `PerceptionBudget.current`, and emits
/// `Proposal`s through a Combine publisher that the Whisper Card (or any
/// other surface) can subscribe to.
///
/// Concurrency: this is a Swift `actor` so its state (recent-event buffer,
/// rate-limit timestamps, novelty memory) stays race-free under parallel
/// calls from multiple stream subscribers. All handler work lands inside
/// the actor via `Task { await self.handle(event) }` — matching the
/// pattern in `SessionSegmenter`.
///
/// Guards, all AND-gated before emission (the full set is documented on
/// each `canEmit…` check so reviewers can see what must hold without
/// tracing through `tryEmit`):
///   1. Attention score in the between-tasks band `[0.6, 0.85]`. Below 0.6
///      the user is idle (don't distract); above 0.85 the user is in flow
///      (don't interrupt).
///   2. Budget tier at least `.reduced`. `.parked` / `.minimal` suppress.
///   3. Rate limit: ≤ 1 surfaced proposal per 90 seconds, ≤ 6 per rolling
///      hour. Reset on user acceptance so the loop feels responsive
///      after a confirmed interaction.
///   4. Novelty window: the same `(goal, primaryRef)` key was not surfaced
///      in the last 15 minutes.
///
/// Subscribing to proposals:
/// ```swift
/// let loop = ProposalLoop.shared
/// await loop.start(...)
/// let cancellable = await loop.proposalsPublisher.sink { proposal in
///     // render the Whisper Card
/// }
/// ```
public actor ProposalLoop {

    // MARK: - Singleton + state

    public static let shared = ProposalLoop()

    private var subscriptionTask: Task<Void, Never>?
    private var started = false

    /// Rolling window of recent `ActivityEvent`s. 30 seconds covers the
    /// "user just copied, then switched to Slack" compose flow; longer
    /// windows add cognitive noise (we'd surface proposals for events
    /// the user already forgot about).
    private struct RecentEvent {
        let event: ActivityEvent
        let at: Date
    }
    private var recentEvents: [RecentEvent] = []

    /// Rate-limit state. `lastEmissionAt` gates the 90s minimum interval;
    /// `hourlyEmissions` is a rolling window of up-to-6 recent surfaces.
    private var lastEmissionAt: Date = .distantPast
    private var hourlyEmissions: [Date] = []

    /// Novelty memory. Keys are `Proposal.noveltyKey`, values are the
    /// timestamp of the last surfacing. Entries older than 15 minutes
    /// are dropped lazily during each emission attempt.
    private var noveltyMemory: [String: Date] = [:]

    /// Publisher surface for proposals. The Whisper Card presenter
    /// subscribes here. Non-isolated property access is safe because
    /// `PassthroughSubject` + `AnyPublisher` are thread-safe and
    /// `send` is a reference-type method.
    private let subject = PassthroughSubject<Proposal, Never>()

    // MARK: - Tunables (documented on the struct so tests can inspect)

    public struct Tunables: Sendable {
        public var attentionLowerBound: Double = 0.6
        public var attentionUpperBound: Double = 0.85
        public var minIntervalBetweenProposals: TimeInterval = 90
        public var hourlyProposalCap: Int = 6
        public var noveltyWindow: TimeInterval = 15 * 60
        public var recentEventWindow: TimeInterval = 30
        public init() {}
    }
    private var tunables = Tunables()

    // MARK: - Attention + budget accessors

    /// Injected at `start(…)`. Kept as closures so this actor doesn't
    /// depend on AppKit / AttentionModel directly — AgentKit can't import
    /// the app target. Callers (MetamorphiaBootstrap) wire these to
    /// `AttentionModel.shared.currentScore` and
    /// `PerceptionBudget.shared.current.rawValue`.
    private var attentionScoreProvider: @Sendable () async -> Double = { 0.7 }
    private var budgetTierProvider: @Sendable () async -> Int = { 3 }

    // MARK: - Public API

    public init() {}

    /// Non-isolated publisher surface. Safe from any context because
    /// `PassthroughSubject` is thread-safe internally and downstream
    /// delivery uses the subscriber's scheduler.
    public nonisolated var proposalsPublisher: AnyPublisher<Proposal, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Wire the loop up. Idempotent — a second call replaces the providers
    /// and leaves the subscription in place. `activityStream` is the same
    /// instance the rest of AgentKit reads.
    ///
    /// Ingest uses an AsyncStream bridge rather than a Combine `.sink` that
    /// spawns per-event Tasks. Two reasons (critic H4): a fresh Task per
    /// event can arrive out-of-order at the actor's executor under load —
    /// the 30 s rolling window's goal inference assumes submission order.
    /// Second, sustained ActivityStream bursts (10–30 events/s during
    /// active use) allocate a Task per event; a single `for await` reuses
    /// one task and preserves order for free.
    public func start(
        stream: ActivityStream,
        attentionScore: @escaping @Sendable () async -> Double,
        budgetTier: @escaping @Sendable () async -> Int,
        tunables: Tunables = Tunables()
    ) {
        self.attentionScoreProvider = attentionScore
        self.budgetTierProvider = budgetTier
        self.tunables = tunables
        guard !started else { return }
        started = true
        // Bridge Combine → AsyncStream. Downstream cancellation closes
        // the AsyncStream, which terminates the for-await loop below.
        let events = stream.events
        // Bounded drop-oldest buffer mirroring ActivityStream's own ring
        // semantics. The proposal loop is advisory (one card at a time,
        // rate-limited to ≤1/90s), so if the async attention/budget
        // providers transiently lag behind a 10–30 event/s burst, dropping
        // the oldest pending events is harmless and caps buffer growth —
        // an unbounded policy would accumulate ActivityEvents without limit
        // for the duration of a MainActor stall.
        let bridged = AsyncStream<ActivityEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let cancellable = events.sink { event in
                continuation.yield(event)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
        subscriptionTask = Task { [weak self] in
            for await event in bridged {
                guard let self else { return }
                await self.ingest(event: event)
            }
        }
    }

    /// Notify the loop that the user accepted a proposal. Resets the rate
    /// limiter (proposals felt responsive and useful → the limiter can
    /// relax for the next interaction) and clears novelty on the
    /// accepted key.
    public func acknowledgeAcceptance(_ proposal: Proposal) {
        hourlyEmissions.removeAll()
        lastEmissionAt = .distantPast
        noveltyMemory.removeValue(forKey: proposal.noveltyKey)
    }

    // MARK: - Event ingest

    private func ingest(event: ActivityEvent) async {
        let now = Date()
        appendRecent(event: event, at: now)
        await evaluate(now: now)
    }

    private func appendRecent(event: ActivityEvent, at now: Date) {
        recentEvents.append(RecentEvent(event: event, at: now))
        let cutoff = now.addingTimeInterval(-tunables.recentEventWindow)
        recentEvents.removeAll { $0.at < cutoff }
    }

    // MARK: - Goal inference + emission

    /// Walk the goal templates in priority order. Emit the first one whose
    /// preconditions + guards hold. Deliberately eager-exits after one
    /// proposal — we never surface two proposals for a single trigger.
    private func evaluate(now: Date) async {
        guard await gatesAllow(now: now) else { return }

        // Order matters — earlier goals win when their preconditions hold.
        // paste-link outranks join-meeting outranks save-download outranks
        // reply-to-message. Rationale: paste-link has the highest user intent
        // signal (explicit copy + app switch); reply-to-message is the broadest
        // heuristic and therefore most likely to false-positive, so it's last.
        if let proposal = inferPasteLink(now: now) {
            tryEmit(proposal, now: now); return
        }
        if let proposal = inferJoinMeeting(now: now) {
            tryEmit(proposal, now: now); return
        }
        if let proposal = inferSaveDownload(now: now) {
            tryEmit(proposal, now: now); return
        }
        if let proposal = inferReplyToMessage(now: now) {
            tryEmit(proposal, now: now); return
        }
    }

    /// Infer a paste-link proposal from the recent event buffer.
    /// Preconditions:
    ///   - A `.pasteboardCopied` event in the window with URL-shaped kind.
    ///   - A `.focusChanged` event after the copy whose app is a known
    ///     messaging / compose surface (Slack, Messages, Mail, Safari, etc).
    ///     We don't have deep-focused-element introspection here, so the
    ///     app-identity heuristic is the gate — good enough for phase D's
    ///     first surface.
    private func inferPasteLink(now: Date) -> Proposal? {
        var copyEvent: (urlHash: String, at: Date)?
        var focusAfterCopy: (appName: String, bundleID: String, at: Date)?

        for entry in recentEvents {
            switch entry.event {
            case let .clipboardCopied(kind, _, _, at):
                if kind == .url {
                    copyEvent = (urlHash: "\(at.timeIntervalSince1970)", at: at)
                }
            case let .focusChanged(bundleID, appName, _, _, at):
                if let c = copyEvent, at >= c.at {
                    focusAfterCopy = (appName: appName, bundleID: bundleID, at: at)
                }
            default:
                break
            }
        }

        guard let copy = copyEvent, let focus = focusAfterCopy else { return nil }
        guard Self.isComposeFriendlyApp(bundleID: focus.bundleID) else { return nil }

        let appLabel = focus.appName.isEmpty ? focus.bundleID : focus.appName
        let noveltyKey = "pasteLink|\(focus.bundleID)|\(copy.urlHash)"
        return Proposal(
            goal: .pasteLink,
            rationale: "Paste copied link into \(appLabel)?",
            primaryActionLabel: "Paste link",
            noveltyKey: noveltyKey,
            confidence: 0.72,
            surfacedAt: now
        )
    }

    /// Join-meeting: a `.meetingStarted` event in the window, and the user
    /// hasn't already focused the VC app. The goal is a one-tap escape from
    /// the "where's the join link?" hunt that happens every time a calendar
    /// alarm fires.
    private func inferJoinMeeting(now: Date) -> Proposal? {
        var started: (app: String, at: Date)?
        var focusedVC: Bool = false
        let vcBundles: Set<String> = [
            "us.zoom.xos", "com.microsoft.teams2", "com.cisco.webexmeetingsapp",
            "com.hnc.Discord", "com.tinyspeck.slackmacgap", "org.whispersystems.signal-desktop",
            "com.apple.FaceTime"
        ]
        for entry in recentEvents {
            switch entry.event {
            case let .meetingStarted(app, at):
                started = (app, at)
            case let .focusChanged(bundleID, _, _, _, _):
                if let s = started, vcBundles.contains(bundleID), entry.at >= s.at {
                    focusedVC = true
                }
            default:
                break
            }
        }
        guard let meeting = started, !focusedVC else { return nil }
        let noveltyKey = "joinMeeting|\(meeting.app)|\(Int(meeting.at.timeIntervalSince1970))"
        return Proposal(
            goal: .joinMeeting,
            rationale: "Join your \(meeting.app) meeting?",
            primaryActionLabel: "Join now",
            noveltyKey: noveltyKey,
            confidence: 0.78,
            surfacedAt: now
        )
    }

    /// Save-download: a `.documentOpened` from a Downloads-origin app
    /// suggests the user just grabbed a file and may want to move it.
    /// Conservative — only fires on small/medium docs so we don't surface
    /// the prompt every time the user opens a PDF from a browser render.
    private func inferSaveDownload(now: Date) -> Proposal? {
        for entry in recentEvents.reversed() {
            if case let .documentOpened(bundleID, fileExtension, sizeBucket, _) = entry.event {
                // Keep to "likely a real download the user means to keep"
                // shapes — excludes the tiny PDF previews browsers auto-open.
                guard [DocSizeBucket.small, .medium].contains(sizeBucket) else { continue }
                guard [
                    "pdf", "zip", "dmg", "pkg", "docx", "xlsx", "pptx", "csv", "jpg", "png", "mp4"
                ].contains(fileExtension.lowercased()) else { continue }
                let key = "saveDownload|\(bundleID ?? "unknown")|\(fileExtension)"
                return Proposal(
                    goal: .saveDownload,
                    rationale: "Move this .\(fileExtension) out of Downloads?",
                    primaryActionLabel: "Review",
                    noveltyKey: key,
                    confidence: 0.5,
                    surfacedAt: now
                )
            }
        }
        return nil
    }

    /// Reply-to-message: the user focused a chat app shortly after a
    /// camera/mic toggle or meeting signal — implies they just stepped
    /// away from a call and may want to reply to a message they missed.
    /// Broadest signal of the five; lowest confidence; rate-limited by the
    /// novelty gate to avoid over-firing.
    private func inferReplyToMessage(now: Date) -> Proposal? {
        let chatBundles: Set<String> = [
            "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord",
            "com.whatsapp.WhatsApp", "com.microsoft.teams2",
            "com.tencent.xinWeChat", "com.tencent.WeChat", "com.tencent.xin"
        ]
        var lastHardwareSignalAt: Date?
        var focusedChatRecently: (bundleID: String, appName: String, at: Date)?
        for entry in recentEvents {
            switch entry.event {
            case .cameraToggled, .microphoneToggled:
                lastHardwareSignalAt = entry.at
            case let .focusChanged(bundleID, appName, _, _, at):
                if chatBundles.contains(bundleID),
                   let hw = lastHardwareSignalAt, at >= hw {
                    focusedChatRecently = (bundleID: bundleID, appName: appName, at: at)
                }
            default:
                break
            }
        }
        guard let hit = focusedChatRecently else { return nil }
        let key = "replyToMessage|\(hit.bundleID)|\(Int(hit.at.timeIntervalSince1970))"
        let appLabel = hit.appName.isEmpty ? hit.bundleID : hit.appName
        return Proposal(
            goal: .replyToMessage,
            rationale: "Reply to recent messages in \(appLabel)?",
            primaryActionLabel: "Draft reply",
            noveltyKey: key,
            confidence: 0.45,
            surfacedAt: now
        )
    }

    // MARK: - Guards

    private func gatesAllow(now: Date) async -> Bool {
        guard recentEvents.count > 0 else { return false }

        // (1) Attention band.
        let score = await attentionScoreProvider()
        guard score >= tunables.attentionLowerBound,
              score <= tunables.attentionUpperBound else { return false }

        // (2) Budget tier. `parked` = 0, `minimal` = 1, `reduced` = 2,
        // `full` = 3 — require at least reduced so the proposal's
        // downstream perception/suggestion work has headroom.
        let tier = await budgetTierProvider()
        guard tier >= 2 else { return false }

        // (3) Rate limit.
        let sinceLast = now.timeIntervalSince(lastEmissionAt)
        guard sinceLast >= tunables.minIntervalBetweenProposals else { return false }
        let hourAgo = now.addingTimeInterval(-3600)
        hourlyEmissions.removeAll { $0 < hourAgo }
        guard hourlyEmissions.count < tunables.hourlyProposalCap else { return false }

        return true
    }

    private func tryEmit(_ proposal: Proposal, now: Date) {
        // (4) Novelty. Drop stale memory first so the map doesn't grow
        // unbounded under long sessions.
        let noveltyCutoff = now.addingTimeInterval(-tunables.noveltyWindow)
        noveltyMemory = noveltyMemory.filter { $0.value >= noveltyCutoff }
        if let last = noveltyMemory[proposal.noveltyKey], last >= noveltyCutoff {
            return
        }
        noveltyMemory[proposal.noveltyKey] = now
        lastEmissionAt = now
        hourlyEmissions.append(now)
        subject.send(proposal)
    }

    // MARK: - Heuristics

    /// Bundle-ID allowlist for apps where a pasted link is almost always
    /// the next user intent. Kept narrow — adding a new bundle should be
    /// an informed, explicit decision rather than a generic heuristic.
    private static let composeFriendlyBundles: Set<String> = [
        "com.tinyspeck.slackmacgap",   // Slack
        "com.apple.MobileSMS",         // Messages
        "com.hnc.Discord",             // Discord
        "com.apple.mail",              // Mail
        "com.apple.Notes",
        "com.microsoft.teams2",
        "com.microsoft.Outlook",
        "com.whatsapp.WhatsApp",
        "com.tencent.xinWeChat",
        "com.tencent.WeChat",
        "com.tencent.xin",
        "com.apple.Safari",
        "com.google.Chrome",
        "org.whispersystems.signal-desktop"
    ]

    private static func isComposeFriendlyApp(bundleID: String) -> Bool {
        composeFriendlyBundles.contains(bundleID)
    }
}
