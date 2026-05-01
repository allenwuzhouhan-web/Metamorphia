/*
 * Metamorphia
 * Watchlist persistence with optional iCloud key-value sync.
 *
 * Local store: JSON at ~/Library/Application Support/Metamorphia/watchlist.json
 * with debounced atomic writes — same pattern as ConversationPersistenceService.
 *
 * Cloud store (optional): NSUbiquitousKeyValueStore. A watchlist is a small
 * list of tickers (~1 KB typical, well under KVS's 1 MB limit), so KVS is the
 * right sync primitive — CloudKit would be overkill. Conflict resolution is
 * per-entry last-write-wins, driven by WatchlistEntry.updatedAt.
 */

import Foundation
import Combine

@MainActor
public final class WatchlistStore: ObservableObject {

    public static let shared = WatchlistStore()

    @Published public private(set) var entries: [WatchlistEntry] = []

    private let storageURL: URL
    private let writeQueue = DispatchQueue(label: "WatchlistStore.write", qos: .utility)
    private let writeDebounce: TimeInterval
    private var pendingWrite: DispatchWorkItem?

    private let kvStore: NSUbiquitousKeyValueStore?
    private static let kvKey = "metamorphia.watchlist.v1"
    private var kvObserver: NSObjectProtocol?

    public init(
        storageURL: URL = WatchlistStore.defaultStorageURL,
        writeDebounce: TimeInterval = 0.5,
        kvStore: NSUbiquitousKeyValueStore? = .default
    ) {
        self.storageURL = storageURL
        self.writeDebounce = writeDebounce
        self.kvStore = kvStore

        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        loadFromDisk()
        if let kvStore {
            mergeFromKVS(kvStore)
            startObservingKVS(kvStore)
            kvStore.synchronize()
        }
    }

    deinit {
        if let kvObserver {
            NotificationCenter.default.removeObserver(kvObserver)
        }
    }

    public nonisolated static var defaultStorageURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Metamorphia", isDirectory: true)
            .appendingPathComponent("watchlist.json")
    }

    // MARK: - Queries

    public func contains(_ symbol: String) -> Bool {
        let key = symbol.uppercased()
        return entries.contains(where: { $0.symbol == key })
    }

    public func entry(for symbol: String) -> WatchlistEntry? {
        let key = symbol.uppercased()
        return entries.first(where: { $0.symbol == key })
    }

    // MARK: - Mutations

    @discardableResult
    public func add(_ symbol: String, displayName: String? = nil) -> WatchlistEntry {
        let key = symbol.uppercased()
        if let existing = entries.first(where: { $0.symbol == key }) {
            return existing
        }
        let entry = WatchlistEntry(symbol: key, displayName: displayName)
        entries.append(entry)
        scheduleWrite()
        return entry
    }

    public func remove(_ symbol: String) {
        let key = symbol.uppercased()
        guard entries.contains(where: { $0.symbol == key }) else { return }
        entries.removeAll { $0.symbol == key }
        scheduleWrite()
    }

    public func rename(_ symbol: String, to displayName: String?) {
        mutate(symbol: symbol) { $0.displayName = displayName }
    }

    public func setAlerts(_ rules: [PriceAlertRule], for symbol: String) {
        mutate(symbol: symbol) { $0.alertRules = rules }
    }

    public func addAlert(_ rule: PriceAlertRule, to symbol: String) {
        mutate(symbol: symbol) { $0.alertRules.append(rule) }
    }

    public func removeAlert(_ ruleID: UUID, from symbol: String) {
        mutate(symbol: symbol) { $0.alertRules.removeAll { $0.id == ruleID } }
    }

    public func markAlertFired(_ ruleID: UUID, for symbol: String, at fireDate: Date = .now) {
        mutate(symbol: symbol) { entry in
            guard let idx = entry.alertRules.firstIndex(where: { $0.id == ruleID }) else { return }
            entry.alertRules[idx].lastFiredAt = fireDate
        }
    }

    /// All rules across all entries — convenience for the monitor's alert loop.
    public func allAlertRules() -> [PriceAlertRule] {
        entries.flatMap { $0.alertRules }
    }

    private func mutate(symbol: String, _ transform: (inout WatchlistEntry) -> Void) {
        let key = symbol.uppercased()
        guard let idx = entries.firstIndex(where: { $0.symbol == key }) else { return }
        var entry = entries[idx]
        transform(&entry)
        entry.updatedAt = .now
        entries[idx] = entry
        scheduleWrite()
    }

    // MARK: - Disk I/O

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try JSONDecoder().decode([WatchlistEntry].self, from: data)
            var seen: Set<String> = []
            entries = loaded.filter { seen.insert($0.symbol).inserted }
        } catch {
            print("[WatchlistStore] load failed: \(error)")
        }
    }

    private func scheduleWrite() {
        let snapshot = entries
        let url = storageURL
        let debounce = writeDebounce

        writeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingWrite?.cancel()
            let item = DispatchWorkItem {
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    try data.write(to: url, options: .atomic)
                } catch {
                    print("[WatchlistStore] save failed: \(error)")
                }
            }
            self.pendingWrite = item
            self.writeQueue.asyncAfter(deadline: .now() + debounce, execute: item)
        }

        if let kvStore {
            writeToKVS(kvStore, snapshot: snapshot)
        }
    }

    // MARK: - iCloud KVS

    private func startObservingKVS(_ kvStore: NSUbiquitousKeyValueStore) {
        kvObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mergeFromKVS(kvStore)
            }
        }
    }

    private func writeToKVS(_ kvStore: NSUbiquitousKeyValueStore, snapshot: [WatchlistEntry]) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            kvStore.set(data, forKey: Self.kvKey)
        } catch {
            print("[WatchlistStore] KVS encode failed: \(error)")
        }
    }

    /// Merge remote KVS state into local. Per-symbol last-write-wins by
    /// `updatedAt`; local wins ties (avoids ping-ponging when two devices
    /// touch the same tick).
    private func mergeFromKVS(_ kvStore: NSUbiquitousKeyValueStore) {
        guard let data = kvStore.data(forKey: Self.kvKey) else { return }
        guard let remote = try? JSONDecoder().decode([WatchlistEntry].self, from: data) else { return }

        var merged: [String: WatchlistEntry] = [:]
        for entry in entries { merged[entry.symbol] = entry }
        for remoteEntry in remote {
            if let local = merged[remoteEntry.symbol] {
                if remoteEntry.updatedAt > local.updatedAt {
                    merged[remoteEntry.symbol] = remoteEntry
                }
            } else {
                merged[remoteEntry.symbol] = remoteEntry
            }
        }

        let next = merged.values.sorted { $0.addedAt < $1.addedAt }
        if next != entries {
            entries = next
            // Write the merged view back to disk (and forward to KVS) so both
            // sides converge. Debounced write absorbs the loop cleanly.
            scheduleWrite()
        }
    }
}
