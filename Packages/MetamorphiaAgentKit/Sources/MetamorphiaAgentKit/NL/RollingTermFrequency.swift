import Foundation

/// Tracks noun frequencies over a sliding window of the last 500 messages.
/// Used by `EntityExtractor` to score topic unusualness via a simple inverse
/// frequency heuristic: terms that appear rarely score higher.
///
/// Persisted at `~/Library/Application Support/Metamorphia/term-frequency.json`
/// using the same debounced atomic-write pattern as `WatchlistStore`.
public actor RollingTermFrequency {

    // MARK: - Persistence envelope

    private struct Snapshot: Codable, Sendable {
        var counts: [String: Int]
        var messageWindow: [[String]]   // ordered ring buffer of noun lists
    }

    // MARK: - State

    private var counts: [String: Int] = [:]
    /// Ring buffer; each element is the noun list from one message.
    private var messageWindow: [[String]] = []
    private let windowSize: Int

    private let storageURL: URL
    private var pendingWrite: Task<Void, Never>?
    private let writeDebounce: TimeInterval

    // MARK: - Lifecycle

    public init(location: URL? = nil, windowSize: Int = 500, writeDebounce: TimeInterval = 1.0) {
        self.windowSize = windowSize
        self.writeDebounce = writeDebounce
        if let loc = location {
            self.storageURL = loc
        } else {
            self.storageURL = URL.applicationSupportDirectory
                .appendingPathComponent("Metamorphia", isDirectory: true)
                .appendingPathComponent("term-frequency.json")
        }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let initial = Self.readFromDisk(at: storageURL)
        self.counts = initial.counts
        self.messageWindow = initial.messageWindow
    }

    // MARK: - Public API

    /// Record the nouns seen in one message. Evicts the oldest message if the
    /// window is full before inserting.
    public func observe(nouns: [String]) {
        if messageWindow.count >= windowSize {
            let evicted = messageWindow.removeFirst()
            for noun in evicted {
                let key = noun.lowercased()
                if let current = counts[key] {
                    let next = current - 1
                    if next <= 0 {
                        counts.removeValue(forKey: key)
                    } else {
                        counts[key] = next
                    }
                }
            }
        }
        messageWindow.append(nouns)
        for noun in nouns {
            let key = noun.lowercased()
            counts[key] = (counts[key] ?? 0) + 1
        }
        scheduleWrite()
    }

    /// How many times `term` appears across all messages currently in the window.
    public func frequency(of term: String) -> Int {
        counts[term.lowercased()] ?? 0
    }

    // MARK: - Persistence

    private static func readFromDisk(at url: URL) -> Snapshot {
        let empty = Snapshot(counts: [:], messageWindow: [])
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            print("[RollingTermFrequency] load failed: \(error)")
            return empty
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let snap = Snapshot(counts: counts, messageWindow: messageWindow)
        let url = storageURL
        let debounce = writeDebounce
        pendingWrite = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(snap)
                try data.write(to: url, options: .atomic)
            } catch {
                print("[RollingTermFrequency] save failed: \(error)")
            }
        }
    }
}
