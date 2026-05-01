/*
 * Metamorphia
 * PlaceLabelStore — user-assigned labels for Wi-Fi place hashes.
 *
 * Coder A's PlaceSensor derives a salted HMAC hash from the current Wi-Fi
 * SSID and calls `PlaceLabelStore.shared.seen(placeHash:)` each time it
 * observes a network, then `label(for:)` to retrieve the user's label.
 *
 * This store:
 *   • Records the first time each hash was seen (so Settings can surface
 *     recently-seen, unlabeled networks for the user to tag).
 *   • Lets the user attach a short label ("home", "office", "café").
 *   • Persists to plain JSON — hashes are already HMACs; labels are
 *     user-chosen strings.
 *
 * Persistence: ~/Library/Application Support/Metamorphia/place-labels.json
 * Writes are debounced 2 s via a DispatchWorkItem cancel pattern (same as
 * AppFocusDenylistStore and BrowserDomainAllowlist).
 */

import Combine
import Defaults
import Foundation
import SwiftUI

// MARK: - PlaceLabelStore

@MainActor
public final class PlaceLabelStore: ObservableObject {

    public static let shared = PlaceLabelStore()

    // MARK: - Entry

    public struct Entry: Codable, Identifiable, Hashable {
        public let id: UUID
        /// The HMAC-derived place hash produced by PlaceSensor.
        public let placeHash: String
        /// User-assigned label. Empty string means unlabeled.
        public var label: String
        /// Timestamp of the first time this hash was observed.
        public let firstSeen: Date

        public init(id: UUID = UUID(), placeHash: String, label: String = "", firstSeen: Date = .now) {
            self.id = id
            self.placeHash = placeHash
            self.label = label
            self.firstSeen = firstSeen
        }
    }

    // MARK: - Published state

    @Published public private(set) var entries: [Entry] = []

    // MARK: - Private state

    private let storageURL: URL
    private let writeQueue = DispatchQueue(label: "PlaceLabelStore.write", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private static let writeDebounce: TimeInterval = 2.0

    // MARK: - Init

    public init(storageURL: URL = PlaceLabelStore.defaultStorageURL) {
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
            .appendingPathComponent("place-labels.json")
    }

    // MARK: - Observation (called by PlaceSensor)

    /// Record that a hash has been observed. Creates a new unlabeled entry if
    /// the hash is not already known; otherwise is a no-op.
    public func seen(placeHash: String) {
        guard !entries.contains(where: { $0.placeHash == placeHash }) else { return }
        entries.append(Entry(placeHash: placeHash))
        scheduleWrite()
    }

    // MARK: - Mutations

    /// Assign a human-readable label to a place hash. Creates an entry if
    /// one does not already exist (e.g. if `seen` was never called yet).
    public func assign(label: String, to placeHash: String) {
        if let idx = entries.firstIndex(where: { $0.placeHash == placeHash }) {
            entries[idx].label = label
        } else {
            entries.append(Entry(placeHash: placeHash, label: label))
        }
        scheduleWrite()
    }

    /// Remove an entry by its stable ID.
    public func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        scheduleWrite()
    }

    // MARK: - Query

    /// Return the label for a hash, or nil if the hash is unknown or unlabeled.
    public func label(for placeHash: String) -> String? {
        guard let entry = entries.first(where: { $0.placeHash == placeHash }),
              !entry.label.isEmpty else { return nil }
        return entry.label
    }

    /// Return up to `limit` place hashes that have been seen but not labeled,
    /// sorted by most recently first-seen. Used by the Settings UI so the user
    /// can tag new networks without hunting through the full list.
    public func recentUnlabeled(limit: Int = 10) -> [String] {
        entries
            .filter { $0.label.isEmpty }
            .sorted { $0.firstSeen > $1.firstSeen }
            .prefix(limit)
            .map { $0.placeHash }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try JSONDecoder().decode([Entry].self, from: data)
            // De-duplicate by placeHash in case of corrupt state.
            var seen: Set<String> = []
            entries = loaded.filter { seen.insert($0.placeHash).inserted }
        } catch {
            print("[PlaceLabelStore] load failed: \(error)")
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
                print("[PlaceLabelStore] save failed: \(error)")
            }
        }
        pendingWrite = work
        writeQueue.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }
}

// MARK: - PlaceLabelStoreProtocol conformance

extension PlaceLabelStore: PlaceLabelStoreProtocol {}
