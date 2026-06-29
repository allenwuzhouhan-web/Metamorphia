/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Metamorphia
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import AppKit
import SwiftUI

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { scheduleSave() }
    }

    @Published var isLoading: Bool = false

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?

    // Bounded memo of resolved bookmark URLs keyed by bookmark Data, so repeated
    // reads from SwiftUI view bodies (displayName/fileURL/icon) don't re-run the
    // synchronous security-scoped bookmark resolve on every body recomputation.
    private let resolvedURLCache = NSCache<NSData, NSURL>()

    // Debounced persistence: coalesce rapid mutations and run the JSON encode +
    // atomic write off the main actor so the UI thread isn't blocked per change.
    private var saveTask: Task<Void, Never>?

    private init() {
        resolvedURLCache.countLimit = 256
        items = ShelfPersistenceService.shared.load()
        // The didSet above scheduled a redundant save of the just-loaded data;
        // cancel it since the data is already persisted.
        saveTask?.cancel()
        saveTask = nil
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = items
        saveTask = Task { [weak self] in
            // Coalesce bursts of mutations into a single write.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await ShelfPersistenceWriter.shared.write(snapshot)
            self?.saveTask = nil
        }
    }

    /// Force any pending debounced save to flush immediately (e.g. on app
    /// termination or other important transitions) so no data is lost.
    func flushPendingSave() async {
        saveTask?.cancel()
        saveTask = nil
        await ShelfPersistenceWriter.shared.write(items)
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identity key while preserving order (existing first).
        // For .file items resolve through the bounded cache so a drop doesn't
        // synchronously re-resolve every existing item's security-scoped
        // bookmark on the main actor.
        var seen: Set<String> = Set(merged.map { dedupKey(for: $0) })
        var addedIDs: [String] = []
        for it in newItems {
            let key = dedupKey(for: it)
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
                addedIDs.append(it.id.uuidString)
            }
        }
        withAnimation(.smooth(duration: 0.28)) {
            items = merged
        }
        if !addedIDs.isEmpty {
            ExtensionRPCServer.shared.notifyShelfItemsChanged(itemIDs: addedIDs, action: "added")
        }
        // Spotlight incremental index — only fires when the opt-in is on.
        for it in newItems where addedIDs.contains(it.id.uuidString) {
            SpotlightIndexer.shared.indexShelf(id: it.id.uuidString, title: it.displayName)
        }
    }

    /// Deduplication key matching `ShelfItem.identityKey`'s semantics, but
    /// resolving `.file` bookmarks through the bounded cache so repeated adds
    /// of the same files avoid a synchronous security-scoped resolve per item.
    private func dedupKey(for item: ShelfItem) -> String {
        if case .file(let bookmark) = item.kind {
            if let url = cachedFileURL(for: bookmark) {
                return "file://" + url.standardizedFileURL.path
            }
            return "file://missing/" + bookmark.base64EncodedString()
        }
        return item.identityKey
    }

    func remove(_ item: ShelfItem) {
        item.cleanupStoredData()
        withAnimation(.smooth(duration: 0.28)) {
            items.removeAll { $0.id == item.id }
        }
        // Removal is destructive (stored data cleaned up); flush immediately so a
        // crash before the debounce window can't resurrect the deleted item.
        Task { await flushPendingSave() }
        ExtensionRPCServer.shared.notifyShelfItemsChanged(itemIDs: [item.id.uuidString], action: "removed")
        // Spotlight removal.
        SpotlightIndexer.shared.removeShelf(id: item.id.uuidString)
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }

            // Apply all pending updates to a local copy and assign `items` once,
            // so a batch of N bookmark refreshes triggers a single didSet/save
            // instead of N.
            var updated = self.items
            var didChange = false
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = updated.firstIndex(where: { $0.id == itemID }),
                   case .file = updated[idx].kind {
                    updated[idx].kind = .file(bookmark: bookmarkData)
                    didChange = true
                }
            }
            if didChange {
                self.items = updated
            }

            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            var keep: [ShelfItem] = []
            for item in self.items {
                switch item.kind {
                case .file(let data):
                    let bookmark = Bookmark(data: data)
                    if await bookmark.validate() {
                        keep.append(item)
                    } else {
                        item.cleanupStoredData()
                    }
                default:
                    keep.append(item)
                }
            }
            await MainActor.run { self.items = keep }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        if let cached = resolvedURLCache.object(forKey: bookmarkData as NSData) {
            return cached as URL
        }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        if let url = result.url {
            resolvedURLCache.setObject(url as NSURL, forKey: bookmarkData as NSData)
        }
        return result.url
    }

    /// Resolves a bookmark to a file URL using the same bounded memo as
    /// `resolveFileURL`, but never schedules a bookmark refresh. Intended for
    /// read-only callers (e.g. SwiftUI view bodies computing a display name)
    /// that must not mutate `items` during a view update.
    func cachedFileURL(for bookmarkData: Data) -> URL? {
        if let cached = resolvedURLCache.object(forKey: bookmarkData as NSData) {
            return cached as URL
        }
        let url = Bookmark(data: bookmarkData).resolveURL()
        if let url {
            resolvedURLCache.setObject(url as NSURL, forKey: bookmarkData as NSData)
        }
        return url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}

/// Serializes shelf persistence writes off the main actor so the JSON encode +
/// atomic file write never block the UI thread, and never race each other.
private actor ShelfPersistenceWriter {
    static let shared = ShelfPersistenceWriter()

    func write(_ items: [ShelfItem]) {
        ShelfPersistenceService.shared.save(items)
    }
}
