import Foundation

/// Lightweight inline calculator for the Notes scratchpad. Given the part of a line
/// before a trailing "=", it returns a formatted result — or nil when the line isn't
/// math, so ordinary notes (even ones that contain "=") are left untouched.
///
/// Handles:
///   - arithmetic            `100/5`          → `20`
///   - a unit value          `1km`            → `1000 m`
///   - additive unit math    `5km + 300m`     → `5300 m`
///   - explicit conversion   `1km to m`       → `1000 m`,  `1000m to km` → `1 km`
///
/// Arithmetic is delegated to the app's existing `ExpressionParser`; units are folded
/// into base values first, so the whole thing reduces to one numeric expression.
enum AutoMath {
    /// How many base units a token represents, and which dimension it belongs to.
    private struct UnitInfo { let factor: Double; let dimension: String }

    /// The base unit each dimension reports in when no explicit target is given.
    private static let baseSymbol: [String: String] = [
        "length": "m", "mass": "g", "time": "s"
    ]

    private static let units: [String: UnitInfo] = {
        var table: [String: UnitInfo] = [:]
        func add(_ names: [String], _ factor: Double, _ dimension: String) {
            for name in names { table[name] = UnitInfo(factor: factor, dimension: dimension) }
        }
        // length (base: metre)
        add(["m", "meter", "meters", "metre", "metres"], 1, "length")
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], 1000, "length")
        add(["cm", "centimeter", "centimeters"], 0.01, "length")
        add(["mm", "millimeter", "millimeters"], 0.001, "length")
        add(["mi", "mile", "miles"], 1609.344, "length")
        add(["ft", "foot", "feet"], 0.3048, "length")
        add(["inch", "inches"], 0.0254, "length")
        add(["yd", "yard", "yards"], 0.9144, "length")
        // mass (base: gram)
        add(["g", "gram", "grams"], 1, "mass")
        add(["kg", "kilogram", "kilograms"], 1000, "mass")
        add(["mg", "milligram", "milligrams"], 0.001, "mass")
        add(["lb", "lbs", "pound", "pounds"], 453.59237, "mass")
        add(["oz", "ounce", "ounces"], 28.349523, "mass")
        add(["t", "tonne", "tonnes"], 1_000_000, "mass")
        // time (base: second)
        add(["s", "sec", "secs", "second", "seconds"], 1, "time")
        add(["min", "mins", "minute", "minutes"], 60, "time")
        add(["h", "hr", "hrs", "hour", "hours"], 3600, "time")
        add(["day", "days"], 86400, "time")
        return table
    }()

    /// Evaluate the expression (the text before a trailing "="). Returns a formatted
    /// result string, or nil if it isn't a valid numeric/unit expression.
    static func result(for rawExpression: String) -> String? {
        var expression = rawExpression.trimmingCharacters(in: .whitespaces)
        guard !expression.isEmpty else { return nil }

        // Optional explicit conversion: "<expr> to <unit>".
        var targetSymbol: String?
        var targetFactor: Double?
        var targetDimension: String?
        if let range = expression.range(of: " to ", options: [.caseInsensitive, .backwards]) {
            let lhs = String(expression[..<range.lowerBound])
            let rhs = String(expression[range.upperBound...]).trimmingCharacters(in: .whitespaces).lowercased()
            if let info = units[rhs] {
                targetSymbol = rhs
                targetFactor = info.factor
                targetDimension = info.dimension
                expression = lhs
            }
        }

        // Fold "<number><unit>" tokens into their base value, tracking the one dimension.
        var dimension: String?
        var sawUnit = false
        var consistent = true
        let numeric = replacingUnits(in: expression) { number, token in
            guard let info = units[token.lowercased()] else { return nil }
            if let existing = dimension, existing != info.dimension { consistent = false }
            dimension = info.dimension
            sawUnit = true
            return number * info.factor
        }
        guard consistent, let numericExpression = numeric else { return nil }

        // Arithmetic on the now unit-free expression, via the app's parser.
        guard let ast = ExpressionParser.parse(numericExpression) else { return nil }
        // Reject anything with free variables — the parser treats stray words ("buy
        // milk") as variables defaulting to 0, which would wrongly answer ordinary notes.
        guard ast.variables.isEmpty else { return nil }
        let value = ast.evaluate(bindings: [:])
        guard value.isFinite else { return nil }

        if let targetDimension, let targetSymbol, let targetFactor {
            guard dimension == nil || dimension == targetDimension else { return nil }
            return "\(format(value / targetFactor)) \(targetSymbol)"
        }
        if sawUnit, let dimension, let symbol = baseSymbol[dimension] {
            return "\(format(value)) \(symbol)"
        }
        return format(value)
    }

    /// Replace each `<number><unit>` run with its base-unit value. Returns nil if the
    /// `transform` rejects a token (an unknown unit), which marks the line as non-math.
    private static func replacingUnits(
        in expression: String,
        transform: (Double, String) -> Double?
    ) -> String? {
        let pattern = "([0-9]*\\.?[0-9]+)\\s*([a-zA-Z]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return expression }
        let text = expression as NSString
        var output = ""
        var cursor = 0
        var failed = false
        regex.enumerateMatches(in: expression, range: NSRange(location: 0, length: text.length)) { match, _, stop in
            guard let match else { return }
            output += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let numberText = text.substring(with: match.range(at: 1))
            let unitText = text.substring(with: match.range(at: 2))
            guard let number = Double(numberText), let base = transform(number, unitText) else {
                failed = true
                stop.pointee = true
                return
            }
            output += raw(base)
            cursor = match.range.location + match.range.length
        }
        guard !failed else { return nil }
        output += text.substring(from: cursor)
        return output
    }

    /// Full-precision numeric literal for re-parsing (no grouping, no rounding).
    private static func raw(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// Human-facing number: up to 6 decimals, trailing zeros trimmed, no grouping.
    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
