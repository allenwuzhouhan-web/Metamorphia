import SwiftUI

/// Minimal command-bar state dot.
///
/// A plain white circle that breathes gently while processing. Error state
/// retints to a muted red. No gradients, no halos, no shimmer — the visual
/// weight belongs to the text next to it, not the indicator.
struct SiriOrbView: View {
    var isProcessing: Bool
    var hasError: Bool
    var diameter: CGFloat = 18

    var body: some View {
        // Pace the breathing with the system animation cadence rather than a
        // fixed 60 Hz tick — SwiftUI throttles this automatically when the
        // notch is occluded and drops to ~30 Hz on Pro-Motion-less displays.
        TimelineView(.animation(paused: !isProcessing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = 0.5 + 0.5 * sin(t * 2 * .pi / 1.6)
            let scale = isProcessing ? 0.92 + phase * 0.16 : 1.0
            let opacity = isProcessing ? 0.55 + phase * 0.45 : 0.85

            Circle()
                .fill(tint)
                .frame(width: diameter * 0.38, height: diameter * 0.38)
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .frame(width: diameter, height: diameter)
        // `.smooth` reads as a continuous parameter shift — closer to the
        // single-orb-that-morphs feel the state machine wants. `easeInOut`
        // felt like a crossfade because the curve snaps at the endpoints.
        .animation(.smooth(duration: 0.45), value: hasError)
        .animation(.smooth(duration: 0.45), value: isProcessing)
    }

    private var tint: Color {
        hasError ? Color(red: 0.95, green: 0.40, blue: 0.40) : .white
    }
}

#Preview {
    VStack(spacing: 24) {
        SiriOrbView(isProcessing: false, hasError: false)
        SiriOrbView(isProcessing: true, hasError: false)
        SiriOrbView(isProcessing: false, hasError: true)
    }
    .padding(40)
    .background(Color.black)
}
