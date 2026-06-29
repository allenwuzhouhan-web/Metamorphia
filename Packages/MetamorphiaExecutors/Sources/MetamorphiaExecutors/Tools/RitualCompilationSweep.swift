import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - RitualCompilationSweep

/// Periodic sweep that bridges `SkillRecorder` + `ActivityStream` into the
/// skill-compilation pipeline.
///
/// Every `interval` seconds the sweep:
///   1. Drains `SkillRecorder.shared` and appends new steps to an internal
///      rolling accumulation buffer (up to 500 steps). This decouples
///      compilation from per-sweep draining: `SkillCompiler` needs to see a
///      sequence repeat >= 3 times in a single call, which requires history
///      that spans multiple sweeps.
///   2. Fetches matching `ActivityEvent`s from `ActivityStream.shared` and
///      projects them to `ActivityCue`s (the package-boundary projection that
///      keeps MetamorphiaPerception AgentKit-free).
///   3. Runs `RitualSegmenter.segment` to carve the accumulated log into
///      candidate windows.
///   4. Feeds each window's signature to `RitualRecurrenceStore`; windows that
///      cross the promotion threshold are retained.
///   5. Compiles the full accumulated step history via `SkillCompiler.compile`
///      and filters to skills whose signature matches a promoted window.
///   6. Calls the supplied `present` closure for each compiled skill so the
///      caller can surface an `.addSkill` proposal via `AmbientProposalPresenter`.
///   7. Evicts from the accumulation buffer only the steps that were actually
///      consumed into a presented skill, leaving unrelated steps for future
///      sweeps.
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

    /// Rolling accumulation of SkillSteps across sweeps. The compiler needs
    /// to see the same sequence at least `minRepetitions` (3) times within
    /// a single `compile()` call. Draining SkillRecorder every sweep would
    /// reset this count to at most 1 per sweep, so we maintain our own
    /// rolling buffer that grows across sweeps up to `maxAccumulatedSteps`.
    ///
    /// Steps are evicted from this buffer only when they have been consumed
    /// into a skill that was presented to the user, preventing unbounded
    /// growth while ensuring the compiler always has enough history.
    private var accumulatedSteps: [SkillStep] = []

    /// Hard cap on accumulated step history. Mirrors SkillRecorder.maxSteps
    /// (500) — at ~0.15 actions/s that is roughly an hour of activity.
    private let maxAccumulatedSteps: Int = 500

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
        // Drain SkillRecorder and merge new steps into our rolling buffer.
        // We drain (not snapshot) so SkillRecorder doesn't grow unboundedly —
        // the authoritative cross-sweep history now lives in accumulatedSteps.
        let newSteps = await SkillRecorder.shared.drain()
        guard !newSteps.isEmpty || !accumulatedSteps.isEmpty else { return }

        mergeNewSteps(newSteps)

        let steps = accumulatedSteps
        guard steps.count >= 4 else { return }

        // Fetch ActivityEvents spanning the recorded step range.
        let since = steps.first?.ts ?? Date().addingTimeInterval(-3600)
        let events = await ActivityStream.shared.recent(since: since)
        let cues = Self.projectCues(events)

        // Segment into candidate ritual windows.
        let windows = await segmenter.segment(steps: steps, activityCues: cues)

        // Promote windows that have recurred enough times across sweeps.
        // RitualRecurrenceStore persists counts across sessions; `observe`
        // increments the count and returns true when the threshold is met.
        var promotedWindows: [RitualWindow] = []
        for window in windows {
            if await RitualRecurrenceStore.shared.observe(signature: window.signature) {
                promotedWindows.append(window)
            }
        }
        guard !promotedWindows.isEmpty else { return }

        // Compile against the full accumulated step log. With cross-sweep
        // history intact, SkillCompiler can now find sequences that repeat
        // >= minRepetitions (3) times and emit a CompiledSkill.
        // Filter to skills whose structural signature matches a promoted window.
        let promotedSigs = Set(promotedWindows.map(\.signature))
        let compiled = SkillCompiler.compile(steps).filter { skill in
            promotedSigs.contains(Self.signature(of: skill))
        }

        for skill in compiled {
            await present(skill)
        }

        // Evict from our accumulated buffer only the steps that were consumed
        // into a presented skill. Steps not yet part of a compiled skill are
        // retained so they can contribute to future sweeps.
        if !compiled.isEmpty {
            evictConsumedSteps(compiled: compiled)
        }
    }

    // MARK: - Buffer management

    /// Append new steps to accumulatedSteps, then trim to maxAccumulatedSteps
    /// by dropping the oldest entries from the front.
    private func mergeNewSteps(_ newSteps: [SkillStep]) {
        accumulatedSteps.append(contentsOf: newSteps)
        if accumulatedSteps.count > maxAccumulatedSteps {
            accumulatedSteps.removeFirst(accumulatedSteps.count - maxAccumulatedSteps)
        }
    }

    /// Remove from accumulatedSteps every step that is structurally part of
    /// a compiled skill. We identify consumed steps by matching the per-step
    /// identity signature ("op|identityKey") against every step in every skill.
    /// This avoids re-emitting the same skills on subsequent sweeps while
    /// leaving unrelated steps untouched.
    private func evictConsumedSteps(compiled: [CompiledSkill]) {
        // Build the set of per-step identity signatures consumed by any skill.
        var consumedStepSigs: Set<String> = []
        for skill in compiled {
            for step in skill.steps {
                consumedStepSigs.insert("\(step.op.rawValue)|\(step.identityKey ?? "")")
            }
        }
        accumulatedSteps.removeAll { step in
            consumedStepSigs.contains("\(step.op.rawValue)|\(step.identityKey ?? "")")
        }
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
