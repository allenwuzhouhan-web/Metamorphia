/*
 * Metamorphia
 * NewsTabModel — view-model for the News tab.
 * Pulls scored proposals from ThreadContinuationEngine; exposes a one-shot
 * explore path via GoogleNewsService. Never auto-polls — that is the engine's
 * concern. Manual refresh only.
 */

import SwiftUI
import MetamorphiaAgentKit
import MetamorphiaExecutors

@MainActor
final class NewsTabModel: ObservableObject {

    static let shared = NewsTabModel()

    @Published private(set) var proposals: [ContinuationProposal] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var selectedStoryId: UUID? = nil
    @Published private(set) var exploreResults: [NewsArticle] = []
    @Published private(set) var isExploring: Bool = false
    @Published private(set) var exploreError: String? = nil

    private var continuation: ThreadContinuationEngine?
    private var stories: StoryTracker?
    private var newsService: GoogleNewsService?

    private init() {}

    // MARK: - Configuration

    func configure(
        continuation: ThreadContinuationEngine,
        stories: StoryTracker,
        newsService: GoogleNewsService
    ) {
        self.continuation = continuation
        self.stories = stories
        self.newsService = newsService
    }

    // MARK: - Thread count

    /// Number of distinct entities across all proposals — used for the header label.
    var threadCount: Int {
        let entities = proposals.compactMap { $0.primaryEntity }
        return Set(entities).count
    }

    // MARK: - Refresh

    func refreshNow() async {
        guard let engine = continuation, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        proposals = await engine.propose(since: cutoff, maxResults: 15)
    }

    // MARK: - Selection

    func select(storyId: UUID) {
        selectedStoryId = storyId
    }

    func clearSelection() {
        selectedStoryId = nil
    }

    // MARK: - Explore

    func explore(query: String) async {
        guard let service = newsService else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isExploring = true
        exploreError = nil
        defer { isExploring = false }
        do {
            exploreResults = try await service.search(query: trimmed)
        } catch {
            exploreError = error.localizedDescription
            exploreResults = []
        }
    }

    func clearExploreResults() {
        exploreResults = []
        exploreError = nil
    }

    // MARK: - Story lookup

    func story(for id: UUID) async -> Story? {
        await stories?.story(id: id)
    }

    func markChecked(storyId: UUID) async {
        await stories?.markChecked(storyId: storyId)
    }
}
