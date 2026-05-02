import SwiftUI

// MARK: - Streaming response renderer
//
// Renders the reply as individual word views so each new token can fade
// in as it arrives. The token-by-token feel is the right signal during
// streaming.
//
// Extracted from NotchCommandBarView.swift (T3). Promoted from `private`
// to `internal` so TranscriptView can reference these types directly.

struct StreamingResponseText: View {
    let text: String

    private struct ParagraphLine: Identifiable {
        let id: Int
        let words: [WordToken]
    }

    private struct WordToken: Identifiable, Equatable {
        let id: String
        let text: String
    }

    private var lines: [ParagraphLine] {
        text.components(separatedBy: "\n").enumerated().map { (paraIdx, line) in
            let words = line
                .split(separator: " ", omittingEmptySubsequences: true)
                .enumerated()
                .map { (wordIdx, word) in
                    WordToken(id: "\(paraIdx)-\(wordIdx)", text: String(word))
                }
            return ParagraphLine(id: paraIdx, words: words)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                paragraph(words: line.words)
            }
        }
    }

    private func paragraph(words: [WordToken]) -> some View {
        CommandBarFlowLayout(spacing: 5, lineSpacing: 3) {
            ForEach(words) { word in
                Text(word.text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: words.map(\.id))
    }
}

/// Word-wrapping layout: each word is its own animatable view while still
/// flowing as a paragraph.
struct CommandBarFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + lineSpacing
                maxRowWidth = max(maxRowWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth - spacing)
        return CGSize(width: max(maxRowWidth, 0), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Single tool-call indicator. Tool calls intentionally render as fixed-size
/// icons only; labels can wrap badly when a run emits many calls at once.
struct ToolPillView: View {
    let pill: AICommandViewModel.ToolCallPill

    var body: some View {
        Image(systemName: toolSymbol(for: pill.toolName))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .frame(width: 22, height: 18)
            .background(backgroundColor, in: Capsule())
            .accessibilityLabel(accessibilityLabel)
            .help(accessibilityLabel)
    }

    private func toolSymbol(for toolName: String) -> String {
        switch toolName {
        case let n where n.contains("file"): return "folder"
        case let n where n.contains("memory"): return "memorychip"
        case let n where n.contains("clipboard"): return "doc.on.clipboard"
        case let n where n.contains("timer"): return "timer"
        case let n where n.contains("note"): return "note.text"
        case let n where n.contains("shelf"): return "books.vertical"
        case let n where n.contains("color"): return "eyedropper"
        case let n where n.contains("calendar"): return "calendar"
        case let n where n.contains("stats"): return "chart.bar"
        case let n where n.contains("script"), let n where n.contains("shell"): return "terminal"
        case let n where n.contains("web") || n.contains("url") || n.contains("search"): return "globe"
        case let n where n.contains("apple"): return "applescript"
        default: return "wrench.and.screwdriver"
        }
    }

    private var foregroundColor: Color {
        guard pill.isComplete else { return .white.opacity(0.72) }
        return pill.isSuccess ? .green.opacity(0.72) : .orange.opacity(0.78)
    }

    private var backgroundColor: Color {
        guard pill.isComplete else { return Color.white.opacity(0.07) }
        return pill.isSuccess ? Color.green.opacity(0.10) : Color.orange.opacity(0.12)
    }

    private var accessibilityLabel: String {
        if pill.isComplete {
            return pill.isSuccess ? "\(pill.toolName) completed" : "\(pill.toolName) failed"
        }
        return "\(pill.toolName) running"
    }
}
