import Foundation

/// In-memory index of skills. Skills are discovered from one or more on-disk
/// directories at bootstrap. The LLM sees skill *names + descriptions* via
/// `search_skills`, and pulls full bodies on demand via `load_skill`.
///
/// Thread-safe: the index is rebuilt atomically and read under a lock.
public final class SkillRegistry: @unchecked Sendable {
    private var skills: [String: Skill] = [:]
    private let lock = NSLock()

    public init() {}

    /// Load every `SKILL.md` file found under `directory`. Each skill lives in
    /// its own subfolder — the subfolder name is the default skill id (unless
    /// overridden by the frontmatter `name:` field).
    ///
    /// Parse failures are logged but non-fatal — one malformed skill shouldn't
    /// prevent the rest from loading.
    @discardableResult
    public func loadSkills(from directory: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }

        var loaded: [Skill] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard let data = try? Data(contentsOf: skillFile),
                  let markdown = String(data: data, encoding: .utf8) else { continue }

            let folderID = entry.lastPathComponent
            do {
                let skill = try SkillParser.parse(id: folderID, markdown: markdown)
                loaded.append(skill)
            } catch {
                print("[SkillRegistry] Failed to parse \(folderID): \(error)")
            }
        }

        lock.lock()
        for skill in loaded { skills[skill.id] = skill }
        let total = skills.count
        lock.unlock()
        print("[SkillRegistry] Loaded \(loaded.count) skills from \(directory.path) (total: \(total))")
        return loaded.count
    }

    /// Register a skill programmatically. Useful for tests and for skills baked
    /// into the binary without a file on disk.
    public func register(_ skill: Skill) {
        lock.lock(); defer { lock.unlock() }
        skills[skill.id] = skill
    }

    /// All skills, sorted by id.
    public func allSkills() -> [Skill] {
        lock.lock(); defer { lock.unlock() }
        return skills.values.sorted { $0.id < $1.id }
    }

    public func skill(named id: String) -> Skill? {
        lock.lock(); defer { lock.unlock() }
        return skills[id]
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return skills.count
    }

    /// Fuzzy-rank skills against a query. Name matches weigh heavier than
    /// description matches. Returns up to `limit` results, highest-scoring first.
    public func search(query: String, limit: Int = 10) -> [Skill] {
        let tokens = tokens(from: query)
        guard !tokens.isEmpty else { return [] }

        lock.lock()
        let snapshot = Array(skills.values)
        lock.unlock()

        var scored: [(skill: Skill, score: Double)] = []
        for skill in snapshot {
            let idTokens = self.tokens(from: skill.id.replacingOccurrences(of: "-", with: " "))
            let descTokens = self.tokens(from: skill.description)
            var score = 0.0
            for tok in tokens {
                if idTokens.contains(tok) { score += 5.0 }
                else if skill.id.lowercased().contains(tok) { score += 3.0 }
                if descTokens.contains(tok) { score += 2.0 }
                else if skill.description.lowercased().contains(tok) { score += 1.0 }
            }
            if score > 0 { scored.append((skill, score)) }
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit)).map(\.skill)
    }

    private func tokens(from text: String) -> Set<String> {
        let lower = text.lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        return Set(parts)
    }
}
