import SwiftUI
import AppKit
import CoreGraphics
import Combine

/// Holds all mutable state for the graphing calculator: the curves, any imported data
/// series, the viewport (the math rectangle currently on screen), and the live values of
/// auto-generated parameter sliders. Sampling is recomputed only when an input that
/// affects it changes, and slider drags are debounced so a fast scrub stays smooth.
///
/// Pure value math (viewport conversions, parameter discovery, sampling) lives in
/// nonisolated statics so it stays cheap and unit-testable; the observable surface is
/// `@MainActor` because it drives SwiftUI.
@MainActor
final class GraphViewModel: ObservableObject {

    // MARK: - Published state

    /// The curves the user is editing/plotting. Editing a row mutates this in place.
    @Published var curves: [PlotCurve]

    /// Scatter/line series imported from clipboard CSV.
    @Published private(set) var dataSeries: [DataSeries] = []

    /// The math rectangle currently mapped to the canvas. Pan/zoom mutate this.
    @Published var viewport: Viewport = .standard

    /// Live values for every free parameter (anything that isn't x/t/theta) found in the
    /// enabled curves — e.g. `a` in `a*sin(x)`. Driven by auto-generated sliders.
    @Published var parameters: [String: Double] = [:]

    /// The canvas size in points, published so gesture math (which needs a pixel->math
    /// scale) can read it. Updated by the canvas via `GeometryReader`.
    @Published var canvasSize: CGSize = .zero

    // MARK: - Sampling output

    /// One renderable result per enabled curve, in math coordinates. Recomputed lazily.
    @Published private(set) var renderedCurves: [RenderedCurve] = []

    // MARK: - Config

    /// Default range for an auto-generated parameter slider.
    let parameterRange: ClosedRange<Double> = -10...10

    /// Samples per curve. Kept modest so a drag-driven recompute stays responsive.
    private let sampleSteps = 600

    private var debounceWork: DispatchWorkItem?

    // MARK: - Init

    init(curves: [PlotCurve]) {
        self.curves = curves.isEmpty ? [PlotCurve()] : curves
        syncParameters()
        recompute()
    }

    // MARK: - Curve editing

    func addCurve() {
        let hex = Self.palette[curves.count % Self.palette.count]
        curves.append(PlotCurve(colorHex: hex))
        inputsChanged()
    }

    func removeCurve(_ id: PlotCurve.ID) {
        curves.removeAll { $0.id == id }
        if curves.isEmpty { curves = [PlotCurve()] }
        inputsChanged()
    }

    /// Call after any edit to a curve's text / kind / enabled flag.
    func inputsChanged() {
        syncParameters()
        recompute()
    }

    /// Call on every slider tick. Recompute is debounced so a fast scrub coalesces.
    func parameterChanged() { scheduleResample() }

    /// Debounced resample, shared by slider scrubs and pan/zoom so a fast gesture
    /// coalesces into a single recompute on the next runloop tick.
    func scheduleResample() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recompute() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
    }

    // MARK: - CSV import

    /// Reads the general pasteboard, parses it as CSV/TSV, and appends the resulting
    /// series. Returns the number of series added (0 if the clipboard held no numbers).
    @discardableResult
    func importClipboardCSV() -> Int {
        guard let text = NSPasteboard.general.string(forType: .string) else { return 0 }
        let series = CSVPlotParser.parse(text)
        guard !series.isEmpty else { return 0 }
        dataSeries.append(contentsOf: series)
        fitToContent()
        return series.count
    }

    func removeDataSeries(_ id: DataSeries.ID) {
        dataSeries.removeAll { $0.id == id }
    }

    var hasData: Bool { !dataSeries.isEmpty }

    // MARK: - Viewport control

    /// Translate the viewport by a pixel delta (drag). Positive `dx` moves content right.
    func pan(byPixels delta: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let mathDX = Double(delta.width) / Double(canvasSize.width) * viewport.width
        let mathDY = Double(delta.height) / Double(canvasSize.height) * viewport.height
        // Screen y grows downward, math y grows upward -> add dy.
        viewport = viewport.translated(dx: -mathDX, dy: mathDY)
    }

    /// Zoom about an anchor point (in screen coordinates). `factor < 1` zooms in.
    func zoom(factor: Double, anchor: CGPoint) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let clamped = min(max(factor, 0.02), 50)
        let math = Self.mathPoint(forScreen: anchor, in: canvasSize, viewport: viewport)
        viewport = viewport.scaled(by: clamped, aroundMathX: math.x, mathY: math.y)
        scheduleResample()
    }

    /// Reset to a sensible frame: fit imported data if present, else the standard window.
    func fitToContent() {
        if let box = Self.boundingBox(of: dataSeries) {
            viewport = Viewport(box).padded(by: 0.12)
        } else {
            viewport = .standard
        }
        recompute()
    }

    func resetViewport() {
        viewport = .standard
        recompute()
    }

    // MARK: - Parameter discovery

    /// Recompute the set of free parameters across enabled curves and keep their values,
    /// defaulting new ones to 1 (Desmos-style) so a freshly typed `a` shows something.
    private func syncParameters() {
        let names = Self.freeParameterNames(in: curves)
        var next: [String: Double] = [:]
        for name in names {
            next[name] = parameters[name] ?? 1
        }
        parameters = next
    }

    /// The sorted list of parameter names the UI should render sliders for.
    var parameterNames: [String] { parameters.keys.sorted() }

    // MARK: - Sampling

    private func recompute() {
        let vp = viewport
        let steps = sampleSteps
        let params = parameters

        var results: [RenderedCurve] = []
        for curve in curves where curve.enabled {
            let domain = vp.xRange
            // Parametric/polar sweep a full turn-ish range independent of zoom.
            let paramRange: ClosedRange<Double> = curve.kind == .explicit
                ? domain
                : -Double.pi * 2 ... Double.pi * 2
            let points = curve.sample(
                domain: domain,
                paramRange: paramRange,
                steps: steps,
                params: params
            )
            guard !points.isEmpty else { continue }
            results.append(RenderedCurve(id: curve.id, colorHex: curve.colorHex, points: points))
        }
        renderedCurves = results
    }

    // MARK: - Static helpers (pure, nonisolated)

    /// The default colour rotation for new curves (matches the notch accent family).
    static let palette: [String] = [
        "#0A84FF", "#FF375F", "#30D158", "#FFD60A",
        "#BF5AF2", "#FF9F0A", "#64D2FF", "#FF6482",
    ]

    /// Returns every free variable that is *not* a curve's own independent variable.
    nonisolated static func freeParameterNames(in curves: [PlotCurve]) -> Set<String> {
        var result: Set<String> = []
        for curve in curves where curve.enabled {
            let independent = curve.independentVariable
            for source in [curve.expressionA, curve.expressionB] {
                guard !source.trimmingCharacters(in: .whitespaces).isEmpty,
                      let expr = PlotExpression(source) else { continue }
                for name in expr.variableNames where name != independent {
                    result.insert(name)
                }
            }
        }
        return result
    }

    nonisolated static func boundingBox(of series: [DataSeries]) -> CGRect? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var found = false
        for s in series {
            for p in s.points where p.x.isFinite && p.y.isFinite {
                found = true
                minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
                minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
            }
        }
        guard found else { return nil }
        // Guard a degenerate box (single point / flat line).
        if maxX - minX < 1e-9 { minX -= 1; maxX += 1 }
        if maxY - minY < 1e-9 { minY -= 1; maxY += 1 }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Maps a math point to screen coordinates for the given viewport and canvas size.
    nonisolated static func screenPoint(forMath p: CGPoint, in size: CGSize, viewport: Viewport) -> CGPoint {
        let sx = (Double(p.x) - viewport.minX) / viewport.width * Double(size.width)
        let sy = (1 - (Double(p.y) - viewport.minY) / viewport.height) * Double(size.height)
        return CGPoint(x: sx, y: sy)
    }

    /// Inverse of `screenPoint`: maps a screen point back to math coordinates.
    nonisolated static func mathPoint(forScreen p: CGPoint, in size: CGSize, viewport: Viewport) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let mx = viewport.minX + Double(p.x) / Double(size.width) * viewport.width
        let my = viewport.minY + (1 - Double(p.y) / Double(size.height)) * viewport.height
        return CGPoint(x: mx, y: my)
    }
}

// MARK: - Viewport

/// An axis-aligned math rectangle (the window currently shown). Stored by its origin and
/// span so pan/zoom are simple arithmetic; never allowed to collapse to zero size.
struct Viewport: Equatable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double

    static let standard = Viewport(minX: -10, minY: -7, width: 20, height: 14)

    /// Largest absolute origin offset we allow. Past this the Double ULP of `minX`/`minY`
    /// can exceed a gridline step, which collapses the grid and (without the counted draw
    /// loops) would spin. Clamping here keeps ulp(minX) ≤ ~1e-4 on every code path —
    /// pan, zoom, fit-to-content, and CSV import.
    static let maxOffset: Double = 1e12

    init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX.isFinite ? max(min(minX, Self.maxOffset), -Self.maxOffset) : 0
        self.minY = minY.isFinite ? max(min(minY, Self.maxOffset), -Self.maxOffset) : 0
        self.width = max(width, 1e-6)
        self.height = max(height, 1e-6)
    }

    init(_ rect: CGRect) {
        self.init(minX: Double(rect.minX), minY: Double(rect.minY),
                  width: Double(rect.width), height: Double(rect.height))
    }

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
    var xRange: ClosedRange<Double> { minX...maxX }
    var yRange: ClosedRange<Double> { minY...maxY }

    func translated(dx: Double, dy: Double) -> Viewport {
        Viewport(minX: minX + dx, minY: minY + dy, width: width, height: height)
    }

    /// Scales the window by `factor` while keeping the given math point fixed on screen.
    func scaled(by factor: Double, aroundMathX ax: Double, mathY ay: Double) -> Viewport {
        let newW = max(min(width * factor, 1e9), 1e-6)
        let newH = max(min(height * factor, 1e9), 1e-6)
        // Keep (ax, ay)'s fractional position within the window constant.
        let fx = width > 0 ? (ax - minX) / width : 0.5
        let fy = height > 0 ? (ay - minY) / height : 0.5
        return Viewport(minX: ax - fx * newW, minY: ay - fy * newH, width: newW, height: newH)
    }

    /// Returns a copy expanded outward on all sides by `fraction` of each span.
    func padded(by fraction: Double) -> Viewport {
        let px = width * fraction
        let py = height * fraction
        return Viewport(minX: minX - px, minY: minY - py,
                        width: width + 2 * px, height: height + 2 * py)
    }
}

// MARK: - Rendered curve

/// A sampled curve ready for the canvas, in math coordinates.
struct RenderedCurve: Identifiable, Equatable {
    let id: UUID
    let colorHex: String
    let points: [CGPoint]
}

// MARK: - Hex color helper (file-local, plot-scoped to avoid collisions)

extension Color {
    /// Parses a `#RRGGBB` / `#RRGGBBAA` hex string, falling back to a calm blue so a bad
    /// swatch never throws or shows as clear.
    init(plotHex hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        string = string.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: string).scanHexInt64(&rgb) else {
            self = Color(red: 0.04, green: 0.52, blue: 1.0)
            return
        }
        let r, g, b, a: Double
        switch string.count {
        case 6:
            r = Double((rgb & 0xFF0000) >> 16) / 255
            g = Double((rgb & 0x00FF00) >> 8) / 255
            b = Double(rgb & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((rgb & 0xFF000000) >> 24) / 255
            g = Double((rgb & 0x00FF0000) >> 16) / 255
            b = Double((rgb & 0x0000FF00) >> 8) / 255
            a = Double(rgb & 0x000000FF) / 255
        default:
            self = Color(red: 0.04, green: 0.52, blue: 1.0)
            return
        }
        self = Color(red: r, green: g, blue: b, opacity: a)
    }

    /// Best-effort `#RRGGBB` for round-tripping a `ColorPicker` selection back to a curve.
    var plotHexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
