import Foundation

// MARK: - SkillStep

/// One recorded step in a Phase-E skill. Keyed by a cross-session
/// `identityKey` (from `RefStabilizer.identityKey(for:)`), not the
/// session-scoped `@eN` — that's the whole point of the Phase-A identity
/// system. Without the key a recorded skill is only replayable during the
/// same perception session it was captured in.
///
/// Parameter placeholders: when `paramRef` is non-nil, the step's text
/// payload gets substituted with the caller-supplied argument at runtime
/// instead of the recorded `text`. `paramRef` matches a `SkillParam.name`
/// on the parent `CompiledSkill`.
public struct SkillStep: Codable, Sendable, Hashable {
    public enum Op: String, Codable, Sendable {
        case press
        case type
        case focus
        case pressMenu
        case wait
    }

    public let ts: Date
    public let op: Op
    /// Cross-session durable key that resolves to a ScreenElement via
    /// `RefStabilizer.resolve(key:)` or `ElementResolver`. Nil for ops that
    /// don't target an element (`wait`, `pressMenu`).
    public let identityKey: String?
    public let appBundleID: String?
    /// Free-form parameter bag. For `type` steps the `"text"` key carries
    /// the payload; for `wait` the `"ms"` key; for `pressMenu` the
    /// `"path"` key as a JSON array of strings.
    public let params: [String: String]
    /// When set, the corresponding parameter value for this step's
    /// `text`/`ms`/etc. comes from the caller's arguments instead of
    /// `params`.
    public let paramRef: String?
    /// Hash of the post-state — used by the compiler to detect whether
    /// this step reliably moves the UI forward. High repeat→different
    /// digest signals a real side-effect; low variance signals idempotence.
    public let resultDigest: String?

    public init(
        ts: Date = Date(),
        op: Op,
        identityKey: String?,
        appBundleID: String?,
        params: [String: String] = [:],
        paramRef: String? = nil,
        resultDigest: String? = nil
    ) {
        self.ts = ts
        self.op = op
        self.identityKey = identityKey
        self.appBundleID = appBundleID
        self.params = params
        self.paramRef = paramRef
        self.resultDigest = resultDigest
    }
}

// MARK: - SkillParam

/// Named slot variable on a compiled skill. Captures variance across the
/// recordings that were clustered — e.g., a "Send Slack message" skill
/// recorded with three different message bodies will have one `SkillParam`
/// named `message` that substitutes into the `type` step.
public struct SkillParam: Codable, Sendable, Hashable {
    public let name: String
    public let description: String
    /// 0-based index into `CompiledSkill.steps` whose text field this
    /// parameter replaces at runtime.
    public let sourceStepIndex: Int
    /// Most-common text value observed during recording — used as a default
    /// when the caller doesn't supply an argument, and as a fallback for
    /// the LLM-facing tool description.
    public let defaultValue: String?

    public init(name: String, description: String, sourceStepIndex: Int, defaultValue: String?) {
        self.name = name
        self.description = description
        self.sourceStepIndex = sourceStepIndex
        self.defaultValue = defaultValue
    }
}

// MARK: - CompiledSkill

/// A learned workflow ready to register as a dynamic `ToolDefinition`.
/// Serialized into the existing `workflows` SQLite table's `steps_json`
/// column — no schema migration needed. The table's `name` + `id` +
/// `app_bundle_id` carry the top-level metadata.
public struct CompiledSkill: Codable, Sendable {
    public let id: String
    public var name: String
    public var description: String
    public let parameters: [SkillParam]
    public let steps: [SkillStep]
    public let createdAt: Date
    /// Observations the compiler saw when it clustered this skill. Used
    /// by the correction flow to judge whether a broken skill should
    /// auto-disable vs. retry.
    public var observedRepetitions: Int
    public var successCount: Int
    public var failureCount: Int
    /// When true, the skill is excluded from the dynamic tool catalog —
    /// set by the correction flow after repeated failures.
    public var disabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String,
        parameters: [SkillParam],
        steps: [SkillStep],
        createdAt: Date = Date(),
        observedRepetitions: Int = 1,
        successCount: Int = 0,
        failureCount: Int = 0,
        disabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
        self.steps = steps
        self.createdAt = createdAt
        self.observedRepetitions = observedRepetitions
        self.successCount = successCount
        self.failureCount = failureCount
        self.disabled = disabled
    }

    /// JSON serialization for the `steps_json` column. Keeps the full
    /// `CompiledSkill` — parameters + steps + telemetry — in one blob
    /// so a `listWorkflows` / `saveWorkflow` round-trip reconstructs
    /// everything without schema additions.
    public func serialized() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    public static func deserialize(_ json: String) -> CompiledSkill? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(CompiledSkill.self, from: data)
    }
}
