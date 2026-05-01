/*
 * Metamorphia
 * NotchNewsView — News tab rendered inside the notch when
 * `coordinator.currentView == .news`.
 *
 * Only surfaces stories that ThreadContinuationEngine has scored — never
 * arbitrary trending content. Empty state offers a one-shot explore field.
 * Mirrors NotchMarketsView visual register.
 */

import AppKit
import SwiftUI
import MetamorphiaAgentKit
import MetamorphiaExecutors

@MainActor
struct NotchNewsView: View {

    @StateObject private var model = NewsTabModel.shared

    @State private var exploreInput: String = ""

    private static let fluidSpring = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0)

    var body: some View {
        ZStack {
            if let selectedId = model.selectedStoryId,
               let proposal = model.proposals.first(where: { $0.id == selectedId }) {
                StoryDetailView(proposal: proposal)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                listView
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(Self.fluidSpring, value: model.selectedStoryId)
        .task {
            if model.proposals.isEmpty && !model.isRefreshing {
                await model.refreshNow()
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.proposals.isEmpty {
                emptyState
            } else {
                proposalList
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            let count = model.threadCount
            Text(count == 0 ? "News" : "Following \(count) thread\(count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
            } else {
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Proposal list

    private var proposalList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.proposals) { proposal in
                    proposalRow(proposal)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func proposalRow(_ proposal: ContinuationProposal) -> some View {
        Button {
            withAnimation(Self.fluidSpring) {
                model.select(storyId: proposal.id)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.story.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                    if let reason = proposal.reasons.first {
                        Text(reason)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        if let source = proposal.story.articles.first?.source {
                            Text(source)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                        Text(relativeTime(proposal.story.lastArticleAt))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing new on your threads.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Stories appear when they continue a topic you follow.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
            .padding(.vertical, 4)

            exploreBar

            if model.isExploring {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.5))
                    Text("Searching…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 2)
            } else if let error = model.exploreError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineLimit(2)
                    .padding(.top, 2)
            } else if !model.exploreResults.isEmpty {
                exploreResultsList
            }
        }
    }

    private var exploreBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            TextField(
                "",
                text: $exploreInput,
                prompt: Text("Explore a topic")
                    .foregroundColor(.white.opacity(0.35))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .onSubmit {
                let query = exploreInput
                Task { await model.explore(query: query) }
            }
            if !exploreInput.isEmpty {
                Button {
                    exploreInput = ""
                    model.clearExploreResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var exploreResultsList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.exploreResults.prefix(8)) { article in
                    exploreRow(article)
                }
            }
        }
        .frame(maxHeight: 120)
    }

    private func exploreRow(_ article: NewsArticle) -> some View {
        Button {
            if let url = URL(string: article.link) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Text(article.source)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                        Text(relativeTime(article.publishedAt))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        switch interval {
        case ..<60:
            return "just now"
        case ..<3600:
            let m = Int(interval / 60)
            return "\(m)m ago"
        case ..<86_400:
            let h = Int(interval / 3600)
            return "\(h)h ago"
        default:
            let d = Int(interval / 86_400)
            return "\(d)d ago"
        }
    }
}
