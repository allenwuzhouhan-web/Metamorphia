import SwiftUI
import QuartzCore
import AppKit

/// Animated rainbow glow border that traces the contour of the response
/// bubble. Uses three stacked `CAShapeLayer` borders with rotating colors
/// and a breathing shadow pulse.
///
/// Ported from Executer (`Executer/UI/Animations/ResponseGlowView.swift`).
/// Placed as a sibling of `ShimmerOverlay` because the two systems target
/// different surfaces: the shimmer lives inside the pill (clip-masked),
/// the glow lives outside the bubble's clip shape so the halo can bleed
/// outward.
///
/// Reduce-motion is NOT applied here (matches Executer) — the glow is a
/// soft idle decoration, not a signal of activity. If we ever want to
/// honour it, drop the `colorRotate` keyframe animations and let the
/// stroke stay on a single phase.
struct ResponseGlowView: NSViewRepresentable {
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> ResponseGlowNSView {
        let view = ResponseGlowNSView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: ResponseGlowNSView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}

final class ResponseGlowNSView: NSView {
    var cornerRadius: CGFloat = 12

    private var glowLayers: [CAShapeLayer] = []
    private var lastPathBounds: CGRect = .zero

    // Soft rainbow — lower alpha for subtlety.
    private let rainbowColors: [NSColor] = [
        NSColor(hue: 0.00, saturation: 0.55, brightness: 1.0, alpha: 0.35), // Red
        NSColor(hue: 0.08, saturation: 0.55, brightness: 1.0, alpha: 0.35), // Orange
        NSColor(hue: 0.15, saturation: 0.45, brightness: 1.0, alpha: 0.35), // Yellow
        NSColor(hue: 0.33, saturation: 0.45, brightness: 1.0, alpha: 0.35), // Green
        NSColor(hue: 0.55, saturation: 0.45, brightness: 1.0, alpha: 0.35), // Cyan
        NSColor(hue: 0.62, saturation: 0.55, brightness: 1.0, alpha: 0.35), // Blue
        NSColor(hue: 0.75, saturation: 0.45, brightness: 1.0, alpha: 0.35), // Purple
        NSColor(hue: 0.85, saturation: 0.35, brightness: 1.0, alpha: 0.35), // Pink
    ]

    // Shadow colors — more saturated for the glow halo.
    private let rainbowShadows: [NSColor] = [
        NSColor(hue: 0.00, saturation: 0.7, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.08, saturation: 0.7, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.15, saturation: 0.6, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.33, saturation: 0.6, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.55, saturation: 0.6, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.62, saturation: 0.7, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.75, saturation: 0.6, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.85, saturation: 0.5, brightness: 1.0, alpha: 0.6),
    ]

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        // Only (re)build the layers + animations when the bounds actually
        // change. layout() fires on every relayout; tearing down and respawning
        // the whole glow stack each time is wasted churn.
        if glowLayers.isEmpty {
            startAnimation()
        } else if bounds != lastPathBounds {
            stopAnimation()
            startAnimation()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    func startAnimation() {
        guard glowLayers.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        lastPathBounds = bounds
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil
        )

        for i in 0..<3 {
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillColor = nil
            let colorIndex = (i * 3) % rainbowColors.count
            let color = rainbowColors[colorIndex]
            shape.strokeColor = color.cgColor
            shape.lineWidth = CGFloat(3 - i)
            shape.shadowColor = rainbowShadows[colorIndex].cgColor
            shape.shadowRadius = CGFloat(8 - i * 2)
            shape.shadowOpacity = Float(0.4 - Double(i) * 0.1)
            shape.shadowOffset = .zero
            shape.opacity = 0

            layer?.addSublayer(shape)
            glowLayers.append(shape)

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.5
            fadeIn.beginTime = CACurrentMediaTime() + Double(i) * 0.06
            fadeIn.fillMode = .forwards
            fadeIn.isRemovedOnCompletion = false
            shape.add(fadeIn, forKey: "fadeIn")

            // Continuous rainbow cross-fade driven by a single long-running
            // keyframe animation per layer (phase-offset by colorIndex), instead
            // of a 20Hz Timer re-adding CABasicAnimations every tick. Core
            // Animation interpolates the colors on the render thread, so this is
            // allocation-free after setup and pauses automatically when the
            // layer is offscreen.
            let cycle: Double = 0.4 * Double(rainbowColors.count)
            let phase = colorIndex

            let strokeRotate = CAKeyframeAnimation(keyPath: "strokeColor")
            strokeRotate.values = (0...rainbowColors.count).map { step in
                rainbowColors[(phase + step) % rainbowColors.count].cgColor
            }
            strokeRotate.duration = cycle
            strokeRotate.calculationMode = .linear
            strokeRotate.repeatCount = .infinity
            shape.add(strokeRotate, forKey: "colorRotate")

            let shadowRotate = CAKeyframeAnimation(keyPath: "shadowColor")
            shadowRotate.values = (0...rainbowShadows.count).map { step in
                rainbowShadows[(phase + step) % rainbowShadows.count].cgColor
            }
            shadowRotate.duration = cycle
            shadowRotate.calculationMode = .linear
            shadowRotate.repeatCount = .infinity
            shape.add(shadowRotate, forKey: "shadowRotate")
        }

        let pulse = CAKeyframeAnimation(keyPath: "shadowOpacity")
        pulse.values = [0.3, 0.5, 0.3]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = 3.0
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.repeatCount = .infinity
        glowLayers.first?.add(pulse, forKey: "breathing")
    }

    func stopAnimation() {
        for layer in glowLayers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        glowLayers.removeAll()
        lastPathBounds = .zero
    }

    deinit {
        stopAnimation()
    }
}
