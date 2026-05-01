/*
 * Metamorphia
 * Settings view for place-hash labels.
 *
 * Lets the user assign short labels ("home", "office", "café") to the
 * one-way HMAC hashes that PlaceSensor derives from Wi-Fi SSIDs.
 * The top section surfaces recently-seen unlabeled hashes so new networks
 * can be tagged without scrolling through the full list.
 */

import SwiftUI

// MARK: - PlaceLabelsView

struct PlaceLabelsView: View {
    @ObservedObject private var store = PlaceLabelStore.shared

    var body: some View {
        Form {
            // Privacy note
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("Place hashes are one-way HMACs; the app never stores or logs the Wi-Fi name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Recently seen unlabeled hashes
            let unlabeled = store.recentUnlabeled()
            if !unlabeled.isEmpty {
                Section("Recently seen (unlabeled)") {
                    ForEach(unlabeled, id: \.self) { hash in
                        UnlabeledRow(hash: hash, store: store)
                    }
                }
            }

            // All labeled entries
            let labeled = store.entries.filter { !$0.label.isEmpty }
            if labeled.isEmpty && unlabeled.isEmpty {
                Section {
                    Text("No place hashes recorded yet. Turn on 'Track place' and connect to a Wi-Fi network.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else if !labeled.isEmpty {
                Section("Labeled places") {
                    ForEach(store.entries.filter { !$0.label.isEmpty }) { entry in
                        LabeledRow(entry: entry, store: store)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Place labels")
    }
}

// MARK: - UnlabeledRow

private struct UnlabeledRow: View {
    let hash: String
    let store: PlaceLabelStore

    @State private var draft: String = ""

    var body: some View {
        HStack {
            Text(hash)
                .font(.system(.body, design: .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            TextField("Label", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onSubmit { commitLabel() }
            Button("Save") { commitLabel() }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commitLabel() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.assign(label: trimmed, to: hash)
        draft = ""
    }
}

// MARK: - LabeledRow

private struct LabeledRow: View {
    let entry: PlaceLabelStore.Entry
    let store: PlaceLabelStore

    @State private var draft: String

    init(entry: PlaceLabelStore.Entry, store: PlaceLabelStore) {
        self.entry = entry
        self.store = store
        _draft = State(initialValue: entry.label)
    }

    var body: some View {
        HStack {
            TextField("Label", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitLabel() }
                .onChange(of: draft) { _ in commitLabel() }
            Spacer()
            Button("Remove", role: .destructive) {
                store.remove(id: entry.id)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
    }

    private func commitLabel() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.assign(label: trimmed, to: entry.placeHash)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PlaceLabelsView()
    }
}
