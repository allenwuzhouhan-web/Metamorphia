import AppKit
import SwiftUI

/// The notch tray of scratchpad tools. Each tool is an icon + title button.
///
/// A plain TAP activates the tool in place: `onActivate(tool, nil)`.
/// A DRAG (>~8pt) tears the tool out of the notch — on release we report the live
/// screen cursor (`NSEvent.mouseLocation`, AppKit global / bottom-left origin) so the
/// host can spawn a floating panel exactly where it was dropped:
/// `onActivate(tool, NSEvent.mouseLocation)`.
@MainActor public struct ScratchpadTrayView: View {
    private let onActivate: (ScratchTool, CGPoint?) -> Void
    /// Reports when a tear-out drag begins (true) / ends (false) so the host can keep
    /// the notch open during the drag — otherwise auto-close cancels the gesture.
    private let onDragStateChange: ((Bool) -> Void)?

    /// The tool currently being dragged, so we can give it light follow/scale feedback.
    @State private var dragging: ScratchTool?
    @State private var dragTranslation: CGSize = .zero

    public init(
        onActivate: @escaping (ScratchTool, CGPoint?) -> Void,
        onDragStateChange: ((Bool) -> Void)? = nil
    ) {
        self.onActivate = onActivate
        self.onDragStateChange = onDragStateChange
    }

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(ScratchTool.allCases) { tool in
                tile(for: tool)
            }
        }
        .padding(10)
        .background(trayBackground)
    }

    // MARK: Tile

    private func tile(for tool: ScratchTool) -> some View {
        let isDragging = dragging == tool
        return VStack(spacing: 5) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(height: 20)
            Text(tool.title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isDragging ? 0.14 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Light tear-out feedback: the dragged tile follows the cursor slightly and lifts.
        .scaleEffect(isDragging ? 1.06 : 1.0)
        .offset(isDragging ? cappedOffset(dragTranslation) : .zero)
        .shadow(color: .black.opacity(isDragging ? 0.35 : 0), radius: isDragging ? 8 : 0, y: 3)
        .zIndex(isDragging ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragging)
        .gesture(dragGesture(for: tool))
        .accessibilityElement()
        .accessibilityLabel("\(tool.title) scratchpad")
        .accessibilityHint("Tap to open, or drag out to place a floating panel")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Gesture

    private func dragGesture(for tool: ScratchTool) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragging != tool {
                    dragging = tool
                    // Keep the notch open for the duration of the tear-out.
                    onDragStateChange?(true)
                }
                dragTranslation = value.translation
            }
            .onEnded { _ in
                // A real drag past the threshold: drop the tool at the cursor.
                onActivate(tool, NSEvent.mouseLocation)
                dragging = nil
                dragTranslation = .zero
                onDragStateChange?(false)
            }
            // A press that never crosses the threshold falls through to this tap.
            .exclusively(before: TapGesture().onEnded {
                onActivate(tool, nil)
            })
    }

    /// Keep the follow feedback subtle — a hint of movement, not a full drag image.
    private func cappedOffset(_ translation: CGSize) -> CGSize {
        let limit: CGFloat = 14
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, -limit), limit) }
        return CGSize(width: clamp(translation.width), height: clamp(translation.height))
    }

    // MARK: Background

    private var trayBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.45))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}
