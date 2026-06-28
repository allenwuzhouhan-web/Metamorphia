import Foundation

public struct ColumnSummary: Codable, Sendable, Hashable {
    public let name: String
    public let count: Int
    public let mean: Double
    public let median: Double
    public let standardDeviation: Double
    public let min: Double
    public let max: Double
    public let q1: Double
    public let q3: Double
}

public struct CorrelationMatrix: Codable, Sendable, Hashable {
    public let columnNames: [String]
    public let values: [[Double]]   // symmetric, diagonal = 1
}

public struct GroupSummaryRow: Codable, Sendable, Hashable {
    public let key: String
    public let count: Int
    public let sum: Double
    public let mean: Double
}

public struct GroupSummary: Codable, Sendable, Hashable {
    public let groupColumn: String
    public let valueColumn: String
    public let rows: [GroupSummaryRow]
}

public struct ForecastPoint: Codable, Sendable, Hashable {
    public let x: Double
    public let y: Double
}

/// Descriptive statistics, correlation, group-by aggregation, and a simple linear
/// forecast — pure Swift, sample (n-1) variance.
public enum DataTableStats {

    public static func describe(_ column: [Double], name: String) -> ColumnSummary? {
        guard !column.isEmpty else { return nil }
        let n = column.count
        let sorted = column.sorted()
        let mean = column.reduce(0, +) / Double(n)
        let variance = n > 1
            ? column.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
            : 0
        return ColumnSummary(
            name: name,
            count: n,
            mean: mean,
            median: percentile(sorted, 0.5),
            standardDeviation: variance.squareRoot(),
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            q1: percentile(sorted, 0.25),
            q3: percentile(sorted, 0.75)
        )
    }

    public static func pearsonMatrix(columns: [[Double]], names: [String]) -> CorrelationMatrix? {
        guard columns.count == names.count, columns.count >= 2 else { return nil }
        let n = columns.first?.count ?? 0
        guard n >= 2, columns.allSatisfy({ $0.count == n }) else { return nil }
        let count = columns.count
        var values = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        for i in 0..<count {
            for j in i..<count {
                let r = i == j ? 1.0 : pearson(columns[i], columns[j])
                values[i][j] = r
                values[j][i] = r
            }
        }
        return CorrelationMatrix(columnNames: names, values: values)
    }

    public static func groupBy(
        keys: [String],
        values: [Double],
        groupColumn: String,
        valueColumn: String
    ) -> GroupSummary? {
        guard keys.count == values.count, !keys.isEmpty else { return nil }
        var sums: [String: Double] = [:]
        var counts: [String: Int] = [:]
        var order: [String] = []
        for (key, value) in zip(keys, values) {
            if counts[key] == nil { order.append(key) }
            sums[key, default: 0] += value
            counts[key, default: 0] += 1
        }
        let rows = order.map { key -> GroupSummaryRow in
            let count = counts[key] ?? 0
            let sum = sums[key] ?? 0
            return GroupSummaryRow(key: key, count: count, sum: sum, mean: count > 0 ? sum / Double(count) : 0)
        }
        return GroupSummary(groupColumn: groupColumn, valueColumn: valueColumn, rows: rows)
    }

    /// Extends the best-fit line `horizon` steps past the last x (assumes evenly
    /// spaced x; falls back to integer indices if x is empty).
    public static func linearForecast(x: [Double], y: [Double], horizon: Int) -> [ForecastPoint] {
        let xs = x.isEmpty ? (0..<y.count).map(Double.init) : x
        guard xs.count == y.count, xs.count >= 2, horizon > 0,
              let fit = RegressionFit.simpleLinear(y: y, x: xs) else { return [] }
        let intercept = fit.coefficients.first?.estimate ?? 0
        let slope = fit.coefficients.count > 1 ? fit.coefficients[1].estimate : 0
        let step = (xs.max()! - xs.min()!) / Double(max(1, xs.count - 1))
        let lastX = xs.max()!
        return (1...horizon).map { i in
            let xv = lastX + step * Double(i)
            return ForecastPoint(x: xv, y: intercept + slope * xv)
        }
    }

    // MARK: - Helpers

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        guard n >= 2 else { return 0 }
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var cov = 0.0, varA = 0.0, varB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            cov += da * db
            varA += da * da
            varB += db * db
        }
        let denom = (varA * varB).squareRoot()
        return denom > 0 ? cov / denom : 0
    }
}
