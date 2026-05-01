import Foundation
import MetamorphiaAgentKit

/// Surface the agent's skill library to the LLM. `search_skills` returns
/// candidate skill ids + descriptions; `load_skill` returns the full markdown
/// body so the agent can follow the playbook.
///
/// Two-step design (search → load) mirrors `DeferredToolMiddleware` for tools:
/// keeps the system prompt small while making the full library reachable.
public struct SearchSkillsTool: ToolDefinition {
    public let name = "search_skills"
    public let description = "Search the skill library for a how-to guide on accomplishing a task (e.g., 'create reminder', 'control music', 'screenshot a window'). Returns matching skill ids + one-line descriptions. Follow up with `load_skill` to read the full guide."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "What you want to accomplish (e.g., 'add a note to apple notes', 'play a song on spotify', 'lock the screen')."),
            "limit": JSONSchema.integer(description: "Max results (default 8)", minimum: 1, maximum: 25),
        ], required: ["query"])
    }

    private let registry: SkillRegistry

    public init(registry: SkillRegistry) {
        self.registry = registry
    }

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let limit = optionalInt("limit", from: args) ?? 8

        let matches = registry.search(query: query, limit: limit)
        guard !matches.isEmpty else {
            return "No skills matched '\(query)'. The library currently has \(registry.count) skill(s). Try `search_skills` with a different query, or proceed without a skill."
        }
        var out = "Skills matching '\(query)':\n"
        for skill in matches {
            out += "- **\(skill.id)** — \(skill.description)\n"
        }
        out += "\nCall `load_skill` with one of these ids to read the full guide."
        return out
    }
}

public struct LoadSkillTool: ToolDefinition {
    public let name = "load_skill"
    public let description = "Load the full markdown body of a skill by id (discovered via `search_skills`). Returns step-by-step guidance on how to accomplish the task using available tools."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "id": JSONSchema.string(description: "Skill id, e.g., 'apple-notes'. Get valid ids from `search_skills`."),
        ], required: ["id"])
    }

    private let registry: SkillRegistry

    public init(registry: SkillRegistry) {
        self.registry = registry
    }

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let id = try requiredString("id", from: args)

        guard let skill = registry.skill(named: id) else {
            let suggestions = registry.search(query: id, limit: 3)
            if suggestions.isEmpty {
                return "Skill '\(id)' not found. Use `search_skills` to discover available skills."
            }
            let suggestionList = suggestions.map { "  - \($0.id)" }.joined(separator: "\n")
            return "Skill '\(id)' not found. Did you mean:\n\(suggestionList)"
        }
        return skill.body + "\n\n---\nThis was instructional content, not a completion. Proceed to carry out the user's request by calling the tools described above. Do not stop here."
    }
}
