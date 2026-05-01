import Foundation

// MARK: - Protocol

public protocol ConversationStore: Sendable {
    /// Persist the latest run's full message thread for this session.
    /// Overwrites prior content for the same sessionId.
    func save(sessionId: String, messages: [ChatMessage]) async throws
    /// Load messages for a session, or empty array if none exist.
    func load(sessionId: String) async throws -> [ChatMessage]
    /// Remove a session's stored thread.
    func delete(sessionId: String) async throws
    /// All known session IDs, most-recently-modified first.
    func listSessions() async throws -> [String]
}

// MARK: - File-backed implementation

/// Persists each session as a JSON file under `baseURL/<sessionId>.json`.
/// Writes are atomic (write-to-tmp then rename) so partial writes never corrupt state.
public actor FileConversationStore: ConversationStore {

    // Wrapper so we can version the on-disk schema later without breaking existing files.
    private struct SessionEnvelope: Codable {
        let savedAt: Date
        let messages: [ChatMessage]
    }

    private let baseURL: URL

    public init(baseURL: URL? = nil) {
        if let url = baseURL {
            self.baseURL = url
        } else {
            let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.baseURL = (appSupport ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Metamorphia/conversations", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    }

    // MARK: - ConversationStore

    public func save(sessionId: String, messages: [ChatMessage]) async throws {
        let dest = fileURL(for: sessionId)
        let tmp = dest.appendingPathExtension("tmp")
        let envelope = SessionEnvelope(savedAt: Date(), messages: messages)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: tmp, options: .atomic)
        // Atomic rename — avoids partial reads if a crash happens mid-write.
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }

    public func load(sessionId: String) async throws -> [ChatMessage] {
        let url = fileURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(SessionEnvelope.self, from: data)
        return envelope.messages
    }

    public func delete(sessionId: String) async throws {
        let url = fileURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func listSessions() async throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )
        let jsonFiles = contents.filter { $0.pathExtension == "json" }
        // Sort newest-first by modification date.
        let sorted = try jsonFiles.sorted {
            let lhs = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhs = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        return sorted.map { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: - Helpers

    /// Sanitizes sessionId so it is safe as a filename — non-alphanumeric/dash/underscore chars become `_`.
    private func sanitize(_ sessionId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(sessionId.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "_"
        })
    }

    private func fileURL(for sessionId: String) -> URL {
        baseURL.appendingPathComponent(sanitize(sessionId) + ".json")
    }
}
