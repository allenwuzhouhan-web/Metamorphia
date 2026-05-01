import XCTest
@testable import MetamorphiaAgentKit

final class SkillRegistryTests: XCTestCase {
    func testParseWithFrontmatter() throws {
        let md = """
        ---
        name: test-skill
        description: A tiny test skill used to verify the parser.
        emoji: 🧪
        ---

        # Test Skill

        Body content here.
        """
        let skill = try SkillParser.parse(id: "folder-id", markdown: md)
        XCTAssertEqual(skill.id, "test-skill", "frontmatter name: should override folder id")
        XCTAssertEqual(skill.description, "A tiny test skill used to verify the parser.")
        XCTAssertTrue(skill.body.contains("Body content here"))
        XCTAssertFalse(skill.body.contains("---"), "frontmatter should be stripped from body")
        XCTAssertEqual(skill.frontmatter["emoji"], "🧪")
    }

    func testParseWithoutFrontmatterFallsBackToFirstHeading() throws {
        let md = """
        # My Heading

        Body goes here.
        """
        let skill = try SkillParser.parse(id: "my-skill", markdown: md)
        XCTAssertEqual(skill.id, "my-skill")
        XCTAssertEqual(skill.description, "My Heading")
    }

    func testParseThrowsOnMissingDescription() {
        let md = "no frontmatter and no heading, just prose.\n"
        XCTAssertThrowsError(try SkillParser.parse(id: "x", markdown: md)) { err in
            XCTAssertEqual(err as? SkillParseError, .missingDescription(id: "x"))
        }
    }

    func testFrontmatterSkipsNestedYAMLBlocks() throws {
        let md = """
        ---
        name: nested
        description: Parser should ignore nested objects.
        metadata:
          nested:
            key: value
        homepage: https://example.com
        ---

        # Body

        Content.
        """
        let skill = try SkillParser.parse(id: "nested", markdown: md)
        XCTAssertEqual(skill.description, "Parser should ignore nested objects.")
        XCTAssertEqual(skill.frontmatter["homepage"], "https://example.com")
        XCTAssertNil(skill.frontmatter["key"], "nested keys must not leak into top-level frontmatter")
    }

    func testSearchRanksNameMatchesAboveDescription() {
        let registry = SkillRegistry()
        registry.register(Skill(id: "music", description: "Control playback.", body: "..."))
        registry.register(Skill(id: "calendar", description: "Schedule music rehearsal events.", body: "..."))
        registry.register(Skill(id: "notes", description: "Write things down.", body: "..."))

        let results = registry.search(query: "music")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.id, "music", "id match should outrank description match")
    }

    func testSearchHandlesHyphenatedIds() {
        let registry = SkillRegistry()
        registry.register(Skill(id: "apple-notes", description: "Create Apple Notes.", body: "..."))
        registry.register(Skill(id: "things-mac", description: "Add Things todos.", body: "..."))

        let notesHits = registry.search(query: "apple notes")
        XCTAssertEqual(notesHits.first?.id, "apple-notes")

        let todoHits = registry.search(query: "things")
        XCTAssertEqual(todoHits.first?.id, "things-mac")
    }

    func testLoadSkillsFromDirectoryParsesEachSkillMd() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("SkillRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try """
        ---
        description: Alpha skill.
        ---

        # Alpha

        body
        """.write(to: tmp.appendingPathComponent("alpha/SKILL.md"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("beta"), withIntermediateDirectories: true)
        try """
        ---
        description: Beta skill.
        ---

        # Beta

        body
        """.write(to: tmp.appendingPathComponent("beta/SKILL.md"), atomically: true, encoding: .utf8)

        // A folder with no SKILL.md — should be silently skipped.
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let registry = SkillRegistry()
        let loaded = registry.loadSkills(from: tmp)
        XCTAssertEqual(loaded, 2)
        XCTAssertEqual(registry.count, 2)
        XCTAssertNotNil(registry.skill(named: "alpha"))
        XCTAssertNotNil(registry.skill(named: "beta"))
    }
}
