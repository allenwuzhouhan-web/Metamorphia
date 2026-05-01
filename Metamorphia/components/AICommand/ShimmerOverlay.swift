import SwiftUI

/// Animated rainbow gradient sweeping across the command-bar pill.
///
/// Ported from Executer's `ShimmerView` with two changes:
///   1. Colors and activity are injected, not baked in — lets the caller
///      vary the palette per `InputBarState`.
///   2. Respects `@Environment(\.accessibilityReduceMotion)` — when
///      reduce-motion is on, we render a flat static gradient (still
///      visible so the shimmer-means-working affordance is preserved)
///      and skip the `repeatForever` animation.
struct ShimmerOverlay: View {
    /// Drives whether the sweep animates. When `false`, the view renders
    /// a transparent fallback. Flips at state-machine transitions;
    /// SwiftUI's structural identity gives us clean start/stop without
    /// manual teardown.
    var isActive: Bool
    var colors: [Color]
    var animationSpeed: Double = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1.0

    var body: some View {
        if isActive {
            GeometryReader { geo in
                LinearGradient(
                    colors: colors,
                    startPoint: UnitPoint(x: reduceMotion ? 0.2 : phase, y: 0.5),
                    endPoint: UnitPoint(x: reduceMotion ? 0.8 : phase + 0.6, y: 0.5)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .onAppear {
                guard !reduceMotion else { return }
                phase = -1.0
                let duration = max(0.5, 2.5 / animationSpeed)
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
            .onDisappear {
                phase = -1.0
            }
        } else {
            Color.clear
        }
    }
}
