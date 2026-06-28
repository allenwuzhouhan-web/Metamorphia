import SwiftUI

struct FunctionGraphView: View {
    let spec: FunctionGraphSpec

    private let ast: MathExpression?
    @State private var parameters: [String: Double]
    @State private var appeared = false
    @State private var curveDrawn: CGFloat = 0
    @State private var graphCache = GraphDataCache()

    private let graphHeight: CGFloat = 180
    private let sampleCount = 300
    private let xRange: ClosedRange<Double> = -10...10

    init(spec: FunctionGraphSpec) {
        self.spec = spec
        self.ast = ExpressionParser.parse(spec.expressionBody)
        var initial: [String: Double] = [:]
        for p in spec.parameters { initial[p] = 1.0 }
        _parameters = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            equationLabel

            if ast != nil {
                graphCanvas
                    .frame(height: graphHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)

                if !spec.parameters.isEmpty {
                    parameterSection
                        .opacity(appeared ? 1 : 0)
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                appeared = true
            }
            withAnimation(.easeOut(duration: 0.7).delay(0.25)) {
                curveDrawn = 1
            }
        }
    }

    // MARK: - Equation Label

    private var equationLabel: some View {
        Text(prettyEquation)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
    }

    private var prettyEquation: String {
        spec.rawInput
            .replacingOccurrences(of: "^2", with: "\u{00B2}")
            .replacingOccurrences(of: "^3", with: "\u{00B3}")
            .replacingOccurrences(of: "pi", with: "\u{03C0}")
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            let data = graphData(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.03))

                gridLines(data: data, in: geo.size)
                axesView(data: data, in: geo.size)

                data.curvePath
                    .trim(from: 0, to: curveDrawn)
                    .stroke(
                        Color(red: 0.5, green: 0.58, blue: 1.0).opacity(0.35),
                        lineWidth: 7
                    )
                    .blur(radius: 4)

                data.curvePath
                    .trim(from: 0, to: curveDrawn)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.45, green: 0.62, blue: 1.0),
                                Color(red: 0.72, green: 0.45, blue: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                tickLabels(data: data, in: geo.size)
            }
        }
    }

    // MARK: - Grid & Axes

    private func gridLines(data: GraphData, in size: CGSize) -> some View {
        let xSpan = data.xRange.upperBound - data.xRange.lowerBound
        let ySpan = data.yRange.upperBound - data.yRange.lowerBound

        return Path { path in
            var x = ceil(data.xRange.lowerBound / data.xInterval) * data.xInterval
            while x <= data.xRange.upperBound + data.xInterval * 0.01 {
                let sx = CGFloat((x - data.xRange.lowerBound) / xSpan) * size.width
                path.move(to: CGPoint(x: sx, y: 0))
                path.addLine(to: CGPoint(x: sx, y: size.height))
                x += data.xInterval
            }
            var y = ceil(data.yRange.lowerBound / data.yInterval) * data.yInterval
            while y <= data.yRange.upperBound + data.yInterval * 0.01 {
                let sy = size.height - CGFloat((y - data.yRange.lowerBound) / ySpan) * size.height
                path.move(to: CGPoint(x: 0, y: sy))
                path.addLine(to: CGPoint(x: size.width, y: sy))
                y += data.yInterval
            }
        }
        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
    }

    private func axesView(data: GraphData, in size: CGSize) -> some View {
        Path { path in
            if data.xAxisScreenY >= 0 && data.xAxisScreenY <= size.height {
                path.move(to: CGPoint(x: 0, y: data.xAxisScreenY))
                path.addLine(to: CGPoint(x: size.width, y: data.xAxisScreenY))
            }
            if data.yAxisScreenX >= 0 && data.yAxisScreenX <= size.width {
                path.move(to: CGPoint(x: data.yAxisScreenX, y: 0))
                path.addLine(to: CGPoint(x: data.yAxisScreenX, y: size.height))
            }
        }
        .stroke(Color.white.opacity(0.18), lineWidth: 1)
    }

    // MARK: - Tick Labels

    private func tickLabels(data: GraphData, in size: CGSize) -> some View {
        let xSpan = data.xRange.upperBound - data.xRange.lowerBound
        let ySpan = data.yRange.upperBound - data.yRange.lowerBound
        let xTicks = tickValues(from: data.xRange, interval: data.xInterval)
        let yTicks = tickValues(from: data.yRange, interval: data.yInterval)

        return ZStack {
            ForEach(Array(xTicks.enumerated()), id: \.offset) { _, val in
                if Swift.abs(val) > data.xInterval * 0.01 {
                    let sx = CGFloat((val - data.xRange.lowerBound) / xSpan) * size.width
                    let ly = clamp(data.xAxisScreenY + 12, lo: 12, hi: size.height - 4)
                    Text(formatTick(val))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                        .position(x: sx, y: ly)
                }
            }
            ForEach(Array(yTicks.enumerated()), id: \.offset) { _, val in
                if Swift.abs(val) > data.yInterval * 0.01 {
                    let sy = size.height - CGFloat((val - data.yRange.lowerBound) / ySpan) * size.height
                    let lx = clamp(data.yAxisScreenX + 16, lo: 18, hi: size.width - 18)
                    Text(formatTick(val))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                        .position(x: lx, y: sy)
                }
            }
        }
    }

    // MARK: - Parameter Sliders

    private var parameterSection: some View {
        VStack(spacing: 6) {
            ForEach(spec.parameters, id: \.self) { param in
                HStack(spacing: 10) {
                    Text(param)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 18)

                    Slider(
                        value: Binding(
                            get: { parameters[param, default: 1] },
                            set: { parameters[param] = $0 }
                        ),
                        in: -5...5
                    )
                    .tint(Color(red: 0.5, green: 0.55, blue: 1.0))

                    Text(String(format: "%.1f", parameters[param, default: 1]))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Graph Data Computation

    private struct GraphData {
        let curvePath: Path
        let xRange: ClosedRange<Double>
        let yRange: ClosedRange<Double>
        let xAxisScreenY: CGFloat
        let yAxisScreenX: CGFloat
        let xInterval: Double
        let yInterval: Double
    }

    /// Holds the last sampled curve so a layout pass with unchanged inputs
    /// (notch resize, incidental re-render) reuses it instead of re-evaluating
    /// the AST 301 times and rebuilding the path.
    private final class GraphDataCache {
        var key: (size: CGSize, parameters: [String: Double])?
        var data: GraphData?
    }

    /// Returns memoized graph data, recomputing only when the canvas size or
    /// parameter values actually change.
    private func graphData(in size: CGSize) -> GraphData {
        if let key = graphCache.key,
           key.size == size,
           key.parameters == parameters,
           let cached = graphCache.data {
            return cached
        }
        let computed = computeGraphData(in: size)
        graphCache.key = (size, parameters)
        graphCache.data = computed
        return computed
    }

    private func computeGraphData(in size: CGSize) -> GraphData {
        let empty = GraphData(
            curvePath: Path(), xRange: -10...10, yRange: -10...10,
            xAxisScreenY: size.height / 2, yAxisScreenX: size.width / 2,
            xInterval: 5, yInterval: 5
        )
        guard let ast = ast else { return empty }

        let dx = (xRange.upperBound - xRange.lowerBound) / Double(sampleCount)
        var bindings = parameters
        var samples: [(x: Double, y: Double)] = []

        for i in 0...sampleCount {
            let x = xRange.lowerBound + dx * Double(i)
            bindings[spec.independentVar] = x
            let y = ast.evaluate(bindings: bindings)
            samples.append((x, y))
        }

        let validY = samples.map(\.y).filter { $0.isFinite }
        guard validY.count >= 2 else { return empty }

        let sorted = validY.sorted()
        let lo = sorted[Swift.max(0, sorted.count / 20)]
        let hi = sorted[Swift.min(sorted.count - 1, sorted.count * 19 / 20)]
        let span = Swift.max(hi - lo, 0.1)
        let pad = span * 0.15
        let yRange = (lo - pad)...(hi + pad)

        let xSpan = xRange.upperBound - xRange.lowerBound
        let ySpan = yRange.upperBound - yRange.lowerBound

        func sx(_ x: Double) -> CGFloat {
            CGFloat((x - xRange.lowerBound) / xSpan) * size.width
        }
        func sy(_ y: Double) -> CGFloat {
            size.height - CGFloat((y - yRange.lowerBound) / ySpan) * size.height
        }

        var path = Path()
        var drawing = false
        var prevSY: CGFloat = 0
        let jumpThreshold = size.height * 0.45

        for s in samples {
            let screenX = sx(s.x)
            let screenY = sy(s.y)
            let valid = s.y.isFinite
                && screenY > -size.height * 0.5
                && screenY < size.height * 1.5

            if !valid { drawing = false; continue }

            if drawing && Swift.abs(screenY - prevSY) > jumpThreshold {
                drawing = false
            }

            if drawing {
                path.addLine(to: CGPoint(x: screenX, y: screenY))
            } else {
                path.move(to: CGPoint(x: screenX, y: screenY))
                drawing = true
            }
            prevSY = screenY
        }

        return GraphData(
            curvePath: path,
            xRange: xRange,
            yRange: yRange,
            xAxisScreenY: sy(0),
            yAxisScreenX: sx(0),
            xInterval: niceInterval(for: xRange),
            yInterval: niceInterval(for: yRange)
        )
    }

    // MARK: - Helpers

    private func tickValues(from range: ClosedRange<Double>, interval: Double) -> [Double] {
        var values: [Double] = []
        var v = ceil(range.lowerBound / interval) * interval
        while v <= range.upperBound + interval * 0.01 {
            values.append(v)
            v += interval
        }
        return values
    }

    private func formatTick(_ value: Double) -> String {
        if value == value.rounded() && Swift.abs(value) < 10000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func clamp(_ value: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lo), hi)
    }

    private func niceInterval(for range: ClosedRange<Double>, targetCount: Int = 5) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 1 }
        let rough = span / Double(targetCount)
        let mag = Foundation.pow(10, Foundation.floor(Foundation.log10(rough)))
        let r = rough / mag
        if r <= 1.5 { return mag }
        if r <= 3.5 { return 2 * mag }
        if r <= 7.5 { return 5 * mag }
        return 10 * mag
    }
}
