/*
 * Metamorphia
 * Shared sparkline rendering — a tiny Path-based line chart with a subtle
 * fill beneath it. No third-party chart library. Styled to sit inside the
 * notch without ceremony: no axes, no labels, no side squircles.
 */

import SwiftUI
import MetamorphiaExecutors

/// Loads a 1-day history for a single symbol and renders a compact sparkline.
/// Caches the fetched points in `@State` for the lifetime of the view.
struct MarketSparkline: View {
    let symbol: String
    var range: String = "1d"
    var tint: Color = .white

    @State private var points: [Double] = []
    @State private var isLoading: Bool = true

    var body: some View {
        SparklinePath(points: points, tint: tint)
            .task(id: symbol) {
                await load()
            }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let chart = try await YahooFinanceService().chart(symbol: symbol, range: range)
            points = chart.points.map { $0.close }
        } catch {
            points = []
        }
    }
}

/// Pure-render line + fill sparkline from a points array. Auto-scales.
struct SparklinePath: View {
    let points: [Double]
    var tint: Color = .white
    var lineWidth: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            if points.count >= 2 {
                ZStack {
                    fillPath(in: geo.size)
                        .fill(tint.opacity(0.12))
                    linePath(in: geo.size)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func linePath(in size: CGSize) -> Path {
        var path = Path()
        guard let first = normalizedPoint(index: 0, in: size) else { return path }
        path.move(to: first)
        for i in 1..<points.count {
            if let p = normalizedPoint(index: i, in: size) {
                path.addLine(to: p)
            }
        }
        return path
    }

    private func fillPath(in size: CGSize) -> Path {
        var path = linePath(in: size)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    private func normalizedPoint(index: Int, in size: CGSize) -> CGPoint? {
        guard points.count >= 2, index >= 0, index < points.count else { return nil }
        let lo = points.min() ?? 0
        let hi = points.max() ?? 1
        let range = max(hi - lo, 0.0001)
        let xStep = size.width / CGFloat(points.count - 1)
        let x = CGFloat(index) * xStep
        let y = size.height - (CGFloat((points[index] - lo) / range) * size.height)
        return CGPoint(x: x, y: y)
    }
}
