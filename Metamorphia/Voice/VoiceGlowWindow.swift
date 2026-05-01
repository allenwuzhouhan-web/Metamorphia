import Cocoa
import QuartzCore

/// Full-screen transparent overlay that draws a pulsing rainbow aura around
/// the screen edges while voice mode is active. Clicks pass through to apps
/// underneath (`ignoresMouseEvents = true`).
///
/// Ported from Executer's `VoiceGlowWindow`. Only difference: resolves the
/// host screen without `NSScreen.builtIn` (Metamorphia doesn't ship that
/// extension) — picks the notched display if one is present, otherwise the
/// main screen.
final class VoiceGlowWindow {
    private var window: NSWindow?
    private var glowLayer: VoiceGlowLayer?

    func show() {
        guard window == nil else { return }
        guard let screen = Self.resolveHostScreen() else { return }

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.isReleasedWhenClosed = false

        let containerView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = CGColor.clear

        let glow = VoiceGlowLayer()
        glow.frame = containerView.bounds
        glow.contentsScale = screen.backingScaleFactor
        containerView.layer?.addSublayer(glow)

        win.contentView = containerView
        window = win
        glowLayer = glow

        win.orderFrontRegardless()

        DispatchQueue.main.async {
            glow.startAnimation()
        }
    }

    func hide() {
        glowLayer?.fadeOut { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.glowLayer = nil
        }
    }

    func updatePulseIntensity(_ state: VoiceState) {
        switch state {
        case .activated: glowLayer?.setPulseDuration(1.5)
        case .listening: glowLayer?.setPulseDuration(3.0)
        case .dispatched: glowLayer?.setPulseDuration(4.0)
        default: break
        }
    }

    /// Prefer the display with a notch (non-zero `safeAreaInsets.top`), fall
    /// back to the main screen. Metamorphia's notch UI already lives on this
    /// same screen so the glow and notch animations stay visually unified.
    private static func resolveHostScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main
    }
}

/// Rainbow aura around the screen margins — four gradient edge layers that
/// rotate through a hand-tuned rainbow palette with a breathing pulse and a
/// dreamy colored shadow. Ported unchanged from Executer.
final class VoiceGlowLayer: CALayer {

    private let edgeDepth: CGFloat = 60
    private var edgeLayers: [CAGradientLayer] = []
    private var colorTimer: Timer?
    private var colorPhase: Int = 0

    private let rainbowColors: [CGColor] = [
        NSColor(hue: 0.00, saturation: 0.65, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.08, saturation: 0.65, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.15, saturation: 0.55, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.33, saturation: 0.55, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.55, saturation: 0.55, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.62, saturation: 0.65, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.75, saturation: 0.55, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.85, saturation: 0.45, brightness: 1.0, alpha: 0.55).cgColor,
    ]

    private let rainbowShadows: [CGColor] = [
        NSColor(hue: 0.00, saturation: 0.8, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.08, saturation: 0.8, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.15, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.33, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.55, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.62, saturation: 0.8, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.75, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.85, saturation: 0.6, brightness: 1.0, alpha: 1.0).cgColor,
    ]

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func startAnimation() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let transparent = CGColor.clear

        let edges: [(CGRect, CGPoint, CGPoint, Int)] = [
            (CGRect(x: 0, y: h - edgeDepth, width: w, height: edgeDepth),
             CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1), 0),
            (CGRect(x: w - edgeDepth, y: 0, width: edgeDepth, height: h),
             CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5), 2),
            (CGRect(x: 0, y: 0, width: w, height: edgeDepth),
             CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0), 4),
            (CGRect(x: 0, y: 0, width: edgeDepth, height: h),
             CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), 6),
        ]

        for (frame, start, end, colorOffset) in edges {
            let gradient = CAGradientLayer()
            gradient.frame = frame
            let idx = colorOffset % rainbowColors.count
            gradient.colors = [rainbowColors[idx], transparent]
            gradient.startPoint = start
            gradient.endPoint = end
            gradient.locations = [0.0, 1.0]
            gradient.shadowColor = rainbowShadows[idx]
            gradient.shadowRadius = 25
            gradient.shadowOpacity = 0.6
            gradient.shadowOffset = .zero

            addSublayer(gradient)
            edgeLayers.append(gradient)
        }

        opacity = 0

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.4
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        add(fadeIn, forKey: "fadeIn")

        for edge in edgeLayers {
            addBreathingPulse(to: edge, duration: 3.0)
        }

        colorTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self = self, !self.edgeLayers.isEmpty else {
                timer.invalidate()
                return
            }
            self.colorPhase = (self.colorPhase + 1) % self.rainbowColors.count

            for (i, edge) in self.edgeLayers.enumerated() {
                let idx = (self.colorPhase + i * 2) % self.rainbowColors.count
                let newColors = [self.rainbowColors[idx], CGColor.clear]

                let colorAnim = CABasicAnimation(keyPath: "colors")
                colorAnim.toValue = newColors
                colorAnim.duration = 0.3
                colorAnim.fillMode = .forwards
                colorAnim.isRemovedOnCompletion = false
                edge.add(colorAnim, forKey: "rainbow")

                let shadowAnim = CABasicAnimation(keyPath: "shadowColor")
                shadowAnim.toValue = self.rainbowShadows[idx]
                shadowAnim.duration = 0.3
                shadowAnim.fillMode = .forwards
                shadowAnim.isRemovedOnCompletion = false
                edge.add(shadowAnim, forKey: "rainbowShadow")
            }
        }
    }

    func fadeOut(completion: @escaping () -> Void) {
        colorTimer?.invalidate()
        colorTimer = nil

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.toValue = 0
        fadeOut.duration = 0.6
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        add(fadeOut, forKey: "fadeOut")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            completion()
        }
    }

    func setPulseDuration(_ duration: CGFloat) {
        for edge in edgeLayers {
            edge.removeAnimation(forKey: "breathing")
            addBreathingPulse(to: edge, duration: duration)
        }
    }

    private func addBreathingPulse(to layer: CAGradientLayer, duration: CGFloat) {
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.3, 0.7, 0.3]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = CFTimeInterval(duration)
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: "breathing")
    }
}
