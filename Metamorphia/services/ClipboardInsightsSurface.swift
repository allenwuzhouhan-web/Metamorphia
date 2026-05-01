/*
 * Metamorphia
 * Continuum Phase 8 — Clipboard enrichment surface.
 *
 * Observes `continuumEntitiesExtracted` notifications whose source is
 * `.clipboard`, checks whether any extracted entity scores above 0.3 in the
 * interest graph, finds the most-recent matching story via `StoryTracker`, and
 * then asks `ThreadContinuationEngine` whether a continuation proposal scores
 * above 0.2. If all gates pass and AttentionModel allows it, a
 * `ClipboardThreadHint` is published for the notch to render.
 *
 * Kept separate from `MarketQuoteMonitor` so market-lens behaviour is
 * unaffected. Does NOT run entity extraction — all entity data arrives from the
 * notification, which `ClipboardInsights` (Phase 1) already produced.
 *
 * Invariants:
 *  - Singleton is inert until `start(interestGraph:stories:continuation:)`.
 *  - Hints auto-dismiss after 18 seconds via a cancellable Task.
 *  - Dedupe: a second notification for the same `clipboardItemId` is ignored.
 *  - AttentionModel gate: if `currentScore < 0.5` the hint is suppressed.
 */

import Foundation
import Combine
import Defaults
import MetamorphiaAgentKit

// MARK: - ClipboardThreadHint

/// A surfaced continuation proposal triggered by clipboard content.
public struct ClipboardThreadHint: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID { proposalId }
    public let proposalId: UUID
    /// The top-scored entity from the interest graph that triggered this hint.
    public let primaryEntity: String
    /// Story title for the matched narrative.
    public let storyTitle: String
    /// Outlet / source string from the most recent article in the story.
    public let source: String
    /// Timestamp of the most recent article in the story.
    public let publishedAt: Date
    /// One-line reason string ready to render, e.g. "continues your Anthropic thread".
    public let reason: String
    /// Dedupe key — the clipboard item that triggered this hint.
    public let clipboardItemId: UUID
}

// MARK: - ClipboardInsightsSurface

@MainActor
public final class ClipboardInsightsSurface: ObservableObject {

    public static let shared = ClipboardInsightsSurface()

    @Published public private(set) var currentHint: ClipboardThreadHint?

    // MARK: - Private state

    private var notificationCancellable: AnyCancellable?
    private var dismissTask: Task<Void, Never>?

    private static let autoDismissInterval: TimeInterval = 18
    private static let interestGateThreshold: Double = 0.3
    private static let continuationGateThreshold: Double = 0.2
    private static let attentionGateThreshold: Double = 0.5
    private static let storyRecencyWindow: TimeInterval = 7 * 86_400

    private init() {}

    // MARK: - Bootstrap entry point

    /// Wire up stores and begin observing clipboard entity notifications.
    /// Must be called exactly once from MetamorphiaBootstrap after ClipboardInsights
    /// is started.
    public func start(
        interestGraph: InterestGraphStore,
        stories: StoryTracker,
        continuation: ThreadContinuationEngine
    ) {
        guard notificationCancellable == nil else { return }   // idempotent

        notificationCancellable = NotificationCenter.default
            .publisher(for: .continuumEntitiesExtracted)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard notification.continuumSource == .clipboard else { return }
                Task { @MainActor in
                    await self.handleNotification(
                        notification,
                        interestGraph: interestGraph,
                        stories: stories,
                        continuation: continuation
                    )
                }
            }
    }

    // MARK: - Dismissal

    /// Explicitly dismiss the current hint. Records an attention engagement signal.
    public func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        currentHint = nil
        AttentionModel.shared.recordSurfaceDismissal()
    }

    // MARK: - Notification handling

    private func handleNotification(
        _ notification: Notification,
        interestGraph: InterestGraphStore,
        stories: StoryTracker,
        continuation: ThreadContinuationEngine
    ) async {
        // Master news gate and clipboard enrichment sub-flag.
        guard Defaults[.newsEnabled] && Defaults[.newsClipboardEnrichmentEnabled] else { return }

        guard let entities = notification.continuumEntities, !entities.isEmpty else { return }
        guard let text = notification.continuumText else { return }
        guard let clipboardItemId = notification.continuumClipboardItemId else { return }

        // Dedupe: skip if we are already showing a hint for this clipboard item.
        if currentHint?.clipboardItemId == clipboardItemId { return }

        // Market-hint collision suppression: if MarketQuoteMonitor already has a
        // clipboard suggestion for this same item (e.g. the user copied "NVDA"),
        // the market hint is more specific — skip the thread hint entirely.
        if MarketQuoteMonitor.shared.clipboardSuggestion?.clipboardItemId == clipboardItemId { return }

        // Attention gate: suppress when the user is not in an active window.
        let attentionScore = AttentionModel.shared.currentScore
        guard attentionScore >= Self.attentionGateThreshold else { return }

        // Interest gate: find the top-scored entity above the threshold.
        var topEntityName: String?
        var topScore: Double = 0

        for entity in entities {
            let s = await interestGraph.score(entity: entity.canonicalName)
            if s > topScore {
                topScore = s
                topEntityName = entity.canonicalName
            }
        }

        guard topScore > Self.interestGateThreshold, let primaryEntity = topEntityName else { return }

        // Story recency gate: find the most-recent story about the primary entity
        // published within the last 7 days.
        let cutoff = Date().addingTimeInterval(-Self.storyRecencyWindow)
        let candidateStories = await stories.stories(about: primaryEntity)
        guard let targetStory = candidateStories.first(where: { $0.lastArticleAt > cutoff }) else {
            return
        }

        // Continuation scoring: ask the engine whether this story is relevant
        // given the clipboard text as pseudo turn context and the extracted entities.
        let recentTurnEntities = Set(entities.map { $0.canonicalName })
        let proposal = await continuation.score(
            story: targetStory,
            recentTurnText: text,
            recentTurnEntities: recentTurnEntities
        )

        guard proposal.score > Self.continuationGateThreshold else { return }

        // Build the reason string. Prefer the engine's first reason when available;
        // fall back to a generic "continues your <entity> thread" line.
        let reason: String
        if let engineReason = proposal.reasons.first {
            reason = engineReason
        } else {
            reason = "continues your \(primaryEntity) thread"
        }

        // Pick the most-recent article for display metadata.
        let latestArticle = targetStory.articles.max(by: { $0.publishedAt < $1.publishedAt })

        let hint = ClipboardThreadHint(
            proposalId: UUID(),
            primaryEntity: primaryEntity,
            storyTitle: targetStory.title,
            source: latestArticle?.source ?? "",
            publishedAt: targetStory.lastArticleAt,
            reason: reason,
            clipboardItemId: clipboardItemId
        )

        currentHint = hint
        scheduleAutoDismiss()
    }

    // MARK: - Auto-dismiss timer

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.autoDismissInterval * 1_000_000_000))
                // Surface timed out — record as ignored, not dismissed.
                if currentHint != nil {
                    currentHint = nil
                    AttentionModel.shared.recordSurfaceIgnored()
                }
            } catch {
                // Task cancelled by explicit dismiss() — nothing to do.
            }
        }
    }
}
