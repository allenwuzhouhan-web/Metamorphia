import Foundation

/// Student-t and F distribution tail probabilities for regression significance
/// tests. Pure Swift (regularized incomplete beta via continued fraction) so
/// there is no Accelerate/LAPACK dependency to link or validate.
enum StatisticalDistributions {

    /// Two-tailed p-value for a t-statistic with `df` degrees of freedom:
    /// P(|T| > |t|).
    static func twoTailedT(_ t: Double, df: Double) -> Double {
        guard df > 0, t.isFinite else { return Double.nan }
        let x = df / (df + t * t)
        let p = regularizedIncompleteBeta(a: df / 2.0, b: 0.5, x: x)
        return min(1.0, max(0.0, p))
    }

    /// Upper-tail p-value for an F-statistic with (d1, d2) degrees of freedom:
    /// P(F > f).
    static func upperTailF(_ f: Double, d1: Double, d2: Double) -> Double {
        guard f > 0, d1 > 0, d2 > 0, f.isFinite else { return Double.nan }
        let x = d2 / (d2 + d1 * f)
        let p = regularizedIncompleteBeta(a: d2 / 2.0, b: d1 / 2.0, x: x)
        return min(1.0, max(0.0, p))
    }

    /// Regularized incomplete beta function I_x(a, b). Numerical Recipes `betai`.
    static func regularizedIncompleteBeta(a: Double, b: Double, x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lnBeta = lgamma(a + b) - lgamma(a) - lgamma(b)
        let front = exp(lnBeta + a * log(x) + b * log(1 - x))
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(a: a, b: b, x: x) / a
        } else {
            return 1 - front * betaContinuedFraction(a: b, b: a, x: 1 - x) / b
        }
    }

    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double {
        let tiny = 1e-30
        let maxIterations = 300
        let epsilon = 3e-12

        let qab = a + b
        let qap = a + 1
        let qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var result = d

        for m in 1...maxIterations {
            let mDouble = Double(m)
            let m2 = 2 * mDouble

            var numerator = mDouble * (b - mDouble) * x / ((qam + m2) * (a + m2))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            result *= d * c

            numerator = -(a + mDouble) * (qab + mDouble) * x / ((a + m2) * (qap + m2))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            result *= delta

            if abs(delta - 1) < epsilon { break }
        }
        return result
    }
}
