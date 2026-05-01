import Foundation

/// Executes a `CompiledSkill` end-to-end. Each step resolves its
/// `identityKey` via `RefStabilizer.resolve(key:)` + `ElementResolver`,
/// then dispatches through `SemanticExecutor.shared.press` / `type` so the
/// full safety stack (FeedbackLoopSuppressor, PerceptionBudget, AX-fail
/// telemetry) applies automatically.
///
/// Parameter binding: a step's `paramRef` looks up the argument under the
/// same name in `arguments`. Unresolved slots fall back to the
/// `SkillParam.defaultValue` captured at compile time.
///
/// Failure policy: on the first step that can't resolve, `run` logs a
/// `FailureLog` entry (so the correction flow has something to surface),
/// increments `CompiledSkill.failureCount`, and returns an error. No
/// silent half-completions.
public actor SkillRunner {

    public static let shared = SkillRunner()

    public struct RunResult: Sendable {
        public let skillID: String
        public let stepsCompleted: Int
        public let totalSteps: Int
        public let latencyMs: Int
        public let succeeded: Bool
        public let error: String?
    }

    public enum RunError: Error, CustomStringConvertible {
        case unresolvedStep(index: Int, identityKey: String)
        case stepFailed(index: Int, underlying: String)
        case missingParameter(name: String)
        case noScreenMap

        public var description: String {
            switch self {
            case .unresolvedStep(let i, let key):
                return "step \(i) unresolved (key: \(key))"
            case .stepFailed(let i, let reason):
                return "step \(i) failed: \(reason)"
            case .missingParameter(let name):
                return "missing required parameter '\(name)'"
            case .noScreenMap:
                return "no ScreenMap available"
            }
        }
    }

    public init() {}

    @discardableResult
    public func run(
        _ skill: CompiledSkill,
        arguments: [String: String] = [:]
    ) async -> RunResult {
        let started = Date()
        var completed = 0

        let stabilizer = PerceptionPipeline.shared.refStabilizer

        // Resolve all identity keys up front against a single captured
        // ScreenMap. This keeps the between-steps recapture cost away from
        // the skill hot path — the SemanticExecutor's CDP / cursor
        // fallback chain still handles per-step drift.
        let map = await DefaultComputerPerception.shared.capture(
            forceOCR: false, appFilter: nil, ocrOverride: .skip
        )

        for (i, step) in skill.steps.enumerated() {
            do {
                try await runStep(
                    index: i, step: step, skill: skill,
                    arguments: arguments, map: map, stabilizer: stabilizer
                )
                completed += 1
            } catch {
                // Record failure and stop.
                let reason = "\(error)"
                ElementDatabase.shared.logFailure(
                    workflowID: skill.id,
                    stepIndex: i,
                    expectedStateJSON: nil,
                    actualStateJSON: nil,
                    elementRef: step.identityKey,
                    actionAttempted: step.op.rawValue,
                    errorDescription: reason,
                    appBundleID: step.appBundleID
                )
                return RunResult(
                    skillID: skill.id,
                    stepsCompleted: completed,
                    totalSteps: skill.steps.count,
                    latencyMs: elapsedMs(from: started),
                    succeeded: false,
                    error: reason
                )
            }
        }

        return RunResult(
            skillID: skill.id,
            stepsCompleted: completed,
            totalSteps: skill.steps.count,
            latencyMs: elapsedMs(from: started),
            succeeded: true,
            error: nil
        )
    }

    // MARK: - Per-step

    private func runStep(
        index: Int,
        step: SkillStep,
        skill: CompiledSkill,
        arguments: [String: String],
        map: ScreenMap,
        stabilizer: RefStabilizer
    ) async throws {
        switch step.op {
        case .wait:
            let ms = Int(step.params["ms"] ?? "0") ?? 0
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(5_000, ms))) * 1_000_000)

        case .pressMenu:
            // Menu paths don't go through identity keys — they replay by
            // the exact `[String]` path stored in params["path"]. Deferred
            // to follow-up; first-ship skills don't emit menu steps.
            throw RunError.stepFailed(index: index, underlying: "pressMenu unsupported in first-ship runner")

        case .press, .focus:
            let ref = try await resolveRef(
                step: step, index: index, map: map, stabilizer: stabilizer
            )
            do {
                _ = try await SemanticExecutor.shared.press(
                    ref: ref,
                    identityKey: step.identityKey,
                    in: map,
                    stabilizer: stabilizer
                )
            } catch {
                throw RunError.stepFailed(index: index, underlying: "\(error)")
            }

        case .type:
            let ref = try await resolveRef(
                step: step, index: index, map: map, stabilizer: stabilizer
            )
            let text = try resolveText(step: step, skill: skill, arguments: arguments)
            do {
                _ = try await SemanticExecutor.shared.type(
                    ref: ref,
                    text: text,
                    pressEnter: false,
                    clearFirst: false,
                    in: map,
                    stabilizer: stabilizer
                )
            } catch {
                throw RunError.stepFailed(index: index, underlying: "\(error)")
            }
        }
    }

    private func resolveRef(
        step: SkillStep,
        index: Int,
        map: ScreenMap,
        stabilizer: RefStabilizer
    ) async throws -> ElementRef {
        guard let key = step.identityKey else {
            throw RunError.unresolvedStep(index: index, identityKey: "(nil)")
        }
        if let ref = stabilizer.resolve(key: key) {
            return ref
        }
        // The stabilizer didn't see this key in the current or previous
        // snapshot. Try the resolver's fuzzy cascade as a last-ditch
        // — identity-key re-bind inside resolve() gets one more shot with
        // a fresh map snapshot.
        let resolution = ElementResolver.resolve(
            ref: nil,
            identityKey: key,
            label: nil,
            preferredRole: nil,
            nearPoint: nil,
            in: map,
            stabilizer: stabilizer,
            db: nil
        )
        switch resolution {
        case .success(let r): return r.element.ref
        case .failure: throw RunError.unresolvedStep(index: index, identityKey: key)
        }
    }

    private func resolveText(
        step: SkillStep,
        skill: CompiledSkill,
        arguments: [String: String]
    ) throws -> String {
        if let ref = step.paramRef {
            if let supplied = arguments[ref], !supplied.isEmpty {
                return supplied
            }
            if let param = skill.parameters.first(where: { $0.name == ref }),
               let fallback = param.defaultValue {
                return fallback
            }
            throw RunError.missingParameter(name: ref)
        }
        return step.params["text"] ?? ""
    }

    private func elapsedMs(from start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
