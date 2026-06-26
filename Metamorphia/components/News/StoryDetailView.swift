/*
 * Metamorphia
 * StoryDetailView — inline article list for a single story thread.
 * Shown inside NotchNewsView when the user taps a proposal row.
 * Not a modal; back button calls model.clearSelection().
 */

import SwiftUI
import AppKit
import MetamorphiaAgentKit

struct StoryDetailView: View {

    let proposal: ContinuationProposal
    @ObservedObject private var model = NewsTabModel.shared

    // Full story is loaded asynchronously from StoryTracker.
    @State private var story: Story? = nil

    private static let fluidSpring = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let story {
                diffSummary(story: story)
                articleList(story: story)
                footer(story: story)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            story = await model.story(for: proposal.id)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(Self.fluidSpring) {
                    model.clearSelection()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.story.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                if let entity = proposal.primaryEntity {
                    Text(entity)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Diff summary

    private func diffSummaryLabel(story: Story) -> String {
        let newCount = newArticleCount(story: story)
        if story.userLastCheckedAt != nil {
            return newCount == 0
                ? "No new articles since your last check"
                : "\(newCount) article\(newCount == 1 ? "" : "s") since your last check"
        } else {
            return "First time viewing this thread"
        }
    }

    private func diffSummary(story: Story) -> some View {
        Text(diffSummaryLabel(story: story))
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 4)
    }

    private func newArticleCount(story: Story) -> Int {
        guard let checked = story.userLastCheckedAt else { return story.articles.count }
        return story.articles.filter { $0.publishedAt > checked }.count
    }

    // MARK: - Article list

    private func articleList(story: Story) -> some View {
        let sorted = story.articles.sorted { $0.publishedAt > $1.publishedAt }
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(sorted.enumerated()), id: \.element.articleId) { _, article in
                    articleRow(article: article, story: story)
                }
            }
        }
        .frame(maxHeight: 140)
    }

    private func articleRow(article: StoryArticleRef, story: Story) -> some View {
        let isNew: Bool = {
            guard let checked = story.userLastCheckedAt else { return true }
            return article.publishedAt > checked
        }()

        return Button {
            // articleId comes from untrusted feed data; only open web URLs.
            if let url = URL(string: article.articleId),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title)
                        .font(.system(size: 11, weight: isNew ? .semibold : .regular))
                        .foregroundStyle(isNew ? .white.opacity(0.9) : .white.opacity(0.6))
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
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isNew ? Color.white.opacity(0.05) : Color.white.opacity(0.02))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private func footer(story: Story) -> some View {
        Button {
            Task { @MainActor in
                await model.markChecked(storyId: story.id)
                // Reload story so the diff summary updates.
                self.story = await model.story(for: proposal.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10))
                Text("Mark checked")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
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
