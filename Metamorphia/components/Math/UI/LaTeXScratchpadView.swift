/*
 * Metamorphia
 * Native LaTeX math rendering — the live scratchpad UI.
 *
 * A self-contained editor: LaTeX input on top, a debounced live `MathView`
 * preview below, and a toolbar for inserting common snippets and copying
 * the rendered math to the clipboard as an image or a PDF. Styled to sit in
 * the notch (dark, rounded, system materials) but takes no dependency on
 * notch chrome, so it can also live in a floating panel.
 *
 * All state is local (@State / @StateObject). No app singletons, no network,
 * no force-unwraps — export failures degrade silently and the preview always
 * shows something (MathView renders a styled fallback for invalid input).
 */

import SwiftUI
import AppKit

/// A live LaTeX scratchpad with copy-as-image / copy-as-PDF and quick-insert
/// snippets. Hostable in the notch or a floating panel.
@MainActor
public struct LaTeXScratchpadView: View {
    /// The current LaTeX source. Seeded with a friendly example so the
    /// preview isn't empty on first open.
    @State private var latex: String
    /// Debounced copy of `latex` that actually drives the preview, so heavy
    /// typing doesn't re-parse on every keystroke.
    @State private var previewLatex: String
    /// Owns the debounce timer; torn down automatically with the view.
    @StateObject private var debounce = TypingDebounce()

    /// Transient toolbar feedback ("Copied", a flashed checkmark).
    @State private var copyFeedback: CopyFeedback?

    public init(initialLatex: String = "\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}") {
        _latex = State(initialValue: initialLatex)
        _previewLatex = State(initialValue: initialLatex)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            editor
            divider
            preview
            toolbar
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onChange(of: latex) { _, newValue in
            debounce.schedule {
                previewLatex = newValue
            }
        }
        .frame(minWidth: 300)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("LaTeX")
            TextEditor(text: $latex)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white.opacity(0.92))
                .frame(minHeight: 64, maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Preview")
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                MathView(previewLatex, display: true, fontSize: 24, color: .white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(minHeight: 72, maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            // Snippet inserts.
            HStack(spacing: 6) {
                ForEach(Self.snippets) { snippet in
                    snippetButton(snippet)
                }
                Spacer(minLength: 0)
            }

            // Copy actions.
            HStack(spacing: 8) {
                copyButton(
                    title: "Copy as Image",
                    systemImage: "photo",
                    kind: .image,
                    action: copyAsImage
                )
                copyButton(
                    title: "Copy as PDF",
                    systemImage: "doc.richtext",
                    kind: .pdf,
                    action: copyAsPDF
                )
                Spacer(minLength: 0)
            }
        }
    }

    private func snippetButton(_ snippet: Snippet) -> some View {
        Button {
            insert(snippet.latex, caretBack: snippet.caretOffsetFromEnd)
        } label: {
            Text(snippet.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
        .help("Insert \(snippet.latex)")
    }

    private func copyButton(title: String, systemImage: String, kind: CopyFeedback.Kind, action: @escaping () -> Bool) -> some View {
        let isFlashing = copyFeedback?.kind == kind
        return Button {
            let ok = action()
            flash(.init(kind: kind, success: ok))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isFlashing ? (copyFeedback?.success == true ? "checkmark" : "exclamationmark.triangle") : systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(isFlashing ? (copyFeedback?.success == true ? "Copied" : "Failed") : title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isFlashing
                             ? (copyFeedback?.success == true ? Color.green : Color.orange)
                             : Color.white.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
            .animation(.spring(response: 0.25), value: isFlashing)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - Subviews

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.40))
            .tracking(0.5)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - Editing

    /// Append a snippet at the end of the source. We keep this simple — a
    /// plain SwiftUI `TextEditor` exposes no caret API, so snippets append
    /// rather than splice. `caretBack` is reserved for a future AppKit-backed
    /// editor; ignored here so behavior stays predictable.
    private func insert(_ fragment: String, caretBack: Int) {
        _ = caretBack
        // Add a separating space if the previous character isn't whitespace.
        if let last = latex.last, !last.isWhitespace {
            latex.append(" ")
        }
        latex.append(fragment)
    }

    // MARK: - Copy actions
    //
    // Both return success so the toolbar can flash the right feedback. They
    // render the *committed* preview source (`previewLatex`) at export scale.

    private func copyAsImage() -> Bool {
        let source = sourceForExport
        guard !source.isEmpty,
              let image = MathImageExporter.image(latex: source, display: true, scale: 3, color: .white)
        else { return false }

        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([image])
    }

    private func copyAsPDF() -> Bool {
        let source = sourceForExport
        guard !source.isEmpty,
              let data = MathImageExporter.pdf(latex: source, display: true, color: .black)
        else { return false }

        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setData(data, forType: .pdf)
    }

    /// Prefer the live text; fall back to the committed preview if the editor
    /// is momentarily mid-debounce. Trimmed so a stray trailing space doesn't
    /// count as content.
    private var sourceForExport: String {
        let live = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        return live.isEmpty ? previewLatex.trimmingCharacters(in: .whitespacesAndNewlines) : live
    }

    // MARK: - Feedback

    private func flash(_ feedback: CopyFeedback) {
        copyFeedback = feedback
        let token = feedback.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copyFeedback?.id == token {
                copyFeedback = nil
            }
        }
    }

    // MARK: - Snippet table

    private struct Snippet: Identifiable {
        let id = UUID()
        let label: String
        let latex: String
        /// Where a future caret-aware editor would drop the cursor, counted
        /// back from the end of the fragment. Unused by the plain editor.
        let caretOffsetFromEnd: Int
    }

    private static let snippets: [Snippet] = [
        Snippet(label: "a/b",    latex: "\\frac{}{}",      caretOffsetFromEnd: 3),
        Snippet(label: "xⁿ",     latex: "x^{}",            caretOffsetFromEnd: 1),
        Snippet(label: "√",      latex: "\\sqrt{}",        caretOffsetFromEnd: 1),
        Snippet(label: "∑",      latex: "\\sum_{}^{}",     caretOffsetFromEnd: 3),
        Snippet(label: "matrix", latex: "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", caretOffsetFromEnd: 0),
    ]
}

// MARK: - Copy feedback model

/// Transient toolbar feedback for a copy action.
private struct CopyFeedback: Identifiable, Equatable {
    enum Kind: Equatable { case image, pdf }
    let id = UUID()
    let kind: Kind
    let success: Bool
}

// MARK: - Debounce

/// Coalesces rapid typing into a single deferred preview update. Lives as a
/// `@StateObject` so its timer is invalidated when the view goes away.
private final class TypingDebounce: ObservableObject {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval

    init(delay: TimeInterval = 0.18) {
        self.delay = delay
    }

    /// Run `action` after the debounce interval, cancelling any pending one.
    func schedule(_ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    deinit {
        work?.cancel()
    }
}

// MARK: - Preview

#Preview("Scratchpad") {
    LaTeXScratchpadView()
        .frame(width: 380)
        .padding(24)
        .background(Color.black)
}
