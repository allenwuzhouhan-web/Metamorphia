import SwiftUI

/// Floating dropdown that appears under the command-bar input pill while the
/// user is typing a `/slash` token. Renders the current matches from
/// `AICommandViewModel.slashSuggestions` and reflects the highlighted index
/// driven by the view model's keyboard handlers.
///
/// Visual language: matches the existing notch panels — translucent dark
/// background, rounded rectangle, San Francisco display (no monospace).
/// Each row is a single line: emoji/symbol, skill id, description trimmed
/// to one line. The currently selected row gets a subtle accent fill.
///
/// Containment: the list caps at `maxVisibleRows` rows and scrolls internally
/// for the rest. Without the cap, a bare `/` (which returns every skill)
/// would drive the notch straight to its 420pt ceiling in one jump and clip
/// the overflow with no scroll — borrowing the minimalistic music player's
/// fixed-height + `.smooth(duration: 0.3)` pattern keeps the reveal compact
/// and animates height changes in lockstep with the notch spring.
struct SkillSuggestionListView: View {
    let suggestions: [SkillSuggestion]
    let selectedIndex: Int
    let onSelect: (SkillSuggestion) -> Void

    /// Ceiling on rows shown at once — beyond this, the list scrolls. Chosen
    /// so the dropdown sits comfortably inside the notch alongside the input
    /// row without pushing the response area off-screen.
    private let maxVisibleRows = 5
    /// Height budget per row: 13pt id + 1pt gap + 11pt description + 12pt
    /// vertical padding ≈ 38pt in practice. Keep in sync with `row(for:)`.
    private let rowHeight: CGFloat = 38
    /// Extra chrome padding inside the rounded rectangle (4pt top + 4pt bottom
    /// from `.padding(.vertical, 4)`).
    private let chromePadding: CGFloat = 8

    private var visibleRowCount: Int {
        min(max(suggestions.count, 1), maxVisibleRows)
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(visibleRowCount)
        // 1pt divider between each pair of visible rows.
        let dividerSpan = CGFloat(max(0, visibleRowCount - 1))
        return rows * rowHeight + dividerSpan + chromePadding
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, suggestion in
                        row(for: suggestion, isSelected: idx == selectedIndex)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(suggestion) }
                            .id(idx)
                        if idx < suggestions.count - 1 {
                            Divider()
                                .background(Color.white.opacity(0.05))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: listHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)
            .animation(.smooth(duration: 0.3), value: listHeight)
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for suggestion: SkillSuggestion, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            iconView(for: suggestion)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("/\(suggestion.id)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    if suggestion.isStub {
                        Text("stub")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.orange.opacity(0.35))
                            )
                    }
                }
                Text(suggestion.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.22)
                : Color.clear
        )
    }

    @ViewBuilder
    private func iconView(for suggestion: SkillSuggestion) -> some View {
        if let raw = suggestion.emoji, !raw.isEmpty {
            // Heuristic: if the value looks like an SF Symbol identifier
            // (lowercase, dot-separated, no emoji glyphs), render it as a
            // symbol. Otherwise render as a glyph.
            if isLikelySFSymbol(raw) {
                Image(systemName: raw)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text(raw)
                    .font(.system(size: 14))
            }
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func isLikelySFSymbol(_ value: String) -> Bool {
        // SF Symbols use [a-z0-9.] only. Emoji include extended grapheme
        // clusters with non-ASCII code points.
        for scalar in value.unicodeScalars {
            if scalar.value > 127 { return false }
        }
        return value.contains(where: { $0.isLetter })
    }
}
