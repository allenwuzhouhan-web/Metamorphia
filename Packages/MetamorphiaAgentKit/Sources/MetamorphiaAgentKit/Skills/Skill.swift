import Foundation

/// A Skill is a markdown document that teaches the agent how to accomplish a
/// class of tasks using the tools it already has. Skills are **deferred
/// knowledge** — discovered via `search_skills`, loaded on demand via
/// `load_skill`. They don't occupy the system prompt.
///
/// Inspired by the SKILL.md pattern popularized by Anthropic's Skills and the
/// openclaw project (MIT-licensed). Metamorphia's twist: skills reference Metamorphia's
/// native primitives (AppleScript, shell, web, clipboard) rather than assuming
/// third-party CLI binaries are installed.
public struct Skill: Sendable, Hashable {
    /// Stable identifier. Derived from the folder name or the frontmatter
    /// `name:` field. Kebab-case by convention.
    public let id: String

    /// One-line description of when this skill applies. Shown to the LLM during
    /// `search_skills`; used for fuzzy ranking.
    public let description: String

    /// Full markdown body (frontmatter stripped). This is what the LLM receives
    /// when it calls `load_skill`.
    public let body: String

    /// Raw frontmatter key/value pairs, for callers that want to inspect metadata
    /// (emoji, os, requirements). Kept as `String` — structured access isn't
    /// needed by the agent itself.
    public let frontmatter: [String: String]

    public init(id: String, description: String, body: String, frontmatter: [String: String] = [:]) {
        self.id = id
        self.description = description
        self.body = body
        self.frontmatter = frontmatter
    }
}

public enum SkillParseError: Error, Equatable {
    case missingDescription(id: String)
    case emptyBody(id: String)
}

public enum SkillParser {
    /// Parse a SKILL.md document. Frontmatter is optional — if absent, the
    /// first `# Heading` line becomes the description and the whole document
    /// becomes the body.
    ///
    /// The frontmatter parser is intentionally minimal: it supports top-level
    /// `key: value` pairs only. Nested YAML objects (e.g., openclaw's
    /// `metadata.openclaw.install[]`) are captured as the raw block string so
    /// round-tripping works, but we don't try to parse them structurally —
    /// Metamorphia doesn't need those fields.
    public static func parse(id: String, markdown: String) throws -> Skill {
        var frontmatter: [String: String] = [:]
        var body = markdown

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("---") {
            let afterFirstFence = trimmed.dropFirst(3)
            if let endRange = afterFirstFence.range(of: "\n---") {
                let fmBlock = String(afterFirstFence[..<endRange.lowerBound])
                frontmatter = parseFrontmatter(fmBlock)
                let bodyStart = afterFirstFence.index(endRange.upperBound, offsetBy: 0)
                body = String(afterFirstFence[bodyStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let description = frontmatter["description"]
            ?? firstHeading(in: body)
            ?? ""

        guard !description.isEmpty else {
            throw SkillParseError.missingDescription(id: id)
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillParseError.emptyBody(id: id)
        }

        let resolvedId = frontmatter["name"]?.trimmingCharacters(in: .whitespaces) ?? id

        return Skill(id: resolvedId, description: description, body: body, frontmatter: frontmatter)
    }

    private static func parseFrontmatter(_ block: String) -> [String: String] {
        var out: [String: String] = [:]
        var depth = 0
        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            // Track indentation depth so we ignore nested keys — we only want
            // top-level `key: value` pairs.
            let leading = line.prefix(while: { $0 == " " }).count
            if leading > 0 { continue }

            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }

            // Skip structural YAML markers that suggest we're inside a block
            // scalar the simple parser can't handle.
            if trimmedLine.hasSuffix(":") { depth += 1; continue }
            if depth > 0 && (trimmedLine.hasPrefix("{") || trimmedLine.hasPrefix("[")) { continue }

            guard let sep = trimmedLine.firstIndex(of: ":") else { continue }
            let key = String(trimmedLine[..<sep]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmedLine[trimmedLine.index(after: sep)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty && !value.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    private static func firstHeading(in markdown: String) -> String? {
        for rawLine in markdown.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
