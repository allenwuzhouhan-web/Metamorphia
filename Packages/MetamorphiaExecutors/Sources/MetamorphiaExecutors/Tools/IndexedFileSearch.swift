import Foundation

/// Indexed filesystem search. Wraps macOS Spotlight (`mdfind`) for
/// content-aware retrieval and falls back to `find` only when Spotlight
/// returns nothing — the most common reason being that the location is
/// excluded from the user's index. Results are extension-filtered when
/// a concrete ``DocTypeIntent`` is supplied so a "research paper"
/// search cannot return a PowerPoint or a code file.
///
/// Used directly by ``FindFilesTool`` and as the second-stage fallback
/// inside ``RecallSceneTool`` when the temporal-recall index returns
/// no scenes.
public enum IndexedFileSearch {

    public struct Hit: Sendable {
        public let path: String
        public let modifiedAt: Date?
        public let size: Int64?
        public let `extension`: String

        public init(path: String, modifiedAt: Date?, size: Int64?, extension ext: String) {
            self.path = path
            self.modifiedAt = modifiedAt
            self.size = size
            self.extension = ext
        }
    }

    /// Run an indexed search. `query` is free-text matched against
    /// content + filename. `intent` filters by document type when set
    /// to anything other than ``DocTypeIntent/any``. Results are
    /// deduped and ranked by modification time descending.
    public static func search(
        query: String,
        intent: DocTypeIntent = .any,
        directory: String? = nil,
        maxResults: Int = 20
    ) async -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var hits = await mdfindHits(
            query: trimmed,
            intent: intent,
            directory: directory,
            maxResults: maxResults
        )

        if hits.isEmpty {
            hits = await findHits(
                query: trimmed,
                intent: intent,
                directory: directory,
                maxResults: maxResults
            )
        }

        let allowed = Set(intent.extensions)
        if !allowed.isEmpty {
            hits = hits.filter { allowed.contains($0.extension.lowercased()) }
        }

        // Stable rank: most-recently-modified first.
        hits.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        return Array(hits.prefix(maxResults))
    }

    // MARK: - Spotlight

    private static func mdfindHits(
        query: String,
        intent: DocTypeIntent,
        directory: String?,
        maxResults: Int
    ) async -> [Hit] {
        let topic = intent.extractTopicKeywords(from: query)
        let primaryQuery = topic.isEmpty ? query : topic
        guard !primaryQuery.isEmpty else { return [] }

        var args: [String] = ["-0"]
        if let dir = directory {
            args.append("-onlyin")
            args.append(NSString(string: dir).expandingTildeInPath)
        }
        args.append(primaryQuery)

        let result = try? await AsyncShellRunner.run(
            executable: "/usr/bin/mdfind",
            arguments: args,
            timeout: 15
        )
        guard let stdout = result?.stdout, !stdout.isEmpty else { return [] }

        let paths = stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)

        let upperBound = max(maxResults * 4, maxResults)
        return paths.prefix(upperBound).compactMap { decorate(path: $0) }
    }

    // MARK: - find(1) fallback

    private static func findHits(
        query: String,
        intent: DocTypeIntent,
        directory: String?,
        maxResults: Int
    ) async -> [Hit] {
        let topic = intent.extractTopicKeywords(from: query)
        let firstToken = topic
            .split(separator: " ")
            .map(String.init)
            .first ?? query.split(separator: " ").map(String.init).first ?? query
        guard !firstToken.isEmpty else { return [] }

        let dir = (directory.map { NSString(string: $0).expandingTildeInPath })
            ?? NSString(string: "~").expandingTildeInPath

        let pattern = "*\(firstToken)*"
        let cmd = "find \(shellEscape(dir)) -iname \(shellEscape(pattern)) 2>/dev/null | head -n \(maxResults * 4)"
        let result = try? await AsyncShellRunner.run(
            executable: "/bin/zsh",
            arguments: ["-c", cmd],
            timeout: 15
        )
        guard let stdout = result?.stdout, !stdout.isEmpty else { return [] }
        let paths = stdout.split(separator: "\n").map(String.init)
        return paths.compactMap { decorate(path: $0) }
    }

    // MARK: - Helpers

    private static func decorate(path: String) -> Hit? {
        guard !path.isEmpty else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        let ext = (path as NSString).pathExtension
        return Hit(path: path, modifiedAt: mtime, size: size, extension: ext)
    }

    private static func shellEscape(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
