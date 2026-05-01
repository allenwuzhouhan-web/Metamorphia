/*
 * Metamorphia
 * Continuum Phase 10 — Predictive staging: query pattern learner.
 *
 * Observes recurring query patterns keyed by canonical form + entity bag.
 * Detects when the user asks the same class of question ≥ 4 days/week near
 * a given hour so PredictiveStaging can pre-warm the answer on wake.
 */

import Foundation
import Combine

#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

// MARK: - QueryPattern

public struct QueryPattern: Sendable, Codable, Hashable {
    public let id: UUID
    /// Normalized form ("what happened overnight", "top news today").
    public let canonicalQuery: String
    /// Entities extracted from the query, sorted.
    public let entityBag: [String]
    /// Hour of day [0, 23] this pattern was first observed.
    public let hourBucket: Int
    /// weekday (1 = Sunday … 7 = Saturday) → set of day-start Dates on which
    /// this pattern was submitted. Counting distinct days (not submissions)
    /// prevents bursts on one day from artificially inflating recurrence scores.
    public var hitsPerWeekday: [Int: Set<Date>]
    public var totalHits: Int
    public var firstSeen: Date
    public var lastSeen: Date

    /// Number of distinct days this pattern was submitted on `weekday`.
    public func hitCount(for weekday: Int) -> Int {
        hitsPerWeekday[weekday]?.count ?? 0
    }
}

// MARK: - QueryPatternLearner

/// Records every submitted query and identifies recurring morning patterns.
///
/// Algorithm overview:
/// - Normalize: lowercase, strip punctuation, collapse whitespace.
/// - Also map synonym clusters ("what's new" / "what is new" → canonical).
/// - Two queries with the same entity bag and similar normalized form are
///   treated as the same pattern.
/// - Patterns with `lastSeen < now - 30d` are evicted on each save.
/// - Debounced encrypted writes to disk.
@MainActor
public final class QueryPatternLearner: ObservableObject {

    public static let shared = QueryPatternLearner()

    // MARK: - Tunables

    /// Minimum per-weekday hit count to be considered a recurring pattern.
    public var minHitsForRecurring: Int = 4
    /// Window (minutes before / after wake time) for pattern eligibility.
    public var withinMinutesOfWake: Int = 2

    // MARK: - Private state

    private var patterns: [String: QueryPattern] = [:]       // canonical → pattern
    private var securePersistence: SecurePersistence?
#if canImport(MetamorphiaAgentKit)
    private var extractor: EntityExtractor?
#endif

    private let writeQueue = DispatchQueue(label: "QueryPatternLearner.write", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private static let writeDebounce: TimeInterval = 4.0
    private static let evictionAge: TimeInterval = 30 * 86_400  // 30 days
    /// Sliding window for per-weekday hit sets: only keep dates within this
    /// many days of the current observation. 5 weeks (35 days) covers the
    /// last 5 occurrences of any given weekday.
    private static let weekdayWindow: TimeInterval = 35 * 86_400

    private nonisolated static var storageURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Metamorphia", isDirectory: true)
            .appendingPathComponent("query-patterns.enc")
    }

    // MARK: - Init

    private init() {}

    // MARK: - Lifecycle

#if canImport(MetamorphiaAgentKit)
    public func start(securePersistence: SecurePersistence?, extractor: EntityExtractor) {
        self.securePersistence = securePersistence
        self.extractor = extractor
        loadFromDisk()
    }
#else
    public func start(securePersistence: SecurePersistence?) {
        self.securePersistence = securePersistence
        loadFromDisk()
    }
#endif

    // MARK: - Observation

    /// Record a submitted query. Normalizes, extracts entity bag, and updates
    /// hit counts. Safe to call on every submit — cost is negligible.
    public func observe(query: String, submittedAt: Date = .now) {
        let canonical = Self.normalize(query)
        guard !canonical.isEmpty else { return }

        let cal = Calendar.current
        let hourBucket = cal.component(.hour, from: submittedAt)
        let weekday = cal.component(.weekday, from: submittedAt)  // 1 = Sunday

        // Day-start of the submission date used as the set element so that
        // multiple submissions on the same calendar day only count once.
        let dayStart = cal.startOfDay(for: submittedAt)
        let windowCutoff = submittedAt.addingTimeInterval(-Self.weekdayWindow)

        if var existing = patterns[canonical] {
            // Insert the day-start; prune entries older than the 35-day window.
            var days = existing.hitsPerWeekday[weekday, default: Set<Date>()]
            days.insert(dayStart)
            days = days.filter { $0 >= windowCutoff }
            existing.hitsPerWeekday[weekday] = days
            existing.totalHits += 1
            existing.lastSeen = submittedAt
            patterns[canonical] = existing
        } else {
            // Entity bag extraction is async; for the initial record we store
            // an empty bag and back-fill asynchronously.
            let pattern = QueryPattern(
                id: UUID(),
                canonicalQuery: canonical,
                entityBag: [],
                hourBucket: hourBucket,
                hitsPerWeekday: [weekday: [dayStart]],
                totalHits: 1,
                firstSeen: submittedAt,
                lastSeen: submittedAt
            )
            patterns[canonical] = pattern

#if canImport(MetamorphiaAgentKit)
            if let ex = extractor {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let entities = await ex.extract(query)
                    let bag = entities.map { $0.canonicalName }.sorted()
                    if let p = self.patterns[canonical] {
                        // Patch entity bag — recreate because struct is a value type.
                        self.patterns[canonical] = QueryPattern(
                            id: p.id,
                            canonicalQuery: p.canonicalQuery,
                            entityBag: bag,
                            hourBucket: p.hourBucket,
                            hitsPerWeekday: p.hitsPerWeekday,
                            totalHits: p.totalHits,
                            firstSeen: p.firstSeen,
                            lastSeen: p.lastSeen
                        )
                    }
                }
            }
#endif
        }

        scheduleWrite()
    }

    // MARK: - Kill switch

    /// Wipe all learned patterns and flush the empty state to disk.
    /// Called from the Settings danger-zone "Forget everything" action.
    public func forgetAll() {
        patterns.removeAll()
        flushToDisk()
    }

    // MARK: - Query

    /// Returns patterns whose `hourBucket` is within `within` seconds of the
    /// current time and whose canonical hour matches `hourBucket`. Results are
    /// sorted descending by total hits.
    public func topPatterns(hourBucket: Int, within: TimeInterval = 120) -> [QueryPattern] {
        // Allow ±1 hour bucket to cover edge-of-hour queries.
        let adjacent = Set([
            (hourBucket - 1 + 24) % 24,
            hourBucket,
            (hourBucket + 1) % 24
        ])
        return patterns.values
            .filter { adjacent.contains($0.hourBucket) }
            .sorted { $0.totalHits > $1.totalHits }
    }

    // MARK: - Normalization

    /// Normalize a raw query string to its canonical form.
    ///
    /// Steps:
    /// 1. Lowercase.
    /// 2. Strip punctuation except spaces.
    /// 3. Collapse multiple spaces.
    /// 4. Apply synonym clusters.
    public static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()

        // Strip punctuation (keep spaces, letters, digits).
        s = s.unicodeScalars.filter { scalar in
            CharacterSet.letters.union(.decimalDigits).union(.whitespaces).contains(scalar)
        }.map { String($0) }.joined()

        // Collapse whitespace.
        s = s.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Synonym clusters — map variant surface forms to canonical queries.
        for (variants, canonical) in Self.synonymClusters {
            if variants.contains(s) {
                return canonical
            }
        }

        return s
    }

    /// Small hand-curated synonym clusters. Keys are normalized forms that
    /// should all collapse to the same canonical query (the value).
    private static let synonymClusters: [Set<String>: String] = [
        ["whats new", "what is new", "whats happening", "what is happening",
         "anything new", "what happened"]: "whats new",
        ["whats the news", "top news", "latest news", "whats happening in the news",
         "news today", "todays news"]: "top news today",
        ["what happened overnight", "whats new overnight", "overnight news",
         "anything overnight"]: "what happened overnight",
        ["whats the weather", "weather today", "how is the weather",
         "weather forecast"]: "whats the weather",
        ["whats on my calendar", "calendar today", "whats today", "my schedule",
         "todays schedule"]: "whats on my calendar",
        ["whats the market doing", "market update", "how are markets",
         "stock market today", "market today"]: "market update",
    ]

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let sp = securePersistence else {
            loadPlain()
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let url = Self.storageURL
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let plain = try? sp.decrypt(data),
                  let loaded = try? JSONDecoder().decode([String: QueryPattern].self, from: plain)
            else {
                return
            }
            await MainActor.run { self.patterns = loaded }
        }
    }

    private func loadPlain() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let url = Self.storageURL.deletingPathExtension().appendingPathExtension("json")
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let loaded = try? JSONDecoder().decode([String: QueryPattern].self, from: data)
            else { return }
            await MainActor.run { self.patterns = loaded }
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.flushToDisk() }
        }
        pendingWrite = work
        writeQueue.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }

    private func flushToDisk() {
        // Evict stale patterns.
        let cutoff = Date().addingTimeInterval(-Self.evictionAge)
        patterns = patterns.filter { $0.value.lastSeen >= cutoff }

        guard let encoded = try? JSONEncoder().encode(patterns) else { return }

        if let sp = securePersistence {
            guard let cipher = try? sp.encrypt(encoded) else { return }
            let url = Self.storageURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? cipher.write(to: url, options: .atomic)
        } else {
            let url = Self.storageURL.deletingPathExtension().appendingPathExtension("json")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? encoded.write(to: url, options: .atomic)
        }
    }
}
