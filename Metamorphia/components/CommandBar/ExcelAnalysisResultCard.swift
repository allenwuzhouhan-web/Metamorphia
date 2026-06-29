import SwiftUI

/// Renders a deterministic Excel analysis: regression equation + coefficients,
/// correlation grid, summary stats, group-by, or forecast — plus a minimal chart.
struct ExcelAnalysisResultCard: View {
    let result: ExcelAnalysisResult
    let onAction: ((ExcelAnalysisAction) async -> Void)?

    @State private var activeKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let equation = result.equation, !equation.isEmpty {
                Text(equation)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }

            fitChips

            if let coefficients = result.coefficients, !coefficients.isEmpty {
                coefficientTable(coefficients)
            }
            if let correlation = result.correlation {
                correlationGrid(correlation)
            }
            if let summaries = result.columnSummaries, !summaries.isEmpty {
                summaryTable(summaries)
            }
            if let group = result.groupSummary {
                groupTable(group)
            }
            if let forecast = result.forecast, !forecast.isEmpty {
                forecastList(forecast)
            }
            if let points = result.chartPoints, points.count >= 2 {
                miniChart(points)
            }

            if !result.interpretation.isEmpty {
                Text(result.interpretation)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.kind.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.workbookName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(result.sheetName) · \(result.sourceAddress)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            chip(result.kind.displayName, tint: .white.opacity(0.14))
        }
    }

    @ViewBuilder
    private var fitChips: some View {
        let items: [String] = {
            var out: [String] = []
            if let r2 = result.rSquared { out.append(String(format: "R² %.3f", r2)) }
            if let adj = result.adjustedRSquared { out.append(String(format: "adj %.3f", adj)) }
            if let n = result.observationCount { out.append("n \(n)") }
            if let fp = result.fPValue, fp.isFinite { out.append(String(format: "F p%@", formatP(fp))) }
            return out
        }()
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { chip($0, tint: .white.opacity(0.10)) }
            }
        }
    }

    private func coefficientTable(_ coefficients: [RegressionCoefficient]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(coefficients, id: \.name) { coef in
                HStack(spacing: 6) {
                    Circle()
                        .fill(coef.isSignificant ? Color.green.opacity(0.8) : Color.white.opacity(0.2))
                        .frame(width: 6, height: 6)
                    Text(coef.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text(String(format: "%.4g", coef.estimate))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(String(format: "p%@", formatP(coef.pValue)))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func correlationGrid(_ matrix: CorrelationMatrix) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(matrix.columnNames.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 90, alignment: .leading)
                        .lineLimit(1)
                    ForEach(Array(matrix.values[i].enumerated()), id: \.offset) { _, value in
                        Text(String(format: "%.2f", value))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(value >= 0 ? .green.opacity(0.85) : .red.opacity(0.85))
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func summaryTable(_ summaries: [ColumnSummary]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(summaries, id: \.name) { s in
                HStack(spacing: 6) {
                    Text(s.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 90, alignment: .leading)
                        .lineLimit(1)
                    Text(String(format: "μ %.3g  σ %.3g  med %.3g", s.mean, s.standardDeviation, s.median))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
            }
        }
    }

    private func groupTable(_ group: GroupSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(group.valueColumn) by \(group.groupColumn)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            ForEach(group.rows.prefix(8), id: \.key) { row in
                HStack(spacing: 6) {
                    Text(row.key)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    Text(String(format: "n %d  Σ %.4g  μ %.4g", row.count, row.sum, row.mean))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
            }
        }
    }

    private func forecastList(_ points: [ForecastPoint]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Projection")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                Text(String(format: "x %.3g  →  %.4g", point.x, point.y))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func miniChart(_ points: [ExcelChartPoint]) -> some View {
        GeometryReader { geo in
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
            let spanX = max(maxX - minX, 0.0001)
            let spanY = max(maxY - minY, 0.0001)
            let w = geo.size.width, h = geo.size.height
            let pt: (ExcelChartPoint) -> CGPoint = { p in
                CGPoint(
                    x: CGFloat((p.x - minX) / spanX) * w,
                    y: h - CGFloat((p.y - minY) / spanY) * h
                )
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    let c = pt(p)
                    Circle()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: 4, height: 4)
                        .position(c)
                }
            }
        }
        .frame(height: 64)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            actionButton(title: "Write to Excel", systemImage: "square.and.arrow.down", key: "write", action: .writeAnalysisSheet)
            actionButton(title: "Jump to data", systemImage: "arrow.right.circle", key: "jump", action: .jumpToSource)
            actionButton(title: "Copy", systemImage: "doc.on.doc", key: "copy", action: .copySummary)
        }
        .padding(.top, 2)
    }

    private func actionButton(title: String, systemImage: String, key: String, action: ExcelAnalysisAction) -> some View {
        let isRunning = activeKey == key
        return Button {
            guard activeKey == nil, let onAction else { return }
            activeKey = key
            Task {
                await onAction(action)
                await MainActor.run { activeKey = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isRunning ? "hourglass" : systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(isRunning || onAction == nil)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint))
    }

    private func formatP(_ p: Double) -> String {
        guard p.isFinite else { return "—" }
        if p < 0.001 { return "<0.001" }
        return String(format: "%.3f", p)
    }
}
