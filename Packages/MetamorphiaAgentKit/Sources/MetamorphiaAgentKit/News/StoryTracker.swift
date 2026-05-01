import Foundation
import NaturalLanguage

// MARK: - StoryDiff

/// Describes what changed in a story since a given cutoff date.
public struct StoryDiff: Sendable {
    public let story: Story
    /// Articles whose `publishedAt` is after the cutoff.
    public let newArticles: [StoryArticleRef]
    /// Entities added to the story since the cutoff (union of new article entities
    /// minus entities that were present before any new article arrived).
    public let newEntities: Set<String>
    /// Change in mean polarity relative to samples before the cutoff.
    /// `nil` when there are insufficient samples on either side.
    public let sentimentShift: Double?
}

// MARK: - StoryTracker

/// Clusters incoming news article references into `Story` narrative objects
/// using asymmetric entity containment. Stories are persisted encrypted at rest
/// and evicted after `quietLifetime` of no new articles.
///
/// Matching uses containment rather than Jaccard: `|A ∩ S| / |A|` where A is
/// the incoming article's entity set and S is the story's canonical entity set.
/// This keeps the score stable as S grows across many articles.
///
/// Thread-safety: actor-isolated. All mutations happen on the actor's executor.
/// Disk I/O is dispatched to a detached `Task` to avoid holding the actor
/// during blocking writes.
///
/// Persistence mirrors `InterestGraphStore`: debounced atomic writes with a
/// `pendingWriteTask` cancel-before-replace pattern.
public actor StoryTracker {

    // MARK: - Configuration

    /// How far back (in time from now) to look for candidate stories to merge
    /// an incoming article into. Default 24 hours.
    private let clusteringWindow: TimeInterval
    /// Minimum asymmetric containment score `|A ∩ S| / |A|` to consider two
    /// entity sets the same story. Default 0.6.
    private let containmentThreshold: Double
    /// Maximum number of canonical entities kept in `Story.entities`.
    /// Full per-article entity lists remain in `StoryArticleRef.extractedEntities`.
    private let maxEntitiesPerStory: Int
    /// Stories that have seen no new articles for this long are evicted.
    private let quietLifetime: TimeInterval
    /// Hard upper bound on stored stories. Oldest by `lastArticleAt` are
    /// dropped when this limit is breached after eviction.
    private let maxStories: Int
    /// Hard upper bound on articles retained per story, keyed by `publishedAt`.
    /// Long-running narratives (containment scoring stays stable as S grows)
    /// would otherwise accumulate articles indefinitely. The canonical entity
    /// set, sentiment trajectory, and recent-arc diffs are all preserved by
    /// keeping the most recent N refs.
    private let maxArticlesPerStory: Int

    // MARK: - State

    private var stories: [UUID: Story] = [:]

    // MARK: - Persistence

    private let storageURL: URL
    private let securePersistence: SecurePersistence?
    private var pendingWriteTask: Task<Void, Never>?
    private let writeDebounce: TimeInterval = 0.5

    // MARK: - Lifecycle

    public init(
        location: URL? = nil,
        clusteringWindow: TimeInterval = 24 * 3600,
        containmentThreshold: Double = 0.6,
        maxEntitiesPerStory: Int = 12,
        quietLifetime: TimeInterval = 30 * 24 * 3600,
        maxStories: Int = 200,
        maxArticlesPerStory: Int = 60,
        /// Backward-compat alias for `containmentThreshold`. If both are supplied
        /// the explicit `containmentThreshold` value takes precedence.
        jaccardThreshold: Double? = nil
    ) {
        self.clusteringWindow = clusteringWindow
        self.containmentThreshold = jaccardThreshold ?? containmentThreshold
        self.maxEntitiesPerStory = maxEntitiesPerStory
        self.quietLifetime = quietLifetime
        self.maxStories = maxStories
        self.maxArticlesPerStory = maxArticlesPerStory

        let url = location ?? URL.applicationSupportDirectory
            .appendingPathComponent("Metamorphia", isDirectory: true)
            .appendingPathComponent("stories.enc")
        self.storageURL = url

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var secure: SecurePersistence?
        do {
            secure = try SecurePersistence(serviceTag: "com.metamorphia.stories.v1")
        } catch {
            print("[StoryTracker] Keychain unavailable (\(error.localizedDescription)); using plain JSON.")
        }
        self.securePersistence = secure

        // Load synchronously into the still-unpublished actor.
        // `readFromDisk` is `nonisolated` so it's callable from the
        // non-isolated init; we then apply compaction inline (pure mutation
        // of `self.stories`, which is safe during init).
        self.stories = Self.readFromDisk(
            at: url,
            fallback: url.deletingPathExtension().appendingPathExtension("json"),
            secure: secure
        )
        let needsCompactWrite = Self.compactInPlace(
            stories: &self.stories,
            maxArticlesPerStory: maxArticlesPerStory,
            maxEntitiesPerStory: maxEntitiesPerStory
        )
        if needsCompactWrite {
            // Defer the rewrite until the actor's executor is available.
            Task { [weak self] in
                await self?.scheduleCompactRewrite()
            }
        }
    }

    // MARK: - Ingest

    /// Ingest a single article reference, clustering it into an existing story
    /// or creating a new singleton story.
    public func ingest(article: StoryArticleRef) async {
        // De-duplication: skip if any story already contains this article link.
        let alreadyPresent = stories.values.contains { story in
            story.articles.contains { $0.articleId == article.articleId }
        }
        guard !alreadyPresent else { return }

        let entities = Set(article.extractedEntities)
        let now = Date()

        // Score sentiment for the article title. Append to story after clustering.
        let sentimentSample = scoreSentiment(title: article.title, at: now)

        // --- Entity-sparse branch ---
        if entities.count == 0 {
            // Zero-entity articles carry no clustering signal; drop them entirely.
            // This prevents unbounded singleton accumulation from poorly-parsed feeds.
            print("[StoryTracker] warning: dropping article with no extracted entities — '\(article.title)'")
            return
        }

        if entities.count == 1 {
            // Single-entity articles: look for an active story that already contains
            // this entity. If found, append; otherwise create a singleton story.
            let windowCutoff = now.addingTimeInterval(-clusteringWindow)
            let singleEntity = entities.first!
            let match = stories.values
                .filter { $0.lastArticleAt >= windowCutoff && $0.entities.contains(singleEntity) }
                .sorted { $0.lastArticleAt > $1.lastArticleAt }
                .first

            if let existing = match, var matched = stories[existing.id] {
                matched.articles.append(article)
                matched.lastArticleAt = max(matched.lastArticleAt, article.publishedAt)
                trimArticles(&matched.articles)
                // Story.entities is a cached top-K set; re-derive after append.
                // (cached from articles; must stay synchronized — see issue 4)
                matched.entities = topEntities(from: matched.articles, limit: maxEntitiesPerStory)
                if let sample = sentimentSample {
                    matched.sentimentTrajectory.append(sample)
                    if matched.sentimentTrajectory.count > 50 {
                        matched.sentimentTrajectory.removeFirst(
                            matched.sentimentTrajectory.count - 50
                        )
                    }
                }
                stories[existing.id] = matched
            } else {
                var newStory = Story(
                    title: article.title,
                    entities: entities,
                    firstSeenAt: article.publishedAt,
                    lastArticleAt: article.publishedAt,
                    articles: [article]
                )
                if let sample = sentimentSample {
                    newStory.sentimentTrajectory = [sample]
                }
                stories[newStory.id] = newStory
            }
            evictIfNeeded(now: now)
            scheduleWrite()
            return
        }

        // --- Normal path: entities.count >= 2 ---
        // Candidate stories: active within the clustering window.
        let windowCutoff = now.addingTimeInterval(-clusteringWindow)
        let candidates = stories.values.filter { $0.lastArticleAt >= windowCutoff }

        // Find the best-matching candidate using asymmetric containment:
        //   score = |A ∩ S| / |A|   (A = incoming article, S = story's entity set)
        // Containment stays stable as S grows, unlike Jaccard which degrades.
        var bestId: UUID? = nil
        var bestScore: Double = 0
        var bestLastArticle: Date = .distantPast

        for candidate in candidates {
            let score = containment(entities, candidate.entities)
            if score >= containmentThreshold {
                if score > bestScore || (score == bestScore && candidate.lastArticleAt > bestLastArticle) {
                    bestScore = score
                    bestId = candidate.id
                    bestLastArticle = candidate.lastArticleAt
                }
            }
        }

        if let id = bestId, var matched = stories[id] {
            // Merge into existing story.
            matched.articles.append(article)
            matched.lastArticleAt = max(matched.lastArticleAt, article.publishedAt)
            trimArticles(&matched.articles)
            // Story.entities is a cached top-K set derived from all member articles;
            // recompute after each merge to keep it bounded and accurate.
            // (cached from articles; must stay synchronized — see issue 4)
            matched.entities = topEntities(from: matched.articles, limit: maxEntitiesPerStory)
            if let sample = sentimentSample {
                matched.sentimentTrajectory.append(sample)
                if matched.sentimentTrajectory.count > 50 {
                    matched.sentimentTrajectory.removeFirst(
                        matched.sentimentTrajectory.count - 50
                    )
                }
            }
            stories[id] = matched
        } else {
            // No matching story — create a new one.
            var newStory = Story(
                title: article.title,
                entities: entities,
                firstSeenAt: article.publishedAt,
                lastArticleAt: article.publishedAt,
                articles: [article]
            )
            if let sample = sentimentSample {
                newStory.sentimentTrajectory = [sample]
            }
            stories[newStory.id] = newStory
        }

        evictIfNeeded(now: now)
        scheduleWrite()
    }

    /// Batch ingest. Clusters all articles, then performs a single debounced write.
    public func ingest(articles: [StoryArticleRef]) async {
        for article in articles {
            await ingest(article: article)
        }
        // The individual ingest calls already schedule writes; the last one wins.
    }

    // MARK: - Reads

    /// All currently tracked stories, sorted by most-recent-article descending.
    public func allStories() -> [Story] {
        stories.values.sorted { $0.lastArticleAt > $1.lastArticleAt }
    }

    /// Stories that contain `entity` in their entity set.
    public func stories(about entity: String) -> [Story] {
        stories.values
            .filter { $0.entities.contains(entity) }
            .sorted { $0.lastArticleAt > $1.lastArticleAt }
    }

    /// Lookup a single story by id.
    public func story(id: UUID) -> Story? {
        stories[id]
    }

    // MARK: - Diff API

    /// Returns diffs for stories that received new articles since `cutoff`.
    /// Optionally filter to stories that contain `entity`.
    public func storiesSince(_ cutoff: Date, entity: String? = nil) -> [StoryDiff] {
        var candidates = stories.values.filter { $0.lastArticleAt > cutoff }
        if let entity {
            candidates = candidates.filter { $0.entities.contains(entity) }
        }

        return candidates.map { story in
            let newArticles = story.articles.filter { $0.publishedAt > cutoff }

            // Entities that appear only in the new articles.
            let entitiesBeforeCutoff: Set<String> = story.articles
                .filter { $0.publishedAt <= cutoff }
                .reduce(into: Set()) { $0.formUnion($1.extractedEntities) }
            let entitiesAfterCutoff: Set<String> = newArticles
                .reduce(into: Set()) { $0.formUnion($1.extractedEntities) }
            let newEntities = entitiesAfterCutoff.subtracting(entitiesBeforeCutoff)

            // Sentiment shift: mean polarity after cutoff minus mean before.
            let samplesAfter = story.sentimentTrajectory.filter { $0.at > cutoff }
            let samplesBefore = story.sentimentTrajectory.filter { $0.at <= cutoff }

            var sentimentShift: Double? = nil
            if !samplesAfter.isEmpty && !samplesBefore.isEmpty {
                let meanAfter = samplesAfter.map(\.polarity).reduce(0, +) / Double(samplesAfter.count)
                let meanBefore = samplesBefore.map(\.polarity).reduce(0, +) / Double(samplesBefore.count)
                sentimentShift = meanAfter - meanBefore
            }

            return StoryDiff(
                story: story,
                newArticles: newArticles,
                newEntities: newEntities,
                sentimentShift: sentimentShift
            )
        }
        .sorted { $0.story.lastArticleAt > $1.story.lastArticleAt }
    }

    // MARK: - User interaction

    /// Record that the user opened or viewed this story thread.
    public func markChecked(storyId: UUID) {
        guard stories[storyId] != nil else { return }
        stories[storyId]!.userLastCheckedAt = Date()
        scheduleWrite()
    }

    /// Permanently delete a story (user-initiated "forget").
    public func forget(storyId: UUID) {
        stories.removeValue(forKey: storyId)
        scheduleWrite()
    }

    /// Wipe all tracked stories and write an empty state to disk.
    /// Called from the Settings danger-zone "Forget everything" action.
    public func forgetAll() {
        stories.removeAll()
        scheduleWrite()
    }

    // MARK: - Clustering helpers

    /// Asymmetric containment: how much of the incoming article's entity set A
    /// is already covered by the story's entity set S.
    ///   score = |A ∩ S| / |A|
    /// Returns 0 when A is empty. Stays stable as S grows, unlike Jaccard.
    private func containment(_ a: Set<String>, _ s: Set<String>) -> Double {
        guard !a.isEmpty else { return 0 }
        return Double(a.intersection(s).count) / Double(a.count)
    }

    /// Keep only the most recent `maxArticlesPerStory` refs by `publishedAt`.
    /// Callers invoke this after mutating `articles` so subsequent work
    /// (entity re-derivation, diffs, writes) sees the capped set.
    private func trimArticles(_ articles: inout [StoryArticleRef]) {
        guard articles.count > maxArticlesPerStory else { return }
        articles.sort { $0.publishedAt > $1.publishedAt }
        articles.removeLast(articles.count - maxArticlesPerStory)
    }

    /// Derive the top-K most frequent entities across all articles in a story.
    /// Ties are broken by the entity that appeared most recently.
    /// This caps `Story.entities` to `limit` items so containment scoring
    /// remains meaningful and Jaccard-based diffs in `storiesSince` are bounded.
    private func topEntities(from articles: [StoryArticleRef], limit: Int) -> Set<String> {
        // Count occurrences and track most-recent appearance of each entity.
        var counts: [String: Int] = [:]
        var lastSeen: [String: Date] = [:]
        for article in articles {
            for entity in article.extractedEntities {
                counts[entity, default: 0] += 1
                if let prev = lastSeen[entity] {
                    if article.publishedAt > prev { lastSeen[entity] = article.publishedAt }
                } else {
                    lastSeen[entity] = article.publishedAt
                }
            }
        }
        // Sort by count desc, then by most-recent appearance desc for tie-breaking.
        let sorted = counts.keys.sorted { lhs, rhs in
            let cl = counts[lhs]!, cr = counts[rhs]!
            if cl != cr { return cl > cr }
            return (lastSeen[lhs] ?? .distantPast) > (lastSeen[rhs] ?? .distantPast)
        }
        return Set(sorted.prefix(limit))
    }

    // MARK: - Sentiment

    /// Score the polarity of `title` using NLTagger's built-in `.sentimentScore`
    /// scheme. Returns nil when the tagger produces no result (e.g., very short
    /// or non-English input). NLTagger instances are not thread-safe; each call
    /// constructs a fresh instance, which is safe because this method runs
    /// exclusively on the actor's serial executor.
    private func scoreSentiment(title: String, at date: Date) -> StorySentimentSample? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = title

        var polarity: Double? = nil
        tagger.enumerateTags(
            in: title.startIndex..<title.endIndex,
            unit: .paragraph,
            scheme: .sentimentScore,
            options: []
        ) { tag, _ in
            if let tag, let score = Double(tag.rawValue) {
                polarity = score
            }
            return false  // stop after first paragraph
        }

        guard let p = polarity else { return nil }
        return StorySentimentSample(at: date, polarity: p)
    }

    // MARK: - Eviction

    private func evictIfNeeded(now: Date) {
        // Drop stories that have been quiet for longer than quietLifetime.
        let staleThreshold = now.addingTimeInterval(-quietLifetime)
        for (id, story) in stories where story.lastArticleAt < staleThreshold {
            stories.removeValue(forKey: id)
        }

        // If still over the cap, drop oldest by lastArticleAt.
        if stories.count > maxStories {
            let sorted = stories.values.sorted { $0.lastArticleAt < $1.lastArticleAt }
            let dropCount = stories.count - maxStories
            for story in sorted.prefix(dropCount) {
                stories.removeValue(forKey: story.id)
            }
        }
    }

    // MARK: - Persistence

    private var plainFallbackURL: URL {
        storageURL.deletingPathExtension().appendingPathExtension("json")
    }

    private func scheduleWrite() {
        // Cancel any in-flight debounce task before issuing a new one.
        // Both the cancel and the Task assignment run on the actor, so there
        // is no data race on `pendingWriteTask`.
        pendingWriteTask?.cancel()
        let snapshot = Array(stories.values)
        let debounce = writeDebounce
        pendingWriteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performWrite(snapshot: snapshot)
        }
    }

    private func performWrite(snapshot: [Story]) async {
        let secure = self.securePersistence
        let encURL = self.storageURL
        let plainURL = self.plainFallbackURL

        await Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let json = try encoder.encode(snapshot)
                if let secure {
                    let encrypted = try secure.encrypt(json)
                    try encrypted.write(to: encURL, options: .atomic)
                } else {
                    try json.write(to: plainURL, options: .atomic)
                }
            } catch {
                print("[StoryTracker] save failed: \(error)")
            }
        }.value
    }

    nonisolated private static func readFromDisk(
        at encURL: URL,
        fallback: URL,
        secure: SecurePersistence?
    ) -> [UUID: Story] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try encrypted file first.
        if let secure,
           let encData = try? Data(contentsOf: encURL),
           !encData.isEmpty {
            if let json = try? secure.decrypt(encData),
               let loaded = try? decoder.decode([Story].self, from: json) {
                return Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            } else {
                print("[StoryTracker] failed to decrypt; attempting plain JSON fallback.")
            }
        }

        // Plain JSON fallback.
        guard FileManager.default.fileExists(atPath: fallback.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fallback)
            let loaded = try decoder.decode([Story].self, from: data)
            return Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        } catch {
            print("[StoryTracker] load failed: \(error)")
            return [:]
        }
    }

    /// Retroactively apply `maxArticlesPerStory` to snapshots written before
    /// the cap existed. Returns `true` iff any story was trimmed, signalling
    /// that a rewrite should be scheduled so the bloated file doesn't reload
    /// on every launch.
    nonisolated private static func compactInPlace(
        stories: inout [UUID: Story],
        maxArticlesPerStory: Int,
        maxEntitiesPerStory: Int
    ) -> Bool {
        var trimmedAny = false
        for (id, story) in stories where story.articles.count > maxArticlesPerStory {
            var updated = story
            updated.articles.sort { $0.publishedAt > $1.publishedAt }
            updated.articles.removeLast(updated.articles.count - maxArticlesPerStory)
            updated.entities = Self.topEntitiesStatic(
                from: updated.articles,
                limit: maxEntitiesPerStory
            )
            stories[id] = updated
            trimmedAny = true
        }
        return trimmedAny
    }

    nonisolated private static func topEntitiesStatic(
        from articles: [StoryArticleRef],
        limit: Int
    ) -> Set<String> {
        var counts: [String: Int] = [:]
        var lastSeen: [String: Date] = [:]
        for article in articles {
            for entity in article.extractedEntities {
                counts[entity, default: 0] += 1
                if let prev = lastSeen[entity] {
                    if article.publishedAt > prev { lastSeen[entity] = article.publishedAt }
                } else {
                    lastSeen[entity] = article.publishedAt
                }
            }
        }
        let sorted = counts.keys.sorted { lhs, rhs in
            let cl = counts[lhs] ?? 0, cr = counts[rhs] ?? 0
            if cl != cr { return cl > cr }
            return (lastSeen[lhs] ?? .distantPast) > (lastSeen[rhs] ?? .distantPast)
        }
        return Set(sorted.prefix(limit))
    }

    private func scheduleCompactRewrite() {
        scheduleWrite()
    }
}
