/*
 * Metamorphia
 * Retrace Settings — per-source toggles, retention, storage stats, and
 * "forget" controls. All ingestion is local-only; the master toggle
 * (retraceIngestionEnabled) pauses every archiver at once.
 */

import SwiftUI
import Defaults
import MetamorphiaAgentKit
import MetamorphiaPerception

struct RetraceSettingsView: View {
    @Default(.retraceIngestionEnabled) private var masterEnabled
    @Default(.retraceScreenEnabled) private var screenEnabled
    @Default(.retraceFilesEnabled) private var filesEnabled
    @Default(.retraceClipboardEnabled) private var clipboardEnabled
    @Default(.retraceBrowserEnabled) private var browserEnabled
    @Default(.retraceMessagesEnabled) private var messagesEnabled
    @Default(.retraceMailEnabled) private var mailEnabled
    @Default(.retraceCalendarEnabled) private var calendarEnabled
    @Default(.retraceAgentTurnsEnabled) private var agentTurnsEnabled
    @Default(.retraceRetentionDays) private var retentionDays

    @Default(.retraceWatchDocuments) private var watchDocuments
    @Default(.retraceWatchDownloads) private var watchDownloads
    @Default(.retraceWatchDesktop) private var watchDesktop
    @Default(.retraceWatchICloud) private var watchICloud

    @State private var stats: RetraceIndex.Stats?
    @State private var forgetQuery: String = ""
    @State private var forgetResult: String?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("Enable Retrace indexing", isOn: $masterEnabled)
                Text("Retrace indexes what you see and do locally on your Mac, so you can recall things by saying 'that ESL hw yesterday night' or 'the bug I was chasing last Friday.' Nothing leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sources") {
                Toggle("Screen (accessibility tree)", isOn: $screenEnabled)
                    .onChange(of: screenEnabled) { _, newValue in
                        if newValue && AXIsProcessTrusted() {
                            ScreenHarvest.shared.start()
                        } else {
                            ScreenHarvest.shared.stop()
                        }
                    }
                Text("Reads the focused window's text from the macOS accessibility tree. No screenshots. 1Password, Keychain, Private Browsing, and password fields are always excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Files in watched folders", isOn: $filesEnabled)
                Toggle("Clipboard", isOn: $clipboardEnabled)
                Toggle("Browser pages", isOn: $browserEnabled)
                Toggle("Messages (requires Full Disk Access)", isOn: $messagesEnabled)
                Toggle("Mail (requires Full Disk Access)", isOn: $mailEnabled)
                Toggle("Calendar", isOn: $calendarEnabled)
                Toggle("Agent conversation turns", isOn: $agentTurnsEnabled)
            }

            Section("Watched folders") {
                Toggle("Documents", isOn: $watchDocuments)
                Toggle("Downloads", isOn: $watchDownloads)
                Toggle("Desktop", isOn: $watchDesktop)
                Toggle("iCloud Drive", isOn: $watchICloud)
                Text("PDFs, text, markdown, code, RTF, and images (OCR). Audio transcription is opt-in elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Retention") {
                // Step grid aligned so the persisted default (60 days, defined
                // in RetraceDefaults) lands ON the grid (fix #10). The previous
                // `step: 7` grid (7, 14, … 63) skipped 60, so the very first
                // step from the default produced an off-grid value.
                Stepper(value: $retentionDays, in: 5...365, step: 5) {
                    HStack {
                        Text("Keep indexed items for")
                        Spacer()
                        Text("\(retentionDays) days")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Prune now") {
                    Task { await pruneNow() }
                }
            }

            Section("Storage") {
                if let s = stats {
                    HStack {
                        Text("Indexed items")
                        Spacer()
                        Text("\(s.totalItems)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Embeddings")
                        Spacer()
                        Text("\(s.totalEmbeddings)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Entities")
                        Spacer()
                        Text("\(s.totalEntities)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Database size")
                        Spacer()
                        Text(formatBytes(s.dbSizeBytes))
                            .foregroundStyle(.secondary)
                    }
                    if !s.itemsByKind.isEmpty {
                        ForEach(ItemKind.allCases, id: \.self) { kind in
                            if let count = s.itemsByKind[kind], count > 0 {
                                HStack {
                                    Image(systemName: kind.displaySymbol)
                                    Text(kind.displayName)
                                    Spacer()
                                    Text("\(count)")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                        }
                    }
                } else {
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
                Button("Refresh stats") {
                    refreshStats()
                }
            }

            Section("Forget") {
                TextField("Entity or keyword to forget (e.g. 'project alpha')", text: $forgetQuery)
                Button(role: .destructive) {
                    Task { await forgetEntity() }
                } label: {
                    Text("Forget")
                }
                .disabled(forgetQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let result = forgetResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await clearAll() }
                } label: {
                    Text("Clear all Retrace data")
                }
                Text("This is permanent. The index, embeddings, and file watermarks will all be deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshStats() }
    }

    // MARK: - Actions

    @MainActor
    private func refreshStats() {
        refreshTask?.cancel()
        refreshTask = Task {
            let s = RetraceSurface.shared.index?.stats()
            await MainActor.run { self.stats = s }
        }
    }

    @MainActor
    private func pruneNow() async {
        guard let idx = RetraceSurface.shared.index else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let removed = idx.pruneOlderThan(cutoff)
        idx.vacuumIncremental()
        forgetResult = "Pruned \(removed) items."
        refreshStats()
    }

    @MainActor
    private func forgetEntity() async {
        let q = forgetQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return }
        guard let idx = RetraceSurface.shared.index else { return }
        let removed = idx.deleteItemsWithEntity(canonical: q)
        forgetResult = "Removed \(removed) items tagged '\(q)'."
        forgetQuery = ""
        refreshStats()
    }

    @MainActor
    private func clearAll() async {
        RetraceSurface.shared.index?.clearAll()
        forgetResult = "All Retrace data cleared."
        refreshStats()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

private extension ItemKind {
    var displayName: String {
        switch self {
        case .screen:    return "Screen frames"
        case .file:      return "Files"
        case .clip:      return "Clipboard"
        case .browser:   return "Browser pages"
        case .message:   return "Messages"
        case .email:     return "Mail"
        case .calendar:  return "Calendar"
        case .agentTurn: return "Agent turns"
        }
    }
}
