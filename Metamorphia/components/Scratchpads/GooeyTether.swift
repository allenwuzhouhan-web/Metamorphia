import SwiftUI

/// The notch's "ink" while a tool is being drawn out: a blob anchored at the notch
/// lip, a short chain of tapering blobs forming a neck, and a droplet at the tip —
/// all drawn into one layer that is blurred and then alpha-thresholded so they fuse
/// into a single gooey body (the classic metaball trick).
///
/// As `strength` falls toward 0 the middle of the neck thins and finally pinches off:
/// that pinch *is* "the connection getting weaker the farther you pull." Nothing about
/// the break is faked — it falls out of the blur + threshold once the middle blobs are
/// too small to bridge the gap.
struct GooeyTetherView: View {
    /// The fixed end, at the notch lip (view space).
    var anchor: CGPoint
    /// The dragged end, following the cursor (view space).
    var tip: CGPoint
    /// 1 = firmly connected · 0 = about to snap. Drives how far the neck thins.
    var strength: CGFloat

    var anchorRadius: CGFloat = 13
    var tipRadius: CGFloat = 22
    var inkColor: Color = .black

    var body: some View {
        Canvas { context, _ in
            // Filters wrap subsequent drawing innermost-last, so the blur (added
            // last) hits the raw circles first and the threshold (added first)
            // re-sharpens the merged result — that ordering is what fuses them.
            context.addFilter(.alphaThreshold(min: 0.42, color: inkColor))
            context.addFilter(.blur(radius: 9))
            context.drawLayer { layer in
                let steps = 7
                for i in 0...steps {
                    let f = CGFloat(i) / CGFloat(steps)
                    let point = CGPoint(
                        x: anchor.x + (tip.x - anchor.x) * f,
                        y: anchor.y + (tip.y - anchor.y) * f
                    )
                    // Radius tapers anchor → tip. The middle (sin peaks at f = 0.5)
                    // thins most as strength drops, so a weak tether necks down and
                    // breaks in the centre rather than at either end.
                    let base = anchorRadius + (tipRadius - anchorRadius) * f
                    let pinch = 1 - (1 - strength) * sin(f * .pi) * 0.85
                    let r = max(0.5, base * pinch)
                    layer.fill(
                        Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                        with: .color(inkColor)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("Gooey tether — pulling away") {
    // Animates the tip away from the anchor so the neck visibly thins and snaps.
    struct Demo: View {
        @State private var t: CGFloat = 0
        let anchor = CGPoint(x: 200, y: 60)
        var body: some View {
            let tip = CGPoint(x: 200 + 30 * t, y: 60 + 240 * t)
            let strength = max(0, 1 - t)
            return ZStack {
                Color.white
                GooeyTetherView(anchor: anchor, tip: tip, strength: strength)
            }
            .frame(width: 400, height: 360)
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { t = 1 }
            }
        }
    }
    return Demo()
}
