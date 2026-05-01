/*
 * Metamorphia
 * Continuum Phase 13 — Interest graph inspector.
 *
 * Presented as a sheet from ContinuumSettingsView when the user taps
 * "Inspect interest graph". Shows the top-50 tracked entities with their
 * weights, types, and last-seen timestamps. Each row has a Forget button
 * so the user can prune individual entries.
 */

import MetamorphiaAgentKit
import SwiftUI

// MARK: - InterestGraphInspector

struct InterestGraphInspector: View {

    @Environment(\.dismiss) private var dismiss

    @State private var nodes: [InterestNode] = []
    @State private var filter: EntityType? = nil
    @State private var totalCount: Int = 0

    private static let topCount = 50

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("What Metamorphia thinks you care about")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // Filter picker
            Picker("Filter", selection: $filter) {
                Text("All").tag(Optional<EntityType>.none)
                Text("Org").tag(Optional<EntityType>.some(.org))
                Text("Person").tag(Optional<EntityType>.some(.person))
                Text("Ticker").tag(Optional<EntityType>.some(.ticker))
                Text("Topic").tag(Optional<EntityType>.some(.topic))
                Text("Place").tag(Optional<EntityType>.some(.place))
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // Node list
            if nodes.isEmpty {
                Spacer()
                Text("Nothing tracked yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredNodes) { node in
                    NodeRow(node: node) {
                        prune(entity: node.entityId)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer
            HStack {
                Text("\(totalCount) item\(totalCount == 1 ? "" : "s") tracked. Weights decay over 21 days if not reinforced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 520)
        .task { await loadNodes() }
        .onChange(of: filter) { _ in Task { await loadNodes() } }
    }

    // MARK: - Filtered view

    private var filteredNodes: [InterestNode] {
        guard let type = filter else { return nodes }
        return nodes.filter { $0.type == type }
    }

    // MARK: - Data loading

    private func loadNodes() async {
        guard let graph = MetamorphiaBootstrap.interestGraph else { return }
        let top = await graph.topInterests(count: Self.topCount)
        let count = await graph.nodeCount()
        await MainActor.run {
            self.nodes = top
            self.totalCount = count
        }
    }

    // MARK: - Prune

    private func prune(entity: String) {
        Task {
            await MetamorphiaBootstrap.interestGraph?.prune(entity: entity)
            await loadNodes()
        }
    }
}

// MARK: - NodeRow

private struct NodeRow: View {

    let node: InterestNode
    let onForget: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Type badge
            Text(typeBadge)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)

            // Entity name
            Text(node.entityId)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Weight bar
            weightBar

            // Last seen
            Text(relativeDate(node.lastSeen))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            // Forget button
            Button("Forget") { onForget() }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .opacity(isHovered ? 1 : 0.4)
        }
        .onHover { hovering in isHovered = hovering }
    }

    private var typeBadge: String {
        switch node.type {
        case .org:    return "org"
        case .person: return "person"
        case .ticker: return "ticker"
        case .topic:  return "topic"
        case .place:  return "place"
        case .url:    return "url"
        case .paper:  return "paper"
        case .repo:   return "repo"
        }
    }

    private var weightBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(node.weight.value))
            }
        }
        .frame(width: 60, height: 6)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - InterestNode + Identifiable

extension InterestNode: Identifiable {
    public var id: String { entityId }
}
