import Foundation

/// One estimated regression coefficient with its inference statistics.
public struct RegressionCoefficient: Codable, Sendable, Hashable {
    public let name: String
    public let estimate: Double
    public let standardError: Double
    public let tStatistic: Double
    public let pValue: Double

    public init(name: String, estimate: Double, standardError: Double, tStatistic: Double, pValue: Double) {
        self.name = name
        self.estimate = estimate
        self.standardError = standardError
        self.tStatistic = tStatistic
        self.pValue = pValue
    }

    public var isSignificant: Bool { pValue.isFinite && pValue < 0.05 }
}

/// Ordinary-least-squares fit (simple or multiple) with full inference stats.
///
/// Implemented in pure Swift via the normal equations and Gauss-Jordan inversion
/// with partial pivoting — no Accelerate/LAPACK dependency. This is exact for the
/// well-conditioned, modestly-sized tables a spreadsheet holds; rank-deficient or
/// singular designs return `nil` (the copilot then reports collinearity) rather
/// than emitting NaNs.
public struct RegressionFit: Codable, Sendable, Hashable {
    public let coefficients: [RegressionCoefficient]   // index 0 is the intercept
    public let rSquared: Double
    public let adjustedRSquared: Double
    public let standardErrorOfRegression: Double
    public let fStatistic: Double
    public let fPValue: Double
    public let residuals: [Double]
    public let fitted: [Double]
    public let observationCount: Int
    public let predictorCount: Int

    /// `x` is row-major: one inner array per observation, each holding the `k`
    /// predictor values (WITHOUT an intercept column — the intercept is added
    /// internally). `predictorNames` labels the coefficients after the intercept.
    public static func ordinaryLeastSquares(
        y: [Double],
        x: [[Double]],
        predictorNames: [String]? = nil
    ) -> RegressionFit? {
        let n = y.count
        guard n > 0, x.count == n else { return nil }
        let k = x.first?.count ?? 0
        guard k > 0, x.allSatisfy({ $0.count == k }) else { return nil }
        let p = k + 1
        guard n > p else { return nil }   // need residual degrees of freedom

        // Design matrix rows: [1, x1, x2, ...].
        let design: [[Double]] = x.map { [1.0] + $0 }

        // Normal equations: XtX (p x p), XtY (p).
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var xty = [Double](repeating: 0, count: p)
        for row in 0..<n {
            let r = design[row]
            let yi = y[row]
            for i in 0..<p {
                xty[i] += r[i] * yi
                for j in 0..<p {
                    xtx[i][j] += r[i] * r[j]
                }
            }
        }

        guard let inverse = invert(xtx) else { return nil }

        // beta = (XtX)^-1 XtY
        var beta = [Double](repeating: 0, count: p)
        for i in 0..<p {
            var sum = 0.0
            for j in 0..<p { sum += inverse[i][j] * xty[j] }
            beta[i] = sum
        }

        // Fitted, residuals, sums of squares.
        var fitted = [Double](repeating: 0, count: n)
        var residuals = [Double](repeating: 0, count: n)
        var rss = 0.0
        for row in 0..<n {
            var yhat = 0.0
            for i in 0..<p { yhat += design[row][i] * beta[i] }
            fitted[row] = yhat
            let resid = y[row] - yhat
            residuals[row] = resid
            rss += resid * resid
        }
        let yMean = y.reduce(0, +) / Double(n)
        let tss = y.reduce(0) { $0 + ($1 - yMean) * ($1 - yMean) }

        let dfResidual = Double(n - p)
        let sigmaSquared = rss / dfResidual
        let standardErrorOfRegression = sigmaSquared.squareRoot()

        let rSquared = tss > 0 ? max(0, 1 - rss / tss) : 0
        let adjusted = tss > 0 ? 1 - (rss / dfResidual) / (tss / Double(n - 1)) : 0

        // F-test for overall significance (k predictors).
        let modelSS = max(0, tss - rss)
        let fStat = (k > 0 && sigmaSquared > 0) ? (modelSS / Double(k)) / sigmaSquared : 0
        let fP = fStat > 0 ? StatisticalDistributions.upperTailF(fStat, d1: Double(k), d2: dfResidual) : Double.nan

        let names = ["Intercept"] + (0..<k).map { idx in
            predictorNames?.indices.contains(idx) == true ? predictorNames![idx] : "x\(idx + 1)"
        }

        let coefficients: [RegressionCoefficient] = (0..<p).map { i in
            let variance = sigmaSquared * inverse[i][i]
            let se = variance > 0 ? variance.squareRoot() : 0
            let t = se > 0 ? beta[i] / se : 0
            let pVal = se > 0 ? StatisticalDistributions.twoTailedT(t, df: dfResidual) : Double.nan
            return RegressionCoefficient(
                name: names[i],
                estimate: beta[i],
                standardError: se,
                tStatistic: t,
                pValue: pVal
            )
        }

        return RegressionFit(
            coefficients: coefficients,
            rSquared: rSquared,
            adjustedRSquared: adjusted,
            standardErrorOfRegression: standardErrorOfRegression,
            fStatistic: fStat,
            fPValue: fP,
            residuals: residuals,
            fitted: fitted,
            observationCount: n,
            predictorCount: k
        )
    }

    public static func simpleLinear(y: [Double], x: [Double], predictorName: String = "x") -> RegressionFit? {
        ordinaryLeastSquares(y: y, x: x.map { [$0] }, predictorNames: [predictorName])
    }

    // MARK: - Matrix inverse (Gauss-Jordan, partial pivoting)

    private static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return nil }

        // Augment [A | I].
        var a = matrix
        var inv = (0..<n).map { row in (0..<n).map { col in row == col ? 1.0 : 0.0 } }

        for col in 0..<n {
            // Partial pivot: largest magnitude in this column at/below the diagonal.
            var pivotRow = col
            var pivotValue = abs(a[col][col])
            for row in (col + 1)..<n where abs(a[row][col]) > pivotValue {
                pivotValue = abs(a[row][col])
                pivotRow = row
            }
            guard pivotValue > 1e-12 else { return nil }   // singular / rank-deficient

            if pivotRow != col {
                a.swapAt(pivotRow, col)
                inv.swapAt(pivotRow, col)
            }

            let pivot = a[col][col]
            for j in 0..<n {
                a[col][j] /= pivot
                inv[col][j] /= pivot
            }

            for row in 0..<n where row != col {
                let factor = a[row][col]
                guard factor != 0 else { continue }
                for j in 0..<n {
                    a[row][j] -= factor * a[col][j]
                    inv[row][j] -= factor * inv[col][j]
                }
            }
        }
        return inv
    }
}
