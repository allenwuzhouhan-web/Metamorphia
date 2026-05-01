import Defaults
import SwiftUI
import UniformTypeIdentifiers

extension Defaults.Keys {
    static let presentationTasteLearningEnabled = Key<Bool>("presentationTasteLearningEnabled", default: true)
    static let presentationTastePowerPointEnabled = Key<Bool>("presentationTastePowerPointEnabled", default: true)
    static let presentationTasteAskBeforeModelAnalysis = Key<Bool>("presentationTasteAskBeforeModelAnalysis", default: true)
}

struct DesignLanguageSettingsView: View {
    @Default(.presentationTasteLearningEnabled) private var learningEnabled
    @Default(.presentationTastePowerPointEnabled) private var powerPointEnabled
    @Default(.presentationTasteAskBeforeModelAnalysis) private var askBeforeModelAnalysis

    @State private var snapshot = PresentationTasteSnapshot()
    @State private var importing = false
    @State private var pendingImportURL: URL?
    @State private var showConsent = false
    @State private var showInspector = false
    @State private var showForgetConfirmation = false
    @State private var statusMessage: String?
    @State private var isImporting = false

    var body: some View {
        header
        controls
        profileStatus
        referenceDecks
        dangerZone
            .task { await refresh() }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: powerpointTypes,
                allowsMultipleSelection: true
            ) { result in
                handleImportResult(result)
            }
            .alert("Analyze deck metadata?", isPresented: $showConsent) {
                Button("Local only") {
                    Task { await importPendingDeck(allowModelAnalysis: false) }
                }
                Button("Allow model analysis") {
                    Task { await importPendingDeck(allowModelAnalysis: true) }
                }
                Button("Cancel", role: .cancel) {
                    pendingImportURL = nil
                }
            } message: {
                Text("Metamorphia always extracts local design metadata first. Allow model analysis only if this deck’s extracted metadata may be sent to your configured model for stronger style language.")
            }
            .sheet(isPresented: $showInspector) {
                PresentationTasteInspector(snapshot: snapshot)
                    .frame(minWidth: 520, minHeight: 480)
            }
            .alert("Forget design language?", isPresented: $showForgetConfirmation) {
                Button("Forget design language", role: .destructive) {
                    Task { await forgetAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes uploaded deck metadata and the learned PowerPoint design profile. Raw deck files are not stored.")
            }
    }

    private var header: some View {
        Section {
            HStack {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(.tint)
                Text("Design Language")
                    .font(.headline)
                Spacer()
            }
            Text("Learn a reusable PowerPoint presentation style from favorite decks, preview a redesign, then apply it to the open deck.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        Section("Learning") {
            Toggle("Learn from uploaded decks", isOn: $learningEnabled)
            Toggle("Use my design language in PowerPoint", isOn: $powerPointEnabled)
            Toggle("Ask before model analysis", isOn: $askBeforeModelAnalysis)

            HStack {
                Button {
                    importing = true
                } label: {
                    Label("Upload PowerPoint deck", systemImage: "square.and.arrow.up")
                }
                .disabled(!learningEnabled || isImporting)

                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var profileStatus: some View {
        Section("Active profile") {
            if let profile = snapshot.activeProfile {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(profile.deckCount) deck(s) learned · last updated \(profile.learnedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Inspect") {
                        showInspector = true
                    }
                }

                HStack(spacing: 8) {
                    ForEach(profile.palette.prefix(6), id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(color(from: hex))
                            .frame(width: 28, height: 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }
                    Text("\(profile.titleFont) / \(profile.bodyFont)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(
                    "No design language yet",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Upload a .pptx or .ppt reference deck to learn palette, typography, spacing, motifs, and density.")
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var referenceDecks: some View {
        Section("Reference decks") {
            if snapshot.samples.isEmpty {
                Text("No uploaded deck metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.samples) { sample in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.fileName)
                            Text("\(sample.slideCount == 0 ? "Legacy binary deck" : "\(sample.slideCount) slide(s)") · \(sample.allowModelAnalysis ? "model analysis allowed" : "local only")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await prune(sample.id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var dangerZone: some View {
        Section("Danger zone") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forget design language")
                    Text("Deletes extracted deck metadata and the active profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Forget", role: .destructive) {
                    showForgetConfirmation = true
                }
                .foregroundStyle(.red)
                .disabled(snapshot.samples.isEmpty && snapshot.activeProfile == nil)
            }
        }
    }

    private var powerpointTypes: [UTType] {
        [
            UTType(filenameExtension: "pptx") ?? .presentation,
            UTType(filenameExtension: "ppt") ?? .presentation
        ]
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            if askBeforeModelAnalysis {
                pendingImportURL = first
                showConsent = true
            } else {
                pendingImportURL = first
                Task { await importPendingDeck(allowModelAnalysis: false) }
            }
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importPendingDeck(allowModelAnalysis: Bool) async {
        guard let url = pendingImportURL,
              let store = MetamorphiaBootstrap.presentationTasteStore else { return }
        pendingImportURL = nil
        isImporting = true
        statusMessage = nil
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            isImporting = false
        }
        do {
            let sample = try await PowerPointDeckStyleExtractor.extractSample(
                from: url,
                allowModelAnalysis: allowModelAnalysis
            )
            _ = await store.addOrUpdate(sample: sample)
            statusMessage = "Learned design metadata from \(sample.fileName)."
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func prune(_ id: UUID) async {
        await MetamorphiaBootstrap.presentationTasteStore?.pruneDeck(id: id)
        await refresh()
    }

    @MainActor
    private func forgetAll() async {
        await MetamorphiaBootstrap.presentationTasteStore?.forgetAll()
        await refresh()
    }

    @MainActor
    private func refresh() async {
        snapshot = await MetamorphiaBootstrap.presentationTasteStore?.snapshot() ?? PresentationTasteSnapshot()
    }

    private func color(from hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let raw = Int(cleaned, radix: 16) else {
            return .secondary.opacity(0.35)
        }
        return Color(
            red: Double((raw >> 16) & 0xFF) / 255.0,
            green: Double((raw >> 8) & 0xFF) / 255.0,
            blue: Double(raw & 0xFF) / 255.0
        )
    }
}

private struct PresentationTasteInspector: View {
    let snapshot: PresentationTasteSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Design Language")
                    .font(.title2.weight(.semibold))

                if let profile = snapshot.activeProfile {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Profile")
                            .font(.headline)
                        Text(profile.promptSummary)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Deck metadata")
                        .font(.headline)
                    ForEach(snapshot.samples) { sample in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sample.fileName)
                                .font(.subheadline.weight(.semibold))
                            Text("Slides: \(sample.slideCount)")
                            Text("Fonts: \(sample.typography.prefix(6).map { "\($0.name) \(Int($0.size))pt" }.joined(separator: ", "))")
                            Text("Colors: \(sample.colors.prefix(8).map { "#\($0)" }.joined(separator: ", "))")
                        }
                        .font(.caption)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
