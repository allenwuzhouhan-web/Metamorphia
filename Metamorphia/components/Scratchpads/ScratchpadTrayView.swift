import AppKit
import SwiftUI

/// The notch tray of scratchpad tools, laid out as square tiles.
///
/// One press resolves to exactly one action. A single `DragGesture` decides between
/// tap and tear in `onEnded` by how far the press travelled:
/// - travelled ≤ 8pt → a TAP: activate in place, `onActivate(tool, nil)`;
/// - travelled  > 8pt → a TEAR: drop at the live screen cursor
///   (`NSEvent.mouseLocation`, AppKit global / bottom-left origin),
///   `onActivate(tool, NSEvent.mouseLocation)`.
/// There is no separate tap gesture, so a quick flick can never spawn two panels.
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
        return VStack(spacing: 6) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(tool.title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 4)
        }
        // A true square: fill the grid column's width, then match height to it.
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(isDragging ? 0.14 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    /// The tear-out distance, in points, that separates a tap from a drag.
    private let tearThreshold: CGFloat = 8

    private func dragGesture(for tool: ScratchTool) -> some Gesture {
        // A single gesture owns the whole press → release, so it fires `onActivate`
        // exactly once. (The previous drag-`exclusively`-before-tap pair could both
        // resolve on a quick flick and spawn two panels.)
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let torn = hypot(value.translation.width, value.translation.height) > tearThreshold
                if torn, dragging != tool {
                    dragging = tool
                    // Keep the notch open for the duration of the tear-out.
                    onDragStateChange?(true)
                }
                dragTranslation = torn ? value.translation : .zero
            }
            .onEnded { value in
                defer {
                    dragging = nil
                    dragTranslation = .zero
                    onDragStateChange?(false)
                }
                let distance = hypot(value.translation.width, value.translation.height)
                // Past the threshold → tear out at the cursor; otherwise → tap in place.
                onActivate(tool, distance > tearThreshold ? NSEvent.mouseLocation : nil)
            }
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
