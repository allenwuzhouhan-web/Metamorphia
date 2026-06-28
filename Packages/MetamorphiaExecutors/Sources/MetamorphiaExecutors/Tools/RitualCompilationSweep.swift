import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - RitualCompilationSweep

/// Periodic sweep that bridges `SkillRecorder` + `ActivityStream` into the
/// skill-compilation pipeline.
///
/// Every `interval` seconds the sweep:
///   1. Snapshots `SkillRecorder.shared` for the current step log.
///   2. Fetches matching `ActivityEvent`s from `ActivityStream.shared` and
///      projects them to `ActivityCue`s (the package-boundary projection that
///      keeps MetamorphiaPerception AgentKit-free).
///   3. Runs `RitualSegmenter.segment` to carve the log into candidate windows.
///   4. Feeds each window's signature to `RitualRecurrenceStore`; windows that
///      cross the promotion threshold are retained.
///   5. Compiles the full step log via `SkillCompiler.compile` and filters to
///      skills whose signature matches a promoted window.
///   6. Calls the supplied `present` closure for each compiled skill so the
///      caller can surface an `.addSkill` proposal via `AmbientProposalPresenter`.
///   7. Drains `SkillRecorder` so the same steps aren't re-clustered next sweep.
///
/// Package boundary: this file is the only place that performs the
/// `ActivityEvent → ActivityCue` projection. `RitualSegmenter` and
/// `RitualRecurrenceStore` are in `MetamorphiaPerception` and import only
/// `Foundation`. The projection must never move into the Perception package.
public actor RitualCompilationSweep {

    // MARK: - Singleton

    public static let shared = RitualCompilationSweep()

    // MARK: - State

    private var timerTask: Task<Void, Never>?
    private let segmenter = RitualSegmenter()
    private let interval: TimeInterval

    // MARK: - Init

    public init(interval: TimeInterval = 15 * 60) {
        self.interval = interval
    }

    // MARK: - Lifecycle

    /// Start the periodic sweep. Idempotent — a second call before `stop()` is
    /// a no-op. The `present` closure is called on each compiled skill; the
    /// caller builds the `Proposal` and stores the side-channel association.
    public func start(present: @escaping @Sendable (CompiledSkill) async -> Void) {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.runOnce(present: present)
            }
        }
    }

    /// Cancel the periodic sweep.
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Core sweep (internal for testing)

    func runOnce(present: @Sendable (CompiledSkill) async -> Void) async {
        let steps = await SkillRecorder.shared.snapshot()
        guard steps.count >= 4 else { return }

        // Fetch ActivityEvents spanning the recorded step range.
        let since = steps.first?.ts ?? Date().addingTimeInterval(-3600)
        let events = await ActivityStream.shared.recent(since: since)
        let cues = Self.projectCues(events)

        // Segment into candidate ritual windows.
        let windows = await segmenter.segment(steps: steps, activityCues: cues)

        // Promote windows that have recurred enough times.
        var promotedWindows: [RitualWindow] = []
        for window in windows {
            if await RitualRecurrenceStore.shared.observe(signature: window.signature) {
                promotedWindows.append(window)
            }
        }
        guard !promotedWindows.isEmpty else { return }

        // Compile against the full step log so the compiler can find repeats.
        // Filter to skills whose structural signature matches a promoted window.
        let promotedSigs = Set(promotedWindows.map(\.signature))
        let compiled = SkillCompiler.compile(steps).filter { skill in
            promotedSigs.contains(Self.signature(of: skill))
        }

        for skill in compiled {
            await present(skill)
        }

        // Drain to avoid re-clustering the same steps on the next sweep.
        _ = await SkillRecorder.shared.drain()
    }

    // MARK: - Helpers

    /// Derive the structural signature of a compiled skill. Mirrors the
    /// SkillCompiler's per-step key format exactly so signatures match.
    private static func signature(of skill: CompiledSkill) -> String {
        skill.steps
            .map { "\($0.op.rawValue)|\($0.identityKey ?? "")" }
            .joined(separator: "›")
    }

    /// Project `ActivityEvent`s to the package-local `ActivityCue` type.
    /// This is the load-bearing boundary: MetamorphiaPerception must never see
    /// AgentKit types, so the projection lives here in Executors.
    private static func projectCues(_ events: [ActivityEvent]) -> [ActivityCue] {
        events.compactMap { event in
            switch event {
            case let .focusChanged(bundleID, _, _, _, at):
                return ActivityCue(kind: .focusChanged, bundleID: bundleID, at: at)
            case let .querySubmitted(_, _, at):
                return ActivityCue(kind: .querySubmitted, bundleID: nil, at: at)
            case let .inputIdle(_, at):
                return ActivityCue(kind: .idle, bundleID: nil, at: at)
            case let .inputResumed(_, at):
                return ActivityCue(kind: .resumed, bundleID: nil, at: at)
            default:
                return nil
            }
        }
    }
}
