import SwiftUI

/// ASCII-art monospaced agent tree rendered above the response area while an
/// agent run is in flight. Goal: a 3-6 line block that reads at a glance as:
///
///     Oracle
///     ├─ Scout    fetching reuters.com
///     └─ Scribe   drafting the response
///
/// The *active* sub-agent's tagline is swapped for its live-status string so
/// the tree doubles as a progress indicator with zero extra vertical cost.
struct AgentTreeView: View {
    let tree: AgentTreeSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(flatten(), id: \.rowId) { row in
                row.view
            }
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Flattening

    /// One rendered line.
    private struct Row {
        let rowId: String
        let view: AnyView
    }

    private func flatten() -> [Row] {
        var rows: [Row] = []
        // Root — bold name, no tagline.
        rows.append(Row(rowId: tree.root.id, view: AnyView(rootLabel(tree.root))))
        let kids = tree.root.children
        for (idx, child) in kids.enumerated() {
            let isLast = idx == kids.count - 1
            rows.append(Row(
                rowId: child.id,
                view: AnyView(childLabel(child, connector: isLast ? "└─" : "├─"))
            ))
        }
        return rows
    }

    // MARK: - Row views

    private func rootLabel(_ node: AgentNode) -> some View {
        HStack(spacing: 0) {
            Text(node.identity.displayName)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(color(for: node.state).opacity(node.state == .running ? 1 : 0.9))
            Spacer(minLength: 0)
        }
    }

    private func childLabel(_ node: AgentNode, connector: String) -> some View {
        let tagline = node.liveStatus ?? node.identity.tagline
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(connector) ")
                .foregroundStyle(Color.white.opacity(0.35))
            Text(paddedName(node.identity.displayName))
                .foregroundStyle(color(for: node.state))
            Text(tagline)
                .foregroundStyle(taglineColor(for: node.state))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Styling

    /// Pad the name to a fixed 9-character column so taglines line up
    /// vertically across siblings — "Scout", "Scribe", "Curator" all start the
    /// tagline at the same x-coordinate.
    private func paddedName(_ name: String) -> String {
        let width = 9
        if name.count >= width { return name + " " }
        return name + String(repeating: " ", count: width - name.count)
    }

    private func color(for state: AgentNodeState) -> Color {
        switch state {
        case .pending: return Color.white.opacity(0.45)
        case .running: return Color.white
        case .done:    return Color.green.opacity(0.6)
        case .failed:  return Color.orange
        }
    }

    private func taglineColor(for state: AgentNodeState) -> Color {
        switch state {
        case .pending: return Color.white.opacity(0.30)
        case .running: return Color.white.opacity(0.70)
        case .done:    return Color.green.opacity(0.45)
        case .failed:  return Color.orange.opacity(0.70)
        }
    }
}
