/*
 * Metamorphia
 * User-extensible denylist for app-focus observation.
 *
 * Coder A's AppFocusSensor hard-codes password-manager bundle IDs.
 * This store holds the *user-extensible* layer that sits alongside it.
 * The sensor calls `AppFocusDenylistStore.shared.contains(bundleID:)` before
 * emitting a window title.
 *
 * Persistence: plain JSON at
 *   ~/Library/Application Support/Metamorphia/app-focus-denylist.json
 * Writes are debounced 2 s via a DispatchWorkItem cancel pattern (same as
 * QueryPatternLearner and WatchlistStore).
 */

import Foundation
import Combine

// MARK: - AppFocusDenylistStore

@MainActor
public final class AppFocusDenylistStore: ObservableObject {

    public static let shared = AppFocusDenylistStore()

    @Published public private(set) var entries: [DenylistEntry] = []

    // MARK: - DenylistEntry

    public struct DenylistEntry: Codable, Identifiable, Hashable {
        public let id: UUID
        /// Normalized (lowercased) bundle ID.
        public let bundleID: String
        public let addedAt: Date

        public init(id: UUID = UUID(), bundleID: String, addedAt: Date = .now) {
            self.id = id
            self.bundleID = bundleID.lowercased()
            self.addedAt = addedAt
        }
    }

    // MARK: - Private state

    private let storageURL: URL
    private let writeQueue = DispatchQueue(label: "AppFocusDenylistStore.write", qos: .utility)
    private static let writeDebounce: TimeInterval = 2.0
    private var pendingWrite: DispatchWorkItem?

    // MARK: - Init

    public init(storageURL: URL = AppFocusDenylistStore.defaultStorageURL) {
        self.storageURL = storageURL
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        loadFromDisk()
    }

    public nonisolated static var defaultStorageURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Metamorphia", isDirectory: true)
            .appendingPathComponent("app-focus-denylist.json")
    }

    // MARK: - Mutations

    /// Add a bundle ID to the denylist. Normalizes to lowercase; silently
    /// ignores duplicates (case-insensitive match).
    public func add(bundleID: String) {
        let normalized = bundleID.lowercased()
        guard !entries.contains(where: { $0.bundleID == normalized }) else { return }
        entries.append(DenylistEntry(bundleID: normalized))
        scheduleWrite()
    }

    /// Remove an entry by its stable ID.
    public func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        scheduleWrite()
    }

    // MARK: - Query

    /// Returns `true` if `bundleID` is in the user denylist.
    /// Case-insensitive: bundle IDs are normalized to lowercase on insert, and
    /// the lookup mirrors that normalization.
    public func contains(bundleID: String) -> Bool {
        let normalized = bundleID.lowercased()
        return entries.contains(where: { $0.bundleID == normalized })
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try JSONDecoder().decode([DenylistEntry].self, from: data)
            // De-duplicate by bundleID in case of corrupt state.
            var seen: Set<String> = []
            entries = loaded.filter { seen.insert($0.bundleID).inserted }
        } catch {
            print("[AppFocusDenylistStore] load failed: \(error) — archiving corrupt file")
            archiveCorruptFile(storageURL)
        }
    }

    /// Renames a corrupt store file to `<name>.corrupt-<ISO8601>` so a fresh
    /// empty store can be written on the next mutation without silently
    /// overwriting potentially-recoverable data.
    private func archiveCorruptFile(_ url: URL) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let archiveName = url.lastPathComponent + ".corrupt-" + timestamp
        let archiveURL = url.deletingLastPathComponent().appendingPathComponent(archiveName)
        do {
            try FileManager.default.moveItem(at: url, to: archiveURL)
            print("[AppFocusDenylistStore] corrupt file archived to \(archiveURL.lastPathComponent)")
        } catch {
            print("[AppFocusDenylistStore] could not archive corrupt file: \(error)")
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let snapshot = entries
        let url = storageURL
        let work = DispatchWorkItem {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("[AppFocusDenylistStore] save failed: \(error)")
            }
        }
        pendingWrite = work
        writeQueue.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }
}
