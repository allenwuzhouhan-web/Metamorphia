import SwiftUI
import AppKit

/// A plain sticky-note scratchpad for the floating notch panel — somewhere to jot a
/// thought, a snippet, a to-do. The text persists across launches, so a torn-out
/// panel behaves like a sticky note left stuck to your screen.
///
/// Deliberately not a code field: regular (non-monospaced) text on a faint warm
/// wash, so it reads as paper rather than a terminal.
@MainActor public struct NotesScratchpadView: View {
    @AppStorage("metamorphiaScratchNote") private var text: String = ""
    /// Guards against re-entering `autoComplete` from the edit it makes itself.
    @State private var isAutoCompleting = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            editor
            footer
        }
        .padding(14)
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Jot a note… or type 100/5=")
                    .font(.custom("Bradley Hand", size: 17))
                    .foregroundStyle(.black.opacity(0.35))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
            }
            SmartListTextView(
                text: $text,
                font: NSFont(name: "Bradley Hand", size: 17) ?? .systemFont(ofSize: 16),
                textColor: .black
            )
            .onChange(of: text) { _, newValue in autoComplete(newValue) }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(stickyNoteYellow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    /// Classic bright sticky-note yellow — fully opaque, so the pad reads like a
    /// real Post-it rather than a tinted panel.
    private var stickyNoteYellow: Color {
        Color(red: 1.0, green: 0.906, blue: 0.34)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(countLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 0)
            footerButton(symbol: "doc.on.doc", title: "Copy", action: copy)
            footerButton(symbol: "trash", title: "Clear", action: clear)
        }
    }

    private func footerButton(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .opacity(text.isEmpty ? 0.45 : 1)
    }

    private var countLabel: String {
        let words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        return words == 1 ? "1 word" : "\(words) words"
    }

    // MARK: Actions

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clear() {
        text = ""
    }

    // MARK: Auto-math

    /// When the user finishes a line with "=", evaluate the expression before it and
    /// append the answer in place — "100/5=" becomes "100/5=20", "1km=" becomes
    /// "1km=1000 m". Lines that aren't math (most notes) are left exactly as typed.
    private func autoComplete(_ value: String) {
        guard !isAutoCompleting, value.hasSuffix("=") else { return }

        let lineStart = value.lastIndex(of: "\n").map { value.index(after: $0) } ?? value.startIndex
        let expression = String(value[lineStart...].dropLast()) // current line, minus the "="
        guard let answer = AutoMath.result(for: expression) else { return }

        isAutoCompleting = true
        text = value + answer
        DispatchQueue.main.async { isAutoCompleting = false }
    }
}
