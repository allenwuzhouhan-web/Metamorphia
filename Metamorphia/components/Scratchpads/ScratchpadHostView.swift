import SwiftUI

/// Wraps a single scratchpad tile in a floating-panel chrome: a compact title bar
/// (tool icon + name + close button) over the matching tile view, all on a rounded,
/// dark, glassy background suited to an always-on-top NSPanel. Sized for ~380x460.
@MainActor public struct ScratchpadHostView: View {
    private let tool: ScratchTool
    private let onClose: () -> Void

    public init(tool: ScratchTool, onClose: @escaping () -> Void) {
        self.tool = tool
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(Color.white.opacity(0.08))
            tile
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .frame(minWidth: 320, minHeight: 360)
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(tool.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 8)
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(Color.white.opacity(0.08))
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("w", modifiers: .command)
        .help("Close")
        .accessibilityLabel("Close \(tool.title) scratchpad")
    }

    // MARK: Tile

    @ViewBuilder
    private var tile: some View {
        switch tool {
        case .regex: RegexScratchpadView()
        case .notes: NotesScratchpadView()
        case .diff: DiffScratchpadView()
        case .qr: QRScratchpadView()
        case .palette: PaletteScratchpadView()
        case .translate: TranslateScratchpadView()
        }
    }

    // MARK: Background

    private var panelBackground: some View {
        ZStack {
            Color.black.opacity(0.55)
            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.white.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .background(.ultraThinMaterial)
    }
}
