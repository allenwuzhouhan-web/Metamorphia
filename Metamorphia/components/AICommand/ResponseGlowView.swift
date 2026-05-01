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
/// honour it, swap the `colorTimer` for `.animation(nil, value:)` and let
/// the stroke stay on a single phase.
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
    private var colorTimer: Timer?
    private var colorPhase: Int = 0

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
        stopAnimation()
        startAnimation()
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
        }

        let pulse = CAKeyframeAnimation(keyPath: "shadowOpacity")
        pulse.values = [0.3, 0.5, 0.3]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = 3.0
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.repeatCount = .infinity
        glowLayers.first?.add(pulse, forKey: "breathing")

        colorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, !self.glowLayers.isEmpty else {
                timer.invalidate()
                return
            }
            self.colorPhase = (self.colorPhase + 1) % self.rainbowColors.count

            for (i, shape) in self.glowLayers.enumerated() {
                let idx = (self.colorPhase + i * 3) % self.rainbowColors.count
                let color = self.rainbowColors[idx]
                let shadow = self.rainbowShadows[idx]

                let strokeAnim = CABasicAnimation(keyPath: "strokeColor")
                strokeAnim.toValue = color.cgColor
                strokeAnim.duration = 0.15
                strokeAnim.fillMode = .forwards
                strokeAnim.isRemovedOnCompletion = false
                shape.add(strokeAnim, forKey: "colorRotate")

                let shadowAnim = CABasicAnimation(keyPath: "shadowColor")
                shadowAnim.toValue = shadow.cgColor
                shadowAnim.duration = 0.15
                shadowAnim.fillMode = .forwards
                shadowAnim.isRemovedOnCompletion = false
                shape.add(shadowAnim, forKey: "shadowRotate")
            }
        }
    }

    func stopAnimation() {
        colorTimer?.invalidate()
        colorTimer = nil
        for layer in glowLayers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        glowLayers.removeAll()
        colorPhase = 0
    }

    deinit {
        stopAnimation()
    }
}
