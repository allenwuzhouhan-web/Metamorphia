import Foundation

/// Ambient step recorder for Phase E's skill compiler. Tapped by
/// `SemanticExecutor.press` / `type` after a successful action when the
/// user has opted in (Defaults[.workflowRecorderEnabled]). Persists the
/// rolling tail of the last ~500 steps in memory; `SkillCompiler` pulls
/// from here and clusters on a periodic sweep.
///
/// Deliberately distinct from the existing `WorkflowRecorder` (which uses
/// structural signatures for its manual start/stop flow). Phase E keys
/// every step by cross-session `identityKey`, so a compiled skill replays
/// via `RefStabilizer.resolve(key:)` rather than re-walking the AX tree.
public actor SkillRecorder {

    public static let shared = SkillRecorder()

    /// Cap on the in-memory buffer. Steps older than this drop off the
    /// tail when new ones arrive. ~500 covers an hour of moderate use
    /// at 0.15 recorded actions/second (an aggressive estimate).
    private let maxSteps: Int = 500

    private var buffer: [SkillStep] = []

    /// Toggle set from the host app (bootstrap subscribes to
    /// `Defaults.publisher(.workflowRecorderEnabled)`). When false, all
    /// `record(...)` calls no-op — no buffer mutation, no persisted state.
    private var enabled: Bool = false

    public init() {}

    // MARK: - Control

    public func setEnabled(_ value: Bool) {
        enabled = value
        if !enabled { buffer.removeAll() }
    }

    public func isEnabled() -> Bool { enabled }

    /// Append a step. Thread-safe via actor isolation; the executor calls
    /// this from its own actor, so the hop is one message hop.
    public func record(_ step: SkillStep) {
        guard enabled else { return }
        buffer.append(step)
        if buffer.count > maxSteps {
            buffer.removeFirst(buffer.count - maxSteps)
        }
    }

    /// Snapshot of all recorded steps. `SkillCompiler` consumes this each
    /// sweep; reading clears nothing — the compiler decides what to prune
    /// based on its own success criteria.
    public func snapshot() -> [SkillStep] {
        buffer
    }

    /// Explicitly drop the buffer — called after a successful compile so
    /// the same steps don't get re-clustered next sweep, and after the
    /// user disables recording in Settings.
    public func drain() -> [SkillStep] {
        let out = buffer
        buffer.removeAll()
        return out
    }
}
