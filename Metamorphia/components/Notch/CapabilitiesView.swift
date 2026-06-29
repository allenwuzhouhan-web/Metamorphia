/*
 * Metamorphia
 * Capabilities — browse active and deferred tools in the notch.
 * Groups tools by category. Deferred MCP tools can be promoted
 * to active with a single tap.
 */

import SwiftUI
import MetamorphiaAgentKit

/// Notch panel that shows all registered tools grouped by category.
/// Active tools are ready for the LLM to use; deferred tools (usually
/// MCP-discovered ones) can be enabled individually with the Enable button.
struct CapabilitiesView: View {

    @State private var activeSections: [CapabilitySection] = []
    @State private var deferredRows: [DeferredRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Color.white.opacity(0.1))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Text("Capabilities")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            let total = activeSections.reduce(0) { $0 + $1.names.count }
            Text("\(total) active")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Active tools by category
                ForEach(activeSections, id: \.category) { section in
                    categorySection(section)
                }

                // Deferred tools
                if !deferredRows.isEmpty {
                    deferredSection
                }
            }
        }
    }

    // MARK: - Active section

    private func categorySection(_ section: CapabilitySection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.category.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.5)

            FlowLayout(spacing: 6) {
                ForEach(section.names, id: \.self) { name in
                    toolChip(name)
                }
            }
        }
    }

    private func toolChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.07), in: Capsule())
    }

    // MARK: - Deferred section

    private var deferredSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available (tap to enable)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(deferredRows, id: \.name) { row in
                    deferredRow(row)
                }
            }
        }
    }

    private func deferredRow(_ row: DeferredRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if !row.description.isEmpty {
                    Text(row.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Button {
                promote(row.name)
            } label: {
                Text("Enable")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    // MARK: - Data refresh

    private func reload() {
        guard let registry = MetamorphiaBootstrap.registry else { return }

        // Active tools grouped by category
        let names = registry.allToolNames()
        var byCategory: [ToolCategory: [String]] = [:]
        for name in names {
            let cat = registry.categoryForTool(name) ?? .files
            byCategory[cat, default: []].append(name)
        }
        activeSections = byCategory
            .map { CapabilitySection(category: $0.key, names: $0.value.sorted()) }
            .sorted { $0.category.displayName < $1.category.displayName }

        // Deferred tools
        deferredRows = registry.deferredToolSummaries()
            .map { DeferredRow(name: $0.name, description: $0.description) }
    }

    private func promote(_ name: String) {
        guard let registry = MetamorphiaBootstrap.registry else { return }
        registry.promoteDeferred(names: [name])
        reload()
    }
}

// MARK: - Supporting types

private struct CapabilitySection {
    let category: ToolCategory
    let names: [String]
}

private struct DeferredRow {
    let name: String
    let description: String
}

// MARK: - ToolCategory display name

private extension ToolCategory {
    var displayName: String {
        switch self {
        case .appControl:       return "App Control"
        case .music:            return "Music"
        case .systemSettings:   return "System Settings"
        case .power:            return "Power"
        case .files:            return "Files"
        case .web:              return "Web"
        case .windows:          return "Windows"
        case .productivity:     return "Productivity"
        case .terminal:         return "Terminal"
        case .screenshot:       return "Screenshot"
        case .clipboard:        return "Clipboard"
        case .notifications:    return "Notifications"
        case .skills:           return "Skills"
        case .webContent:       return "Web Content"
        case .fileContent:      return "File Content"
        case .fileSearch:       return "File Search"
        case .memory:           return "Memory"
        case .aliases:          return "Aliases"
        case .clipboardHistory: return "Clipboard History"
        case .systemInfo:       return "System Info"
        case .automation:       return "Automation"
        case .cursor:           return "Cursor"
        case .keyboard:         return "Keyboard"
        case .language:         return "Language"
        case .scheduler:        return "Scheduler"
        case .weather:          return "Weather"
        case .messaging:        return "Messaging"
        case .academicResearch: return "Research"
        case .documents:        return "Documents"
        case .browser:          return "Browser"
        case .mcp:              return "MCP"
        case .systemBash:       return "Shell"
        case .media:            return "Media"
        case .screenPerception: return "Perception"
        case .input:            return "Input"
        }
    }
}

// MARK: - FlowLayout

/// Minimal horizontal-wrapping layout for the tool chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = buildRows(subviews: subviews, containerWidth: proposal.width ?? 260)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - (rows.isEmpty ? 0 : spacing)
        return CGSize(width: proposal.width ?? 260, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = buildRows(subviews: subviews, containerWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.view.sizeThatFits(.unspecified)
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(view: LayoutSubview, width: CGFloat)] = []
        var height: CGFloat = 0
    }

    private func buildRows(subviews: Subviews, containerWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        var currentX: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX + size.width > containerWidth, !currentRow.items.isEmpty {
                rows.append(currentRow)
                currentRow = Row()
                currentX = 0
            }
            currentRow.items.append((view: view, width: size.width))
            currentRow.height = max(currentRow.height, size.height)
            currentX += size.width + spacing
        }
        if !currentRow.items.isEmpty { rows.append(currentRow) }
        return rows
    }
}
