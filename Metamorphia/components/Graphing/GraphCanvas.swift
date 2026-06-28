import SwiftUI
import AppKit

/// The plotting surface: draws gridlines, axes, tick labels, every enabled curve, and any
/// imported data series, then layers pan/zoom gestures on top. Everything is drawn with a
/// single `Canvas` for performance and is clipped to the rounded card. NaN / empty input
/// degrades to an empty grid rather than crashing.
struct GraphCanvas: View {
    @ObservedObject var model: GraphViewModel

    // Drag state: we apply deltas relative to the last drag translation so a single drag
    // pans continuously without accumulating rounding error.
    @State private var lastDragTranslation: CGSize = .zero
    @GestureState private var magnifyValue: CGFloat = 1

    private let gridColor = Color.white.opacity(0.06)
    private let axisColor = Color.white.opacity(0.22)
    private let labelColor = Color.white.opacity(0.3)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            Canvas { context, canvasSize in
                guard canvasSize.width > 1, canvasSize.height > 1 else { return }
                let vp = model.viewport
                drawGrid(context: &context, size: canvasSize, viewport: vp)
                drawAxes(context: &context, size: canvasSize, viewport: vp)
                drawDataSeries(context: &context, size: canvasSize, viewport: vp)
                drawCurves(context: &context, size: canvasSize, viewport: vp)
            }
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(magnifyGesture(in: size))
            .onAppear { model.canvasSize = size }
            .onChange(of: size) { _, newValue in model.canvasSize = newValue }
            // Scroll-wheel zoom (trackpad / mouse). Sits behind the Canvas; the SwiftUI
            // pan/magnify gestures on the Canvas consume mouse/pinch, and unconsumed
            // scroll-wheel events fall through to this AppKit view.
            .background(ScrollZoomCatcher { deltaY, location in
                let factor = deltaY > 0 ? 0.92 : 1.08
                model.zoom(factor: factor, anchor: location)
            })
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let incremental = CGSize(
                    width: value.translation.width - lastDragTranslation.width,
                    height: value.translation.height - lastDragTranslation.height
                )
                model.pan(byPixels: incremental)
                lastDragTranslation = value.translation
                // Debounced resample so explicit curves refill the newly revealed domain.
                model.scheduleResample()
            }
            .onEnded { _ in
                lastDragTranslation = .zero
                model.scheduleResample()
            }
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($magnifyValue) { current, state, _ in
                let factor = current / max(state, 0.0001)
                state = current
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // Pinch-out (factor > 1) should zoom in -> shrink the window.
                model.zoom(factor: 1 / Double(factor), anchor: center)
            }
    }

    // MARK: - Drawing

    private func screen(_ p: CGPoint, _ size: CGSize, _ vp: Viewport) -> CGPoint {
        GraphViewModel.screenPoint(forMath: p, in: size, viewport: vp)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize, viewport vp: Viewport) {
        let xStep = niceStep(span: vp.width)
        let yStep = niceStep(span: vp.height)

        var path = Path()
        let startX = (vp.minX / xStep).rounded(.up) * xStep
        for i in 0..<tickCount(start: startX, max: vp.maxX, step: xStep) {
            let x = startX + Double(i) * xStep
            let sx = screen(CGPoint(x: x, y: 0), size, vp).x
            path.move(to: CGPoint(x: sx, y: 0))
            path.addLine(to: CGPoint(x: sx, y: size.height))
        }
        let startY = (vp.minY / yStep).rounded(.up) * yStep
        for i in 0..<tickCount(start: startY, max: vp.maxY, step: yStep) {
            let y = startY + Double(i) * yStep
            let sy = screen(CGPoint(x: 0, y: y), size, vp).y
            path.move(to: CGPoint(x: 0, y: sy))
            path.addLine(to: CGPoint(x: size.width, y: sy))
        }
        context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
    }

    private func drawAxes(context: inout GraphicsContext, size: CGSize, viewport vp: Viewport) {
        let origin = screen(.zero, size, vp)
        var path = Path()
        if origin.y >= 0, origin.y <= size.height {
            path.move(to: CGPoint(x: 0, y: origin.y))
            path.addLine(to: CGPoint(x: size.width, y: origin.y))
        }
        if origin.x >= 0, origin.x <= size.width {
            path.move(to: CGPoint(x: origin.x, y: 0))
            path.addLine(to: CGPoint(x: origin.x, y: size.height))
        }
        context.stroke(path, with: .color(axisColor), lineWidth: 1)

        drawTickLabels(context: &context, size: size, viewport: vp, origin: origin)
    }

    private func drawTickLabels(context: inout GraphicsContext, size: CGSize,
                                viewport vp: Viewport, origin: CGPoint) {
        let xStep = niceStep(span: vp.width)
        let yStep = niceStep(span: vp.height)
        let labelY = min(max(origin.y + 11, 10), size.height - 6)
        let labelX = min(max(origin.x + 14, 16), size.width - 16)

        let startX = (vp.minX / xStep).rounded(.up) * xStep
        for i in 0..<tickCount(start: startX, max: vp.maxX, step: xStep) {
            let x = startX + Double(i) * xStep
            if abs(x) > xStep * 0.01 {
                let sx = screen(CGPoint(x: x, y: 0), size, vp).x
                drawLabel(&context, format(x), at: CGPoint(x: sx, y: labelY))
            }
        }
        let startY = (vp.minY / yStep).rounded(.up) * yStep
        for i in 0..<tickCount(start: startY, max: vp.maxY, step: yStep) {
            let y = startY + Double(i) * yStep
            if abs(y) > yStep * 0.01 {
                let sy = screen(CGPoint(x: 0, y: y), size, vp).y
                drawLabel(&context, format(y), at: CGPoint(x: labelX, y: sy))
            }
        }
    }

    /// Number of evenly spaced ticks from `start` to `max` (inclusive) at `step`, clamped
    /// to a hard cap. Computed as an integer count so the draw loops always terminate even
    /// if the viewport offset is so large that `start + step == start` in Double precision.
    private func tickCount(start: Double, max: Double, step: Double) -> Int {
        guard step > 0, start.isFinite, max.isFinite, max >= start else { return 0 }
        let raw = Int((max - start) / step) + 1
        return Swift.min(Swift.max(raw, 0), 2000)
    }

    private func drawLabel(_ context: inout GraphicsContext, _ text: String, at point: CGPoint) {
        let resolved = context.resolve(
            Text(text).font(.system(size: 9)).foregroundStyle(labelColor)
        )
        context.draw(resolved, at: point, anchor: .center)
    }

    private func drawCurves(context: inout GraphicsContext, size: CGSize, viewport vp: Viewport) {
        for curve in model.renderedCurves {
            let color = Color(plotHex: curve.colorHex)
            let path = strokePath(for: curve.points, size: size, viewport: vp)
            guard !path.isEmpty else { continue }
            // Soft glow underlay then the crisp stroke, echoing FunctionGraphView.
            context.stroke(path, with: .color(color.opacity(0.28)),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawDataSeries(context: inout GraphicsContext, size: CGSize, viewport vp: Viewport) {
        for (index, series) in model.dataSeries.enumerated() {
            let color = Color(plotHex: GraphViewModel.palette[index % GraphViewModel.palette.count])
            // Connecting line.
            var line = Path()
            var started = false
            for p in series.points where p.x.isFinite && p.y.isFinite {
                let s = screen(p, size, vp)
                if started { line.addLine(to: s) } else { line.move(to: s); started = true }
            }
            context.stroke(line, with: .color(color.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            // Dots on top.
            for p in series.points where p.x.isFinite && p.y.isFinite {
                let s = screen(p, size, vp)
                guard s.x >= -4, s.x <= size.width + 4, s.y >= -4, s.y <= size.height + 4 else { continue }
                let dot = Path(ellipseIn: CGRect(x: s.x - 2.2, y: s.y - 2.2, width: 4.4, height: 4.4))
                context.fill(dot, with: .color(color))
            }
        }
    }

    /// Builds a stroked path from math points, breaking the line on off-screen jumps so
    /// asymptotes (e.g. tan) don't draw a spurious vertical sweep across the plot.
    private func strokePath(for points: [CGPoint], size: CGSize, viewport vp: Viewport) -> Path {
        var path = Path()
        var drawing = false
        var prev = CGPoint.zero
        let jump = size.height * 1.5

        for p in points {
            guard p.x.isFinite, p.y.isFinite else { drawing = false; continue }
            let s = screen(p, size, vp)
            let onPlane = s.y > -size.height && s.y < size.height * 2
            if !onPlane { drawing = false; prev = s; continue }
            if drawing && abs(s.y - prev.y) > jump {
                drawing = false
            }
            if drawing { path.addLine(to: s) } else { path.move(to: s); drawing = true }
            prev = s
        }
        return path
    }

    // MARK: - Number helpers

    /// A "nice" gridline step (1/2/5 x 10^n) for the visible span.
    private func niceStep(span: Double, target: Int = 8) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let rough = span / Double(target)
        let mag = pow(10, floor(log10(rough)))
        guard mag.isFinite, mag > 0 else { return 1 }
        let r = rough / mag
        if r <= 1.5 { return mag }
        if r <= 3.5 { return 2 * mag }
        if r <= 7.5 { return 5 * mag }
        return 10 * mag
    }

    private func format(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() && abs(rounded) < 1e5 {
            return String(format: "%.0f", rounded)
        }
        if abs(rounded) < 1e-3 || abs(rounded) >= 1e5 {
            return String(format: "%.1e", rounded)
        }
        return String(format: "%g", rounded)
    }
}

// MARK: - Scroll-wheel zoom catcher

/// A thin `NSView` bridge that turns trackpad/mouse scroll events into zoom requests.
/// SwiftUI has no native scroll-wheel hook on macOS, so we drop down to AppKit. It sits
/// behind the Canvas: the SwiftUI pan/magnify gestures handle mouse and pinch, while
/// scroll-wheel events the SwiftUI layer doesn't consume reach this view's `scrollWheel`.
/// Mouse events are explicitly forwarded up the responder chain so it never steals a click.
private struct ScrollZoomCatcher: NSViewRepresentable {
    /// (deltaY, locationInView) — positive deltaY is a scroll-up / zoom-in cue.
    let onScroll: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGPoint) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let dy = event.scrollingDeltaY
            guard dy != 0 else { super.scrollWheel(with: event); return }
            let local = convert(event.locationInWindow, from: nil)
            // Flip to SwiftUI's top-left origin so the anchor lines up with the canvas.
            let flipped = CGPoint(x: local.x, y: bounds.height - local.y)
            onScroll?(dy, flipped)
        }

        // Never participate in mouse handling: pass clicks/drags up so the SwiftUI gesture
        // layer above receives them. Scroll routing still finds this view via the chain.
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
        override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
        override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
    }
}
