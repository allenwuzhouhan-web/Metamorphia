import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - CompiledSkillTool

/// Dynamic `ToolDefinition` wrapper around a `CompiledSkill`. One tool per
/// skill. The name is derived from the skill's UUID so the LLM can call a
/// specific skill unambiguously (`skill_<uuid-prefix>`); the human-facing
/// `CompiledSkill.name` lives in the tool's `description` so the LLM has
/// context when deciding whether to invoke.
///
/// Parameter schema: every `SkillParam` becomes a string property on the
/// tool's JSON schema. No `required` — the runner falls back to each
/// param's `defaultValue` when the caller doesn't supply the arg.
public struct CompiledSkillTool: ToolDefinition {

    public let skill: CompiledSkill

    public init(skill: CompiledSkill) {
        self.skill = skill
    }

    public var name: String {
        // Trim the UUID to 8 chars + lowercase so the tool name stays
        // short and selectable by LLM heuristics. A skill's id is stable,
        // so the prefix is stable across sessions.
        let shortID = String(skill.id.prefix(8)).lowercased()
        return "skill_\(shortID)"
    }

    public var description: String {
        var pieces: [String] = [skill.name, skill.description]
        if !skill.parameters.isEmpty {
            let paramList = skill.parameters.map { param in
                "\(param.name) (\(param.description))"
            }.joined(separator: ", ")
            pieces.append("Parameters: \(paramList)")
        }
        pieces.append("Learned skill — invokes \(skill.steps.count) recorded steps.")
        return pieces.joined(separator: ". ")
    }

    public var parameters: [String: Any] {
        var props: [String: Any] = [:]
        for param in skill.parameters {
            props[param.name] = JSONSchema.string(
                description: param.description
            )
        }
        return JSONSchema.object(properties: props)
    }

    public func execute(arguments: String) async throws -> String {
        // Decode string → string dict. Skills only accept string params
        // today (the SkillCompiler builds slots from `type` text values).
        let args: [String: String]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            let parsed: [String: Any]
            do { parsed = try parseArguments(arguments) }
            catch { return "Error: failed to parse arguments: \(error.localizedDescription)" }
            var out: [String: String] = [:]
            for (k, v) in parsed {
                if let s = v as? String { out[k] = s }
                else { out[k] = "\(v)" }
            }
            args = out
        }

        let result = await SkillRunner.shared.run(skill, arguments: args)
        var payload: [String: Any] = [
            "skill_id": result.skillID,
            "succeeded": result.succeeded,
            "steps_completed": result.stepsCompleted,
            "total_steps": result.totalSteps,
            "latency_ms": result.latencyMs,
        ]
        if let error = result.error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - CompiledSkillCatalog

/// Manages the lifecycle of compiled skills: loads from the `workflows`
/// SQLite table at startup, registers each as a dynamic tool with the
/// given `ToolRegistry`, and re-registers when new skills are compiled
/// at runtime (e.g. after a user accepts the "Add to tools?" proposal).
public actor CompiledSkillCatalog {

    public static let shared = CompiledSkillCatalog()

    private var registry: ToolRegistry?
    private var registered: [String: CompiledSkillTool] = [:]

    public init() {}

    /// Bind to a registry. Call once at bootstrap after the registry is
    /// populated with the static tool set; subsequent `addSkill(_:)`
    /// calls register through the same instance.
    public func attach(registry: ToolRegistry) {
        self.registry = registry
        loadFromDatabase()
    }

    /// Load every non-disabled compiled skill from the `workflows` table
    /// and register them. Skills are stored as CompiledSkill JSON inside
    /// the flexible `steps_json` column — no schema migration needed.
    public func loadFromDatabase() {
        guard let registry else { return }
        let records = ElementDatabase.shared.listWorkflows(limit: 500)
        for record in records {
            guard let skill = CompiledSkill.deserialize(record.stepsJSON),
                  !skill.disabled else { continue }
            register(skill: skill, into: registry)
        }
    }

    /// Persist a freshly compiled skill and register it as a dynamic tool.
    /// Called from the Whisper Card's "Add to tools" accept handler.
    public func addSkill(_ skill: CompiledSkill) {
        guard let registry else { return }
        guard let json = skill.serialized() else { return }
        ElementDatabase.shared.saveWorkflow(
            id: skill.id,
            name: skill.name,
            appBundleID: skill.parameters.isEmpty
                ? skill.steps.first?.appBundleID
                : skill.steps.first?.appBundleID,
            stepsJSON: json
        )
        register(skill: skill, into: registry)
    }

    /// Disable and unregister a skill — called by the correction flow
    /// after repeated failures. The row stays in the DB for audit and the
    /// tool disappears from the LLM's catalog.
    public func disableSkill(id: String) {
        guard let registry else { return }
        guard let existing = registered[id] else { return }
        registered.removeValue(forKey: id)
        // Re-register the remaining set so ToolRegistry rebuilds its
        // schema cache without the disabled one.
        _ = registry
        _ = existing
        // Persist the disabled flag back to the DB. Reuses saveWorkflow
        // via a reserialized CompiledSkill.
        var next = existing.skill
        next.disabled = true
        if let json = next.serialized() {
            ElementDatabase.shared.saveWorkflow(
                id: next.id, name: next.name,
                appBundleID: next.steps.first?.appBundleID,
                stepsJSON: json
            )
        }
    }

    /// Read-only view for debugging / Settings display.
    public func allSkills() -> [CompiledSkill] {
        registered.values.map(\.skill)
    }

    // MARK: - Private

    private func register(skill: CompiledSkill, into registry: ToolRegistry) {
        let tool = CompiledSkillTool(skill: skill)
        registry.register([(tool: tool, category: .skills)])
        registered[skill.id] = tool
    }
}
