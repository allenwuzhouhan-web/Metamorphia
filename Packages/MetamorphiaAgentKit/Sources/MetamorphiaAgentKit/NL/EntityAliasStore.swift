import Foundation

// MARK: - Alias value

private struct CanonicalAlias: Codable, Sendable {
    let canonicalName: String
    let type: EntityType
}

// MARK: - EntityAliasStore

/// Persistent map from lowercase surface forms to canonical entity names.
///
/// Stored at `~/Library/Application Support/Metamorphia/entity-aliases.json`.
/// Starts empty and grows as the app learns from user turns. Evicts the
/// least-recently-used entries when the cap of 5000 is exceeded.
///
/// Writes are debounced (0.5s) and atomic — identical idiom to `WatchlistStore`.
public actor EntityAliasStore {

    // MARK: - Private types

    private struct AliasEntry: Codable, Sendable {
        let surface: String          // lowercased key (also stored for LRU reconstruction)
        var alias: CanonicalAlias
        var lastUsed: Date
    }

    // MARK: - State

    private var entries: [String: AliasEntry] = [:]   // key = lowercased surface form
    private let maxAliases: Int

    private let storageURL: URL
    private var pendingWrite: Task<Void, Never>?
    private let writeDebounce: TimeInterval

    // MARK: - Lifecycle

    public init(location: URL? = nil, maxAliases: Int = 5000, writeDebounce: TimeInterval = 0.5) {
        self.maxAliases = maxAliases
        self.writeDebounce = writeDebounce
        if let loc = location {
            self.storageURL = loc
        } else {
            self.storageURL = URL.applicationSupportDirectory
                .appendingPathComponent("Metamorphia", isDirectory: true)
                .appendingPathComponent("entity-aliases.json")
        }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.entries = Self.readFromDisk(at: storageURL)
    }

    // MARK: - Public API

    /// Return the canonical name for this surface form + type.
    /// When no alias is known, returns `surface.lowercased()`.
    public func canonicalize(surface: String, type: EntityType) -> String {
        let key = surface.lowercased()
        if var entry = entries[key] {
            entry.lastUsed = Date()
            entries[key] = entry
            return entry.alias.canonicalName
        }
        return key
    }

    /// Teach the store that `surface` maps to `canonical` for `type`.
    /// No-op when the alias is already correct.
    public func learn(surface: String, canonical: String, type: EntityType) {
        let key = surface.lowercased()
        let alias = CanonicalAlias(canonicalName: canonical, type: type)
        entries[key] = AliasEntry(surface: key, alias: alias, lastUsed: Date())
        evictIfNeeded()
        scheduleWrite()
    }

    /// Current number of stored aliases.
    public func aliasCount() -> Int {
        entries.count
    }

    // MARK: - LRU eviction

    private func evictIfNeeded() {
        guard entries.count > maxAliases else { return }
        // Sort by lastUsed ascending; drop the oldest until within cap.
        let sorted = entries.values.sorted { $0.lastUsed < $1.lastUsed }
        let evictCount = entries.count - maxAliases
        for entry in sorted.prefix(evictCount) {
            entries.removeValue(forKey: entry.surface)
        }
    }

    // MARK: - Persistence

    private static func readFromDisk(at url: URL) -> [String: AliasEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([AliasEntry].self, from: data)
            return Dictionary(loaded.map { ($0.surface, $0) }, uniquingKeysWith: { _, new in new })
        } catch {
            print("[EntityAliasStore] load failed: \(error)")
            return [:]
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let snapshot = Array(entries.values)
        let url = storageURL
        let debounce = writeDebounce
        pendingWrite = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("[EntityAliasStore] save failed: \(error)")
            }
        }
    }
}
