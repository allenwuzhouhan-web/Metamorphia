import Foundation
import CoreGraphics

/// The three families of curves the graphing engine can draw.
public enum PlotKind: String, Codable, CaseIterable {
    case explicit     // y = f(x)
    case parametric   // x = f(t), y = g(t)
    case polar        // r = f(theta)
}

/// A single drawable curve: its kind, one or two expression strings, plus presentation
/// state (color, enabled). Sampling compiles the expressions lazily and returns points
/// in *math* coordinates — the view layer is responsible for mapping to screen space.
public struct PlotCurve: Identifiable, Equatable {
    public var id: UUID
    public var kind: PlotKind
    public var expressionA: String   // f(x) | x(t) | r(theta)
    public var expressionB: String   // unused | y(t) | unused
    public var colorHex: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        kind: PlotKind = .explicit,
        expressionA: String = "x",
        expressionB: String = "",
        colorHex: String = "#0A84FF",
        enabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.expressionA = expressionA
        self.expressionB = expressionB
        self.colorHex = colorHex
        self.enabled = enabled
    }

    /// The independent-variable name for this curve's kind.
    /// explicit -> x, parametric -> t, polar -> theta.
    public var independentVariable: String {
        switch kind {
        case .explicit: return "x"
        case .parametric: return "t"
        case .polar: return "theta"
        }
    }

    /// Samples the curve into points in math coordinates.
    ///
    /// - Parameters:
    ///   - domain: the x-range used for `explicit` curves.
    ///   - paramRange: the t/theta-range used for `parametric` and `polar` curves.
    ///   - steps: number of segments (so `steps + 1` candidate samples). Clamped to a
    ///     sane minimum/maximum.
    ///   - params: extra constant bindings for any free variables besides the
    ///     independent one (e.g. amplitude `a` in `a*sin(x)`).
    /// - Returns: an array of `CGPoint`s. Points where the expression has no value
    ///   (domain error / discontinuity) are simply omitted, so callers should treat
    ///   gaps as breaks in the curve.
    public func sample(
        domain: ClosedRange<Double>,
        paramRange: ClosedRange<Double>,
        steps: Int,
        params: [String: Double] = [:]
    ) -> [CGPoint] {
        let count = min(max(steps, 1), 100_000)

        switch kind {
        case .explicit:
            guard let fx = PlotExpression(expressionA) else { return [] }
            return Self.sweep(over: domain, steps: count) { x in
                var vars = params
                vars["x"] = x
                guard let y = fx.evaluate(vars), y.isFinite else { return nil }
                return CGPoint(x: x, y: y)
            }

        case .parametric:
            guard let fx = PlotExpression(expressionA),
                  let gy = PlotExpression(expressionB) else { return [] }
            return Self.sweep(over: paramRange, steps: count) { t in
                var vars = params
                vars["t"] = t
                guard let x = fx.evaluate(vars), let y = gy.evaluate(vars),
                      x.isFinite, y.isFinite else { return nil }
                return CGPoint(x: x, y: y)
            }

        case .polar:
            guard let fr = PlotExpression(expressionA) else { return [] }
            return Self.sweep(over: paramRange, steps: count) { theta in
                var vars = params
                vars["theta"] = theta
                guard let r = fr.evaluate(vars), r.isFinite else { return nil }
                return CGPoint(x: r * cos(theta), y: r * sin(theta))
            }
        }
    }

    // MARK: - Sampling helper

    /// Walks `range` in `steps` even increments, mapping each value through `transform`.
    /// nil results are dropped (a domain gap), keeping the engine crash-free.
    private static func sweep(
        over range: ClosedRange<Double>,
        steps: Int,
        transform: (Double) -> CGPoint?
    ) -> [CGPoint] {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard lower.isFinite, upper.isFinite, upper > lower else {
            // Degenerate range: try the single lower bound so a constant still shows.
            if let p = transform(lower) { return [p] }
            return []
        }

        let span = upper - lower
        let stepSize = span / Double(steps)
        var points: [CGPoint] = []
        points.reserveCapacity(steps + 1)

        for index in 0...steps {
            let value = lower + Double(index) * stepSize
            if let point = transform(value) {
                points.append(point)
            }
        }
        return points
    }
}
