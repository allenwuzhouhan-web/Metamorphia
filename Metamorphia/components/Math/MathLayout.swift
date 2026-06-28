/*
 * Metamorphia
 * Native LaTeX math rendering — layout + the public `MathView`.
 *
 * Walks the `MathAtom` tree and composes SwiftUI views with hand-computed
 * geometry: scaled fonts and baseline offsets for scripts, drawn fraction bars
 * and radicals, stretched fences and matrices. No web view, no font bundles —
 * system fonts plus Unicode glyphs only. Never crashes; unsupported constructs
 * render as a subtle inline fallback.
 */

import SwiftUI

// MARK: - Public view

/// A SwiftUI view that renders LaTeX math natively. Never crashes; unsupported
/// constructs fall back to the raw LaTeX shown in a subtle styled inline form.
public struct MathView: View {
    private let latex: String
    private let display: Bool
    private let fontSize: CGFloat
    private let color: Color

    public init(_ latex: String, display: Bool = false, fontSize: CGFloat = 16, color: Color = .primary) {
        self.latex = latex
        self.display = display
        self.fontSize = fontSize
        self.color = color
    }

    public var body: some View {
        let atom = LatexParser.parse(latex)
        let context = MathRenderContext(baseSize: fontSize, color: color, display: display)
        MathNode(atom: atom, context: context)
            .fixedSize()
            .accessibilityLabel(Text(latex))
    }
}

// MARK: - Render context

/// Styling/scale state threaded through the recursive render. Value type.
struct MathRenderContext {
    /// The font size for the current nesting level.
    var baseSize: CGFloat
    var color: Color
    /// Whether we are in display style (affects big-operator limit placement).
    var display: Bool
    /// Current script-shrink depth (0 = full size).
    var scriptDepth: Int = 0

    /// Effective point size after script shrinking.
    var size: CGFloat {
        // Each script level shrinks to ~70%, floored so it stays legible.
        let factor = pow(0.72, CGFloat(scriptDepth))
        return max(baseSize * factor, 7)
    }

    /// A context one script level deeper.
    func scripted() -> MathRenderContext {
        var c = self
        c.scriptDepth = min(scriptDepth + 1, 3)
        c.display = false
        return c
    }
}

// MARK: - Recursive node renderer

/// Renders one atom. Splitting into a view keeps SwiftUI's diffing happy and
/// lets each node measure itself via `fixedSize`.
struct MathNode: View {
    let atom: MathAtom
    let context: MathRenderContext

    var body: some View {
        switch atom {
        case .run(let s, let style):
            runView(s, style)

        case .list(let items):
            MathRow(items: items, context: context)

        case .scripted(let base, let sup, let sub):
            scriptedView(base: base, sup: sup, sub: sub)

        case .fraction(let num, let den):
            FractionView(numerator: num, denominator: den, context: context)

        case .radical(let index, let radicand):
            RadicalView(index: index, radicand: radicand, context: context)

        case .bigOperator(let symbol, _):
            // A bare big operator with no limits.
            Text(symbol)
                .font(.system(size: context.baseSize * 1.5))
                .foregroundColor(context.color)

        case .delimited(let left, let content, let right):
            DelimitedView(left: left, content: content, right: right, context: context)

        case .matrix(let rows, let delimiter):
            MatrixView(rows: rows, delimiter: delimiter, context: context)

        case .space(let amount):
            Color.clear.frame(width: max(0, amount) * context.size, height: 1)

        case .fallback(let raw):
            Text(raw)
                .font(.system(size: context.size * 0.92))
                .foregroundColor(context.color.opacity(0.55))
                .padding(.horizontal, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(context.color.opacity(0.08))
                )
        }
    }

    @ViewBuilder
    private func runView(_ s: String, _ style: MathFontStyle) -> some View {
        Text(styledString(s, style))
            .foregroundColor(context.color)
    }

    /// Build an AttributedString applying the math face for a run.
    private func styledString(_ s: String, _ style: MathFontStyle) -> AttributedString {
        var out = AttributedString(mapped(s, style))
        out.font = font(for: style, content: s)
        return out
    }

    /// Apply a glyph mapping for double-struck (\mathbb); otherwise pass through.
    private func mapped(_ s: String, _ style: MathFontStyle) -> String {
        guard style == .blackboard else { return s }
        return s.reduce(into: "") { acc, c in acc += MathBlackboard.map(c) }
    }

    private func font(for style: MathFontStyle, content: String) -> Font {
        let size = context.size
        switch style {
        case .bold:
            return .system(size: size, weight: .bold).italic()
        case .roman, .text, .blackboard:
            return .system(size: size)
        case .normal:
            // Single Latin letters render italic (variables); everything else upright.
            if isSingleVariable(content) {
                return .system(size: size).italic()
            }
            return .system(size: size)
        }
    }

    private func isSingleVariable(_ str: String) -> Bool {
        guard str.count == 1, let c = str.first else { return false }
        return c.isLetter && c.isASCII
    }

    // MARK: scripted

    @ViewBuilder
    private func scriptedView(base: MathAtom, sup: MathAtom?, sub: MathAtom?) -> some View {
        if case .bigOperator(let symbol, let displayLimits) = base, context.display && displayLimits {
            // Display-style limits: stack sup above and sub below the operator.
            BigOperatorLimitsView(symbol: symbol, sup: sup, sub: sub, context: context)
        } else {
            ScriptView(base: base, sup: sup, sub: sub, context: context)
        }
    }
}

// MARK: - Horizontal row

/// Lays a list of atoms left to right, baseline-aligned, with light spacing
/// around binary operators and relations.
struct MathRow: View {
    let items: [MathAtom]
    let context: MathRenderContext

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                MathNode(atom: item, context: context)
                    .padding(.horizontal, spacing(for: item))
            }
        }
    }

    /// Minimal optical spacing: a little air around relations/operators.
    private func spacing(for item: MathAtom) -> CGFloat {
        guard case .run(let s, .normal) = item else { return 0 }
        let relations: Set<String> = ["=", "\u{2260}", "\u{2264}", "\u{2265}", "<", ">",
                                      "\u{2248}", "\u{2261}", "\u{2192}", "\u{2190}",
                                      "\u{21D2}", "\u{2208}", "+", "\u{2212}", "-"]
        return relations.contains(s) ? context.size * 0.12 : 0
    }
}

// MARK: - Scripts (corner sup/sub)

/// Renders base with superscript and/or subscript at the top/bottom corners.
struct ScriptView: View {
    let base: MathAtom
    let sup: MathAtom?
    let sub: MathAtom?
    let context: MathRenderContext

    var body: some View {
        let scriptCtx = context.scripted()
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            MathNode(atom: base, context: context)
            VStack(alignment: .leading, spacing: 0) {
                if let sup {
                    MathNode(atom: sup, context: scriptCtx)
                        .alignmentGuide(.lastTextBaseline) { d in d[.lastTextBaseline] }
                        .offset(y: -context.size * 0.42)
                } else {
                    Color.clear.frame(width: 0, height: context.size * 0.5)
                }
                if let sub {
                    MathNode(atom: sub, context: scriptCtx)
                        .offset(y: context.size * 0.16)
                } else {
                    Color.clear.frame(width: 0, height: context.size * 0.25)
                }
            }
            // Pull the script column up so the gap above sup is not doubled.
            .padding(.leading, context.size * 0.04)
        }
    }
}

/// Big operator (sum/prod) with limits stacked above and below in display style.
struct BigOperatorLimitsView: View {
    let symbol: String
    let sup: MathAtom?
    let sub: MathAtom?
    let context: MathRenderContext

    var body: some View {
        let scriptCtx = context.scripted()
        VStack(spacing: context.size * 0.02) {
            if let sup {
                MathNode(atom: sup, context: scriptCtx)
            }
            Text(symbol)
                .font(.system(size: context.baseSize * 1.7))
                .foregroundColor(context.color)
            if let sub {
                MathNode(atom: sub, context: scriptCtx)
            }
        }
        .fixedSize()
    }
}

// MARK: - Fraction

/// Numerator over a drawn rule over denominator.
struct FractionView: View {
    let numerator: MathAtom
    let denominator: MathAtom
    let context: MathRenderContext

    var body: some View {
        let inner = context.scripted()
        VStack(spacing: context.size * 0.12) {
            MathNode(atom: numerator, context: inner)
            Rectangle()
                .fill(context.color)
                .frame(height: max(0.8, context.size * 0.045))
            MathNode(atom: denominator, context: inner)
        }
        .padding(.horizontal, context.size * 0.12)
        .fixedSize()
        // Center the bar on the math axis so the fraction sits correctly inline.
        .alignmentGuide(.lastTextBaseline) { d in d[VerticalAlignment.center] + context.size * 0.28 }
    }
}

// MARK: - Radical

/// √ with an overbar covering the radicand, plus an optional small index.
struct RadicalView: View {
    let index: MathAtom?
    let radicand: MathAtom
    let context: MathRenderContext

    var body: some View {
        let inner = context
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let index {
                    MathNode(atom: index, context: context.scripted().scripted())
                        .offset(x: 0, y: 0)
                }
                RadicalGlyph(color: context.color, lineWidth: max(0.8, context.size * 0.05))
                    .frame(width: context.size * 0.7)
                    .padding(.leading, index == nil ? 0 : context.size * 0.18)
            }
            MathNode(atom: radicand, context: inner)
                .padding(.top, max(1.5, context.size * 0.14))
                .padding(.trailing, context.size * 0.12)
                .padding(.leading, context.size * 0.02)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(context.color)
                        .frame(height: max(0.8, context.size * 0.05))
                }
        }
        .fixedSize()
    }
}

/// The check-mark portion of a radical sign, drawn so it scales with content.
struct RadicalGlyph: View {
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width
                let h = geo.size.height
                p.move(to: CGPoint(x: 0, y: h * 0.55))
                p.addLine(to: CGPoint(x: w * 0.28, y: h * 0.45))
                p.addLine(to: CGPoint(x: w * 0.55, y: h))
                p.addLine(to: CGPoint(x: w, y: 0))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Delimited fence

/// \left( content \right) — fences stretch to the content's height.
struct DelimitedView: View {
    let left: MathDelimiter
    let content: MathAtom
    let right: MathDelimiter
    let context: MathRenderContext

    var body: some View {
        HStack(alignment: .center, spacing: context.size * 0.04) {
            StretchyDelimiter(delimiter: left, isLeft: true, context: context)
            MathNode(atom: content, context: context)
            StretchyDelimiter(delimiter: right, isLeft: false, context: context)
        }
        .fixedSize()
    }
}

/// A bracket glyph stretched vertically to match neighboring content height.
struct StretchyDelimiter: View {
    let delimiter: MathDelimiter
    let isLeft: Bool
    let context: MathRenderContext

    var body: some View {
        let glyph = isLeft ? delimiter.glyphs.left : delimiter.glyphs.right
        if delimiter == .none || glyph.isEmpty {
            Color.clear.frame(width: 0, height: 0)
        } else {
            Text(glyph)
                .font(.system(size: context.size))
                .foregroundColor(context.color)
                .scaleEffect(x: 1, y: 1.0, anchor: .center)
                .modifier(StretchToHeight())
        }
    }
}

/// Lets a delimiter glyph grow vertically to the surrounding row height.
struct StretchToHeight: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Matrix

/// A grid of cells, optionally wrapped in fences (pmatrix/bmatrix/vmatrix).
struct MatrixView: View {
    let rows: [[MathAtom]]
    let delimiter: MathDelimiter
    let context: MathRenderContext

    var body: some View {
        let grid = Grid(alignment: .center,
                        horizontalSpacing: context.size * 0.5,
                        verticalSpacing: context.size * 0.28) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        MathNode(atom: cell, context: context)
                    }
                }
            }
        }
        .padding(.horizontal, context.size * 0.2)

        if delimiter == .none {
            grid
        } else {
            HStack(spacing: 0) {
                Text(delimiter.glyphs.left)
                    .font(.system(size: context.size))
                    .foregroundColor(context.color)
                    .frame(maxHeight: .infinity)
                grid
                Text(delimiter.glyphs.right)
                    .font(.system(size: context.size))
                    .foregroundColor(context.color)
                    .frame(maxHeight: .infinity)
            }
            .fixedSize()
        }
    }
}

// MARK: - Previews

#Preview("Inline samples") {
    VStack(alignment: .leading, spacing: 16) {
        MathView("x^2 + y^2 = z^2", fontSize: 20)
        MathView("\\frac{a+b}{c-d}", fontSize: 20)
        MathView("\\sqrt{x^2 + 1}", fontSize: 20)
        MathView("\\sqrt[3]{27} = 3", fontSize: 20)
        MathView("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}", display: true, fontSize: 22)
        MathView("\\alpha + \\beta \\leq \\gamma", fontSize: 20)
        MathView("\\left( \\frac{1}{2} \\right)", fontSize: 20)
        MathView("\\mathbb{R} \\subset \\mathbb{C}", fontSize: 20)
        MathView("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", fontSize: 20)
        MathView("e^{i\\pi} + 1 = 0 \\quad \\unknownmacro", fontSize: 20)
    }
    .padding(30)
}
