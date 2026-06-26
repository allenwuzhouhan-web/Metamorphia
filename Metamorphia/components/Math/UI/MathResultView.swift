/*
 * Metamorphia
 * Native LaTeX math rendering — message renderer for the AI command bar.
 *
 * Takes an assistant message, runs `MathSpanScanner.split`, and lays the
 * result out as flowing text with inline math rendered by `MathView`.
 * Inline math wraps alongside words; display math gets its own centered
 * block. Pure presentation — no state, no app singletons. Never crashes:
 * the scanner emits unterminated delimiters as plain text, and `MathView`
 * already falls back gracefully on anything it can't render.
 */

import SwiftUI

/// Renders an assistant message with embedded LaTeX. Text spans render as
/// normal `Text`; inline math (`$…$`, `\( … \)`) flows inline with the
/// words; display math (`$$…$$`, `\[ … \]`) renders as its own centered row.
///
/// Lightweight by design — the transcript owns scrolling and chrome; this
/// view only lays out one message body.
public struct MathResultView: View {
    private let message: String
    private let fontSize: CGFloat
    private let textColor: Color

    public init(_ message: String, fontSize: CGFloat = 14, textColor: Color = .primary) {
        self.message = message
        self.fontSize = fontSize
        self.textColor = textColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let spans):
                    MathTextFlow(spans: spans, fontSize: fontSize, color: textColor)
                case .display(let latex):
                    MathView(latex, display: true, fontSize: fontSize + 4, color: textColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
    }

    // MARK: - Block model

    /// One rendered chunk. Display math interrupts the text flow with its own
    /// centered row; everything else is grouped into a single flowing run so
    /// inline math wraps next to its surrounding words.
    private enum Block {
        case text([MathSpan])   // text + inline spans, laid out together
        case display(String)    // standalone display-math LaTeX
    }

    /// Group the scanned spans into flowing-text runs separated by display math.
    private var blocks: [Block] {
        var result: [Block] = []
        var run: [MathSpan] = []

        func flush() {
            if !run.isEmpty {
                result.append(.text(run))
                run = []
            }
        }

        for span in MathSpanScanner.split(message) {
            switch span {
            case .text, .inline:
                run.append(span)
            case .display(let latex):
                flush()
                result.append(.display(latex))
            }
        }
        flush()
        return result
    }
}

// MARK: - Inline flow

/// Flows text and inline math left to right, wrapping at the available width.
/// Words break individually so a long line reflows like prose; inline math
/// rides the baseline of the surrounding text as a single unbreakable token.
private struct MathTextFlow: View {
    let spans: [MathSpan]
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        MathInlineLayout(spacing: 0, lineSpacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                token.view(fontSize: fontSize, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One placeable item in the flow: a word (with a trailing space if the
    /// source had one), explicit whitespace, or an inline-math fragment.
    private enum Token {
        case word(String)
        case space
        case math(String)

        @ViewBuilder
        func view(fontSize: CGFloat, color: Color) -> some View {
            switch self {
            case .word(let s):
                Text(s)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundColor(color)
            case .space:
                Text(" ")
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundColor(color)
            case .math(let latex):
                MathView(latex, display: false, fontSize: fontSize, color: color)
            }
        }
    }

    /// Break text spans into word/space tokens (so prose reflows) while
    /// keeping inline math as single atomic tokens.
    private var tokens: [Token] {
        var out: [Token] = []
        for span in spans {
            switch span {
            case .text(let s):
                out.append(contentsOf: Self.wordTokens(s))
            case .inline(let latex):
                out.append(.math(latex))
            case .display(let latex):
                // Shouldn't reach here (display is split out upstream), but
                // degrade to an inline render rather than dropping content.
                out.append(.math(latex))
            }
        }
        return out
    }

    /// Split a text span into words and whitespace, preserving newlines as
    /// soft breaks (rendered as spaces — the flow layout handles wrapping).
    private static func wordTokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var word = ""

        func flushWord() {
            if !word.isEmpty {
                out.append(.word(word))
                word = ""
            }
        }

        for c in s {
            if c == " " || c == "\n" || c == "\t" {
                flushWord()
                out.append(.space)
            } else {
                word.append(c)
            }
        }
        flushWord()
        return out
    }
}

// MARK: - Wrapping layout

/// A baseline-flowing layout: words and inline math are placed left to right
/// and wrapped to the proposed width. Items keep their intrinsic size, so
/// inline math never gets clipped or squeezed.
private struct MathInlineLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + lineSpacing
                maxRowWidth = max(maxRowWidth, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, x - spacing)
        let width = maxWidth.isFinite ? maxWidth : max(maxRowWidth, 0)
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
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

// MARK: - Preview

#Preview("Message with math") {
    MathResultView(
        "The quadratic formula is \\(x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\\), " +
        "which solves $ax^2 + bx + c = 0$. In display form:\n\n" +
        "$$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$\n\n" +
        "That value shows up all over probability and physics.",
        fontSize: 14,
        textColor: .white
    )
    .padding(20)
    .frame(width: 360)
    .background(Color.black)
}
