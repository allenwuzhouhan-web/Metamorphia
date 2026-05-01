/*
 * Metamorphia
 * Retrace — the temporal-recall surface inside the notch. Gives the user
 * a persistent place to search "that ESL hw yesterday night" without
 * having to re-summon the command bar. Renders RecallScenes from QueryRank.
 *
 * Siri-minimal styling per the command-bar aesthetic; regular San Francisco,
 * no monospace, opacity-based hierarchy, continuous-corner rounded rects.
 */

import SwiftUI
import MetamorphiaAgentKit

struct NotchRetraceView: View {
    @State private var query: String = ""
    @State private var scenes: [RecallScene] = []
    @State private var window: TimeWindow?
    @State private var autoNarrowed: Bool = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching: Bool = false
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            if let window {
                windowChip(window)
            } else if autoNarrowed {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text("Showing last 7 days — say 'all time' to widen")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.45))
            }
            Divider().overlay(Color.white.opacity(0.1))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { searchFieldFocused = true }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            TextField("Recall…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .focused($searchFieldFocused)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }
            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func windowChip(_ window: TimeWindow) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9))
            Text(window.reason)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(.white.opacity(0.7))
        .background(Color.white.opacity(0.07), in: Capsule())
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyPrompt
        } else if scenes.isEmpty, !isSearching {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Nothing matched “\(query)” yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 4)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(scenes) { scene in
                        sceneCard(scene)
                    }
                }
            }
        }
    }

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 4) {
                exampleRow("that esl hw yesterday night")
                exampleRow("what was I doing last Friday")
                exampleRow("the PDF I had open this morning")
                exampleRow("clips from this week")
            }
        }
    }

    private func exampleRow(_ text: String) -> some View {
        Button {
            query = text
            scheduleSearch(text)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scene card

    private func sceneCard(_ scene: RecallScene) -> some View {
        let hero = scene.hero
        return Button {
            // Tap: record feedback, then open the hero's resource.
            Task { await recordTap(hero, query: query) }
            openHero(hero)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: hero.item.kind.displaySymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hero.item.title ?? "(untitled)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let reason = scene.anchorReason {
                            Text(reason)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(relativeTime(hero.item.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }

                let snippet = String(hero.item.body.prefix(140))
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if scene.members.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(Array(scene.members.dropFirst().prefix(4).enumerated()), id: \.offset) { _, sibling in
                            HStack(spacing: 4) {
                                Image(systemName: sibling.item.kind.displaySymbol)
                                    .font(.system(size: 9))
                                Text(sibling.item.title?.prefix(28).description ?? sibling.item.appBundleID ?? "item")
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.white.opacity(0.06), in: Capsule())
                            .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Search dispatch

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            scenes = []
            window = nil
            autoNarrowed = false
            return
        }
        isSearching = true
        searchTask = Task { [query = trimmed] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let result = await RetraceSurface.shared.search(query)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.scenes = result?.scenes ?? []
                self.window = result?.window
                self.autoNarrowed = result?.autoNarrowed ?? false
                self.isSearching = false
            }
        }
    }

    private func openHero(_ hit: SearchHit) {
        // File → reveal; browser → open URL; screen → flash reminder.
        if hit.item.kind == .file, let path = hit.item.docPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let urlString = hit.item.url, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func recordTap(_ hit: SearchHit, query: String) async {
        let rank = await RetraceSurface.shared.queryRank
        await rank?.recordTap(rowid: hit.rowid, query: query)
    }
}
