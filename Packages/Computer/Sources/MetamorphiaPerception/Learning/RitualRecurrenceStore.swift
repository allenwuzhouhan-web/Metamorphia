import Foundation

/// Tracks how often a ritual signature has recurred across sessions and
/// promotes it for skill compilation once it crosses a repetition threshold
/// within a rolling time window.
///
/// Persistence is via a JSON file in the perception support directory — the
/// same directory that ElementDatabase uses. This keeps MetamorphiaPerception
/// self-contained without requiring a SQLite schema migration.
public actor RitualRecurrenceStore {

    public static let shared = RitualRecurrenceStore()

    // MARK: - State

    /// Map of ritual signature → sorted list of observation dates.
    private var occurrences: [String: [Date]] = [:]

    private let fileURL: URL
    private let minRepetitions: Int
    private let recurrenceWindowDays: Int

    // MARK: - Init

    public init(
        fileURL: URL? = nil,
        minRepetitions: Int = 3,
        recurrenceWindowDays: Int = 7
    ) {
        let resolvedURL = fileURL ?? PerceptionRuntime.host.applicationSupportDir
            .appendingPathComponent("ritual_recurrence.json")
        self.fileURL = resolvedURL
        self.minRepetitions = minRepetitions
        self.recurrenceWindowDays = recurrenceWindowDays
        // Load persisted data synchronously during init (nonisolated, safe).
        self.occurrences = Self.loadStatic(fileURL: resolvedURL)
    }

    private static func loadStatic(fileURL: URL) -> [String: [Date]] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: [Date]].self, from: data)) ?? [:]
    }

    // MARK: - Public API

    /// Record one observation of `signature` at the given date (default: now).
    ///
    /// After recording, prunes stale dates outside the window, then checks
    /// whether the signature now qualifies for promotion.
    ///
    /// - Returns: `true` iff the signature has reached `minRepetitions`
    ///   observations within the rolling `recurrenceWindowDays` window.
    @discardableResult
    public func observe(signature: String, at date: Date = Date()) -> Bool {
        prune(now: date)
        occurrences[signature, default: []].append(date)
        save()
        return isPromoted(signature: signature, now: date)
    }

    /// Check promotion status without recording a new observation.
    public func isPromoted(signature: String, now: Date = Date()) -> Bool {
        let cutoff = cutoffDate(from: now)
        let recent = (occurrences[signature] ?? []).filter { $0 >= cutoff }
        return recent.count >= minRepetitions
    }

    // MARK: - Pruning

    private func prune(now: Date) {
        let cutoff = cutoffDate(from: now)
        for key in occurrences.keys {
            occurrences[key] = occurrences[key]?.filter { $0 >= cutoff }
            if occurrences[key]?.isEmpty == true {
                occurrences.removeValue(forKey: key)
            }
        }
    }

    private func cutoffDate(from now: Date) -> Date {
        now.addingTimeInterval(-Double(recurrenceWindowDays) * 86_400)
    }

    // MARK: - Persistence


    /// Persist occurrences atomically. Uses a write-to-temp-then-move pattern
    /// to avoid leaving a half-written file on crash.
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(occurrences) else { return }

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            // Non-fatal: next successful save will correct.
        }
    }
}
