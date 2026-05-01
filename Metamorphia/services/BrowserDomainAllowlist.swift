/*
 * Metamorphia
 * BrowserDomainAllowlist — JSON-persisted set of domains the browser tab
 * sensor is allowed to emit for.
 *
 * Persistence: ~/Library/Application Support/Metamorphia/browser-domain-allowlist.json
 * Write pattern: debounced 2 s, modelled after WatchlistStore.
 *
 * Semantics:
 *   - Empty allowlist → allows every host (no filtering).
 *   - Non-empty → host must equal, or be a subdomain of, a listed entry.
 *     "github.com" covers "gist.github.com" and "api.github.com" but not
 *     "github.io" or "malicious-github.com".
 *
 * Defaults key declared here so Coder A (BrowserTabSensor) can reference it.
 */

import Combine
import Defaults
import Foundation
import SwiftUI

// MARK: - BrowserDomainAllowlist

@MainActor
public final class BrowserDomainAllowlist: ObservableObject {

    public static let shared = BrowserDomainAllowlist()

    @Published public private(set) var entries: [DomainEntry] = []

    // MARK: - DomainEntry

    public struct DomainEntry: Codable, Identifiable, Hashable {
        public let id: UUID
        public let domain: String   // stored lowercase, no scheme, no leading www.
        public let addedAt: Date

        public init(id: UUID = UUID(), domain: String, addedAt: Date = .now) {
            self.id = id
            self.domain = domain
            self.addedAt = addedAt
        }
    }

    // MARK: - Private state

    private let storageURL: URL
    private let writeQueue = DispatchQueue(label: "BrowserDomainAllowlist.write", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private static let writeDebounce: TimeInterval = 2.0

    // MARK: - Init

    public init(storageURL: URL = BrowserDomainAllowlist.defaultStorageURL) {
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
            .appendingPathComponent("browser-domain-allowlist.json")
    }

    // MARK: - Mutations

    public func add(domain raw: String) {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return }
        guard !entries.contains(where: { $0.domain == normalized }) else { return }
        entries.append(DomainEntry(domain: normalized))
        scheduleWrite()
    }

    public func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        scheduleWrite()
    }

    // MARK: - Query

    public func allows(host: String) -> Bool {
        // Empty allowlist: permit everything.
        guard !entries.isEmpty else { return true }

        let normalizedHost = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for entry in entries {
            let listed = entry.domain
            // Exact match.
            if normalizedHost == listed { return true }
            // Subdomain match: host ends with ".<listed>".
            if normalizedHost.hasSuffix(".\(listed)") { return true }
        }
        return false
    }

    // MARK: - Normalization

    /// Strip scheme, path, query; strip leading "www."; lowercase.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Strip scheme (e.g. "https://").
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }

        // Keep only the host part (drop path and query).
        if let slashIndex = s.firstIndex(of: "/") {
            s = String(s[..<slashIndex])
        }

        // Strip port.
        if let colonIndex = s.lastIndex(of: ":") {
            let afterColon = s[s.index(after: colonIndex)...]
            if afterColon.allSatisfy(\.isNumber) {
                s = String(s[..<colonIndex])
            }
        }

        // Strip leading "www.".
        if s.hasPrefix("www.") {
            s = String(s.dropFirst(4))
        }

        return s
    }

    // MARK: - Disk I/O

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try JSONDecoder().decode([DomainEntry].self, from: data)
            var seen: Set<String> = []
            entries = loaded.filter { seen.insert($0.domain).inserted }
        } catch {
            print("[BrowserDomainAllowlist] load failed: \(error)")
        }
    }

    private func scheduleWrite() {
        let snapshot = entries
        let url = storageURL

        pendingWrite?.cancel()
        let item = DispatchWorkItem {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("[BrowserDomainAllowlist] save failed: \(error)")
            }
        }
        pendingWrite = item
        writeQueue.asyncAfter(deadline: .now() + Self.writeDebounce, execute: item)
    }
}

// MARK: - BrowserDomainAllowlistView

struct BrowserDomainAllowlistView: View {
    @ObservedObject private var store = BrowserDomainAllowlist.shared
    @State private var newDomainText: String = ""

    var body: some View {
        Form {
            Section {
                if store.entries.isEmpty {
                    Text("No allowlist configured — all domains will be recorded when the toggle is on. Add a domain to narrow the scope.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(store.entries) { entry in
                        HStack {
                            Text(entry.domain)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                store.remove(id: entry.id)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("github.com", text: $newDomainText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitAdd() }

                    Button("Add") { commitAdd() }
                        .disabled(newDomainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Domain Allowlist")
    }

    private func commitAdd() {
        let trimmed = newDomainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.add(domain: trimmed)
        newDomainText = ""
    }
}
