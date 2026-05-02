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
        return render(skill: skill) + "\n\n---\nThis was instructional content, not a completion. Proceed to carry out the user's request by calling the tools described above. Do not stop here."
    }

    private func render(skill: Skill) -> String {
        var out = skill.body
        guard let directory = skill.sourceDirectory else { return out }

        let supportFiles = listSupportFiles(in: directory)
        if !supportFiles.isEmpty {
            out += "\n\n---\n## Metamorphia Skill Support Files\n"
            out += "This skill was loaded from `\(directory.path)`. When commands reference `scripts/...`, `templates/...`, or adjacent guides, use paths relative to that directory or absolute paths under that directory.\n\n"
            out += "Bundled support files:\n"
            for file in supportFiles {
                out += "- `\(file)`\n"
            }
        }

        let adjacentMarkdown = supportFiles.filter {
            $0.hasSuffix(".md") && !$0.contains("/")
        }.sorted()

        for relativePath in adjacentMarkdown {
            let url = directory.appendingPathComponent(relativePath)
            guard let markdown = try? String(contentsOf: url, encoding: .utf8),
                  !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            out += "\n\n---\n## Bundled Guide: \(relativePath)\n\n"
            out += markdown
        }

        return out
    }

    private func listSupportFiles(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            guard relative != "SKILL.md" else { continue }
            files.append(relative)
        }
        return files.sorted()
    }
}
