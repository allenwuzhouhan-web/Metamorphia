import Foundation

/// A fully local, unit-aware calculator that handles mixed-unit arithmetic and conversions.
/// Supports abbreviations like `mo` (month), `d` (day), `m` (million), `kg`, `km`, etc.
/// Examples: "1g + 100kg + 1t", "100f to c", "2h + 30min", "5m + 200k"
/// Zero API calls — returns instantly.
enum SmartCalculator {

    // MARK: - Public API

    /// Evaluates the input as a unit-aware expression. Returns formatted result or nil if not calculable.
    static func evaluate(_ input: String) -> String? {
        let cleaned = preprocess(input)
        guard looksLikeCalculation(cleaned) else { return nil }

        // Conversion mode: "100f to c", "5km to miles"
        if let result = tryConversion(cleaned) { return result }

        // Money shorthand: "5m + 200k", "10k + 5k", "2b / 4"
        if let result = tryMoneyShorthand(cleaned) { return result }

        // Mixed-unit arithmetic: "1g + 100kg + 1t"
        if let result = tryMixedUnitArithmetic(cleaned) { return result }

        // Percentage: "15% of 240"
        if let result = tryPercentage(cleaned) { return result }

        // Pure math fallback via NSExpression
        if let result = tryPureMath(cleaned) { return result }

        return nil
    }

    // MARK: - Dimensions & Units

    enum Dimension: String {
        case time, mass, length, volume, data, money, temperature, speed, area, energy, pressure
    }

    struct UnitInfo {
        let dimension: Dimension
        let toBase: Double        // multiply by this to convert to base unit
        let symbol: String        // display symbol
        let baseName: String      // base unit name for this dimension
    }

    // Base units: second, gram, meter, milliliter, byte, 1 (money), kelvin, m/s, sqm, joule, pascal
    static let unitMap: [String: UnitInfo] = {
        var map: [String: UnitInfo] = [:]

        // Time (base: seconds)
        let timeUnits: [(String, Double, String)] = [
            ("s", 1, "s"), ("sec", 1, "s"), ("second", 1, "s"), ("seconds", 1, "s"),
            ("min", 60, "min"), ("minute", 60, "min"), ("minutes", 60, "min"),
            ("h", 3600, "h"), ("hr", 3600, "h"), ("hour", 3600, "h"), ("hours", 3600, "h"),
            ("d", 86400, "d"), ("day", 86400, "d"), ("days", 86400, "d"),
            ("w", 604800, "w"), ("wk", 604800, "w"), ("week", 604800, "w"), ("weeks", 604800, "w"),
            ("mo", 2592000, "mo"), ("month", 2592000, "mo"), ("months", 2592000, "mo"),
            ("y", 31536000, "y"), ("yr", 31536000, "y"), ("year", 31536000, "y"), ("years", 31536000, "y"),
        ]
        for (abbr, factor, sym) in timeUnits {
            map[abbr] = UnitInfo(dimension: .time, toBase: factor, symbol: sym, baseName: "seconds")
        }

        // Mass (base: grams)
        let massUnits: [(String, Double, String)] = [
            ("mg", 0.001, "mg"),
            ("g", 1, "g"), ("gram", 1, "g"), ("grams", 1, "g"),
            ("kg", 1000, "kg"), ("kilogram", 1000, "kg"), ("kilograms", 1000, "kg"),
            ("lb", 453.592, "lb"), ("lbs", 453.592, "lb"), ("pound", 453.592, "lb"), ("pounds", 453.592, "lb"),
            ("oz", 28.3495, "oz"), ("ounce", 28.3495, "oz"), ("ounces", 28.3495, "oz"),
            ("t", 1_000_000, "t"), ("ton", 907_185, "ton"), ("tons", 907_185, "ton"),
            ("tonne", 1_000_000, "t"), ("tonnes", 1_000_000, "t"),
            ("mt", 1_000_000, "t"),
        ]
        for (abbr, factor, sym) in massUnits {
            map[abbr] = UnitInfo(dimension: .mass, toBase: factor, symbol: sym, baseName: "g")
        }

        // Length (base: meters)
        let lengthUnits: [(String, Double, String)] = [
            ("mm", 0.001, "mm"), ("millimeter", 0.001, "mm"),
            ("cm", 0.01, "cm"), ("centimeter", 0.01, "cm"),
            ("m", 1, "m"), ("meter", 1, "m"), ("meters", 1, "m"), ("metre", 1, "m"),
            ("km", 1000, "km"), ("kilometer", 1000, "km"), ("kilometers", 1000, "km"),
            ("in", 0.0254, "in"), ("inch", 0.0254, "in"), ("inches", 0.0254, "in"),
            ("ft", 0.3048, "ft"), ("foot", 0.3048, "ft"), ("feet", 0.3048, "ft"),
            ("yd", 0.9144, "yd"), ("yard", 0.9144, "yd"), ("yards", 0.9144, "yd"),
            ("mi", 1609.344, "mi"), ("mile", 1609.344, "mi"), ("miles", 1609.344, "mi"),
            ("nm", 1852, "nm"), ("nmi", 1852, "nmi"),  // nautical mile
        ]
        for (abbr, factor, sym) in lengthUnits {
            map[abbr] = UnitInfo(dimension: .length, toBase: factor, symbol: sym, baseName: "m")
        }

        // Volume (base: milliliters)
        let volumeUnits: [(String, Double, String)] = [
            ("ml", 1, "ml"), ("milliliter", 1, "ml"),
            ("l", 1000, "L"), ("liter", 1000, "L"), ("litre", 1000, "L"), ("liters", 1000, "L"),
            ("gal", 3785.41, "gal"), ("gallon", 3785.41, "gal"), ("gallons", 3785.41, "gal"),
            ("qt", 946.353, "qt"), ("quart", 946.353, "qt"),
            ("pt", 473.176, "pt"), ("pint", 473.176, "pt"),
            ("cup", 236.588, "cup"), ("cups", 236.588, "cup"),
            ("tbsp", 14.7868, "tbsp"), ("tablespoon", 14.7868, "tbsp"),
            ("tsp", 4.92892, "tsp"), ("teaspoon", 4.92892, "tsp"),
            ("floz", 29.5735, "fl oz"), ("fl oz", 29.5735, "fl oz"),
        ]
        for (abbr, factor, sym) in volumeUnits {
            map[abbr] = UnitInfo(dimension: .volume, toBase: factor, symbol: sym, baseName: "ml")
        }

        // Data (base: bytes)
        let dataUnits: [(String, Double, String)] = [
            ("b", 1, "B"), ("byte", 1, "B"), ("bytes", 1, "B"),
            ("kb", 1024, "KB"), ("kilobyte", 1024, "KB"),
            ("mb", 1_048_576, "MB"), ("megabyte", 1_048_576, "MB"),
            ("gb", 1_073_741_824, "GB"), ("gigabyte", 1_073_741_824, "GB"),
            ("tb", 1_099_511_627_776, "TB"), ("terabyte", 1_099_511_627_776, "TB"),
            ("pb", 1_125_899_906_842_624, "PB"), ("petabyte", 1_125_899_906_842_624, "PB"),
        ]
        for (abbr, factor, sym) in dataUnits {
            map[abbr] = UnitInfo(dimension: .data, toBase: factor, symbol: sym, baseName: "bytes")
        }

        // Money shorthand (base: 1)
        let moneyUnits: [(String, Double, String)] = [
            ("k", 1_000, "K"),
            ("thousand", 1_000, "K"),
            ("million", 1_000_000, "M"),
            ("billion", 1_000_000_000, "B"),
            ("trillion", 1_000_000_000_000, "T"),
        ]
        for (abbr, factor, sym) in moneyUnits {
            map[abbr] = UnitInfo(dimension: .money, toBase: factor, symbol: sym, baseName: "")
        }

        // Speed (base: m/s)
        let speedUnits: [(String, Double, String)] = [
            ("m/s", 1, "m/s"), ("mps", 1, "m/s"),
            ("km/h", 0.277778, "km/h"), ("kmh", 0.277778, "km/h"), ("kph", 0.277778, "km/h"),
            ("mph", 0.44704, "mph"),
            ("ft/s", 0.3048, "ft/s"), ("fps", 0.3048, "ft/s"),
            ("knot", 0.514444, "knots"), ("knots", 0.514444, "knots"),
        ]
        for (abbr, factor, sym) in speedUnits {
            map[abbr] = UnitInfo(dimension: .speed, toBase: factor, symbol: sym, baseName: "m/s")
        }

        // Area (base: square meters)
        let areaUnits: [(String, Double, String)] = [
            ("sqm", 1, "m²"), ("sqmeter", 1, "m²"), ("m²", 1, "m²"),
            ("sqft", 0.092903, "ft²"), ("ft²", 0.092903, "ft²"),
            ("sqmi", 2_589_988, "mi²"), ("mi²", 2_589_988, "mi²"),
            ("sqkm", 1_000_000, "km²"), ("km²", 1_000_000, "km²"),
            ("acre", 4046.86, "acres"), ("acres", 4046.86, "acres"),
            ("hectare", 10000, "ha"), ("ha", 10000, "ha"), ("hectares", 10000, "ha"),
        ]
        for (abbr, factor, sym) in areaUnits {
            map[abbr] = UnitInfo(dimension: .area, toBase: factor, symbol: sym, baseName: "m²")
        }

        // Energy (base: joules)
        let energyUnits: [(String, Double, String)] = [
            ("j", 1, "J"), ("joule", 1, "J"), ("joules", 1, "J"),
            ("kj", 1000, "kJ"), ("kilojoule", 1000, "kJ"),
            ("cal", 4.184, "cal"), ("calorie", 4.184, "cal"), ("calories", 4.184, "cal"),
            ("kcal", 4184, "kcal"), ("kilocalorie", 4184, "kcal"),
            ("kwh", 3_600_000, "kWh"), ("kilowatthour", 3_600_000, "kWh"),
            ("ev", 1.602e-19, "eV"), ("electronvolt", 1.602e-19, "eV"),
            ("btu", 1055.06, "BTU"),
            ("wh", 3600, "Wh"), ("watthour", 3600, "Wh"),
        ]
        for (abbr, factor, sym) in energyUnits {
            map[abbr] = UnitInfo(dimension: .energy, toBase: factor, symbol: sym, baseName: "J")
        }

        // Pressure (base: pascals)
        let pressureUnits: [(String, Double, String)] = [
            ("pa", 1, "Pa"), ("pascal", 1, "Pa"),
            ("kpa", 1000, "kPa"), ("kilopascal", 1000, "kPa"),
            ("atm", 101325, "atm"), ("atmosphere", 101325, "atm"),
            ("bar", 100000, "bar"),
            ("psi", 6894.76, "psi"),
            ("mmhg", 133.322, "mmHg"), ("torr", 133.322, "Torr"),
        ]
        for (abbr, factor, sym) in pressureUnits {
            map[abbr] = UnitInfo(dimension: .pressure, toBase: factor, symbol: sym, baseName: "Pa")
        }

        // Temperature handled separately (non-linear conversions)
        map["c"] = UnitInfo(dimension: .temperature, toBase: 1, symbol: "°C", baseName: "K")
        map["°c"] = UnitInfo(dimension: .temperature, toBase: 1, symbol: "°C", baseName: "K")
        map["celsius"] = UnitInfo(dimension: .temperature, toBase: 1, symbol: "°C", baseName: "K")
        map["f"] = UnitInfo(dimension: .temperature, toBase: 2, symbol: "°F", baseName: "K")
        map["°f"] = UnitInfo(dimension: .temperature, toBase: 2, symbol: "°F", baseName: "K")
        map["fahrenheit"] = UnitInfo(dimension: .temperature, toBase: 2, symbol: "°F", baseName: "K")
        // Note: "k" is NOT mapped to Kelvin here — it stays as money (1000x) from line 124.
        // Use "kelvin" or "°k" for temperature Kelvin to avoid ambiguity.
        map["°k"] = UnitInfo(dimension: .temperature, toBase: 3, symbol: "K", baseName: "K")
        map["kelvin"] = UnitInfo(dimension: .temperature, toBase: 3, symbol: "K", baseName: "K")

        return map
    }()

    // MARK: - Token Parsing

    enum Token {
        case number(Double)
        case unit(String)
        case op(Character) // +, -, *, /
        case toKeyword     // "to", "in", "as"
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var i = input.startIndex

        while i < input.endIndex {
            let ch = input[i]

            // Skip whitespace
            if ch.isWhitespace {
                i = input.index(after: i)
                continue
            }

            // Operators
            if ch == "+" || ch == "-" || ch == "*" || ch == "/" {
                // Distinguish negative sign from minus operator
                if ch == "-" && (tokens.isEmpty || tokens.last.map({ if case .op = $0 { return true } else { return false } }) == true) {
                    // Negative number — read ahead
                    let start = i
                    i = input.index(after: i)
                    while i < input.endIndex && (input[i].isNumber || input[i] == ".") {
                        i = input.index(after: i)
                    }
                    if let num = Double(input[start..<i]) {
                        tokens.append(.number(num))
                    }
                    continue
                }
                tokens.append(.op(ch))
                i = input.index(after: i)
                continue
            }

            // Numbers (including decimals and comma-separated like 1,000)
            if ch.isNumber || (ch == "." && i < input.index(before: input.endIndex) && input[input.index(after: i)].isNumber) {
                let start = i
                while i < input.endIndex && (input[i].isNumber || input[i] == "." || input[i] == ",") {
                    i = input.index(after: i)
                }
                let numStr = String(input[start..<i]).replacingOccurrences(of: ",", with: "")
                if let num = Double(numStr) {
                    tokens.append(.number(num))
                }
                continue
            }

            // Words (units or keywords)
            if ch.isLetter || ch == "°" || ch == "²" {
                let start = i
                while i < input.endIndex && (input[i].isLetter || input[i] == "/" || input[i] == "°" || input[i] == "²") {
                    i = input.index(after: i)
                }
                let word = String(input[start..<i]).lowercased()
                if word == "to" || word == "in" || word == "as" || word == "into" {
                    tokens.append(.toKeyword)
                } else {
                    tokens.append(.unit(word))
                }
                continue
            }

            // Skip unknown characters
            i = input.index(after: i)
        }

        return tokens
    }

    // MARK: - Money Shorthand ("5m + 200k", "10k + 5k")

    static func tryMoneyShorthand(_ input: String) -> String? {
        let tokens = tokenize(input)

        // All unit tokens must be single-letter money shorthand (k, m, b, t)
        let moneyLetters: Set<String> = ["k", "m", "b", "t"]
        let unitTokens = tokens.compactMap { if case .unit(let u) = $0 { return u } else { return nil } }
        guard !unitTokens.isEmpty, unitTokens.allSatisfy({ moneyLetters.contains($0) }) else { return nil }

        // Must not contain "to" (that's conversion)
        if tokens.contains(where: { if case .toKeyword = $0 { return true } else { return false } }) { return nil }

        let multipliers: [String: Double] = ["k": 1_000, "m": 1_000_000, "b": 1_000_000_000, "t": 1_000_000_000_000]

        var total: Double = 0
        var currentOp: Character = "+"
        var i = 0

        while i < tokens.count {
            if case .number(let num) = tokens[i] {
                var value = num
                if i + 1 < tokens.count, case .unit(let u) = tokens[i + 1], let mult = multipliers[u] {
                    value *= mult
                    i += 2
                } else {
                    i += 1
                }
                switch currentOp {
                case "+": total += value
                case "-": total -= value
                case "*": total *= value
                case "/": if value != 0 { total /= value }
                default: total += value
                }
            } else if case .op(let op) = tokens[i] {
                currentOp = op
                i += 1
            } else {
                i += 1
            }
        }

        return formatInBestUnit(total, dimension: .money)
    }

    // MARK: - Conversion Mode ("100f to c")

    static func tryConversion(_ input: String) -> String? {
        let tokens = tokenize(input)

        // Pattern: number unit "to" unit
        guard tokens.count >= 4 else { return nil }

        // Find "to" keyword
        guard let toIndex = tokens.firstIndex(where: { if case .toKeyword = $0 { return true } else { return false } }) else {
            return nil
        }
        guard toIndex >= 2 else { return nil }

        // Extract source: number + unit before "to"
        guard case .number(let value) = tokens[toIndex - 2],
              case .unit(let fromUnit) = tokens[toIndex - 1] else { return nil }

        // Extract target unit after "to"
        guard toIndex + 1 < tokens.count,
              case .unit(let toUnit) = tokens[toIndex + 1] else { return nil }

        guard let fromInfo = resolveUnit(fromUnit),
              let toInfo = resolveUnit(toUnit) else { return nil }

        // Temperature special handling
        if fromInfo.dimension == .temperature && toInfo.dimension == .temperature {
            return convertTemperature(value, from: fromInfo, to: toInfo)
        }

        // Same dimension check
        guard fromInfo.dimension == toInfo.dimension else {
            return "Cannot convert \(fromInfo.symbol) to \(toInfo.symbol) (different dimensions)."
        }

        let baseValue = value * fromInfo.toBase
        let result = baseValue / toInfo.toBase

        return "\(formatNumber(result)) \(toInfo.symbol)"
    }

    static func convertTemperature(_ value: Double, from: UnitInfo, to: UnitInfo) -> String {
        // Convert to Kelvin first
        let kelvin: Double
        switch from.symbol {
        case "°C": kelvin = value + 273.15
        case "°F": kelvin = (value - 32) * 5/9 + 273.15
        case "K":  kelvin = value
        default: return nil ?? ""
        }

        // Convert from Kelvin to target
        let result: Double
        let sym: String
        switch to.symbol {
        case "°C": result = kelvin - 273.15; sym = "°C"
        case "°F": result = (kelvin - 273.15) * 9/5 + 32; sym = "°F"
        case "K":  result = kelvin; sym = "K"
        default: return ""
        }

        return "\(formatNumber(result)) \(sym)"
    }

    // MARK: - Mixed-Unit Arithmetic ("1g + 100kg + 1t")

    static func tryMixedUnitArithmetic(_ input: String) -> String? {
        let tokens = tokenize(input)

        // Must have at least: number unit
        guard tokens.count >= 2 else { return nil }

        // Check if there's a "to" keyword — that's conversion, not arithmetic
        if tokens.contains(where: { if case .toKeyword = $0 { return true } else { return false } }) {
            return nil
        }

        // Parse value-unit pairs with operators
        var pairs: [(Double, UnitInfo)] = []
        var currentOp: Character = "+"
        var i = 0

        while i < tokens.count {
            // Expect a number
            guard case .number(let num) = tokens[i] else {
                i += 1
                continue
            }

            // Check if next token is a unit
            var unit: UnitInfo?
            if i + 1 < tokens.count, case .unit(let unitStr) = tokens[i + 1] {
                unit = resolveUnit(unitStr)
                i += 2
            } else {
                i += 1
            }

            guard let unitInfo = unit else {
                // No unit — might be pure money shorthand or no-unit number
                // Check if the number itself has a unit-like suffix handled during tokenization
                return nil
            }

            let signedNum = currentOp == "-" ? -num : num
            pairs.append((signedNum, unitInfo))

            // Next should be an operator
            if i < tokens.count, case .op(let op) = tokens[i] {
                currentOp = op
                i += 1
            } else {
                currentOp = "+"
            }
        }

        guard !pairs.isEmpty else { return nil }

        // All must be same dimension
        let dimension = pairs[0].1.dimension
        guard pairs.allSatisfy({ $0.1.dimension == dimension }) else {
            return "Cannot mix different unit types."
        }

        // Temperature arithmetic doesn't make sense (can't add temperatures)
        if dimension == .temperature { return nil }

        // Sum in base units
        let baseTotal = pairs.reduce(0.0) { $0 + $1.0 * $1.1.toBase }

        // Format in the most sensible unit
        return formatInBestUnit(baseTotal, dimension: dimension)
    }

    // MARK: - Percentage

    static func tryPercentage(_ input: String) -> String? {
        // Pattern: "X% of Y"
        let pattern = #"([\d,.]+)\s*%\s*of\s*([\d,.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else {
            return nil
        }

        guard let pctRange = Range(match.range(at: 1), in: input),
              let numRange = Range(match.range(at: 2), in: input),
              let pct = Double(input[pctRange].replacingOccurrences(of: ",", with: "")),
              let num = Double(input[numRange].replacingOccurrences(of: ",", with: "")) else {
            return nil
        }

        let result = num * pct / 100.0
        return formatNumber(result)
    }

    // MARK: - Pure Math Fallback

    static func tryPureMath(_ input: String) -> String? {
        // Only try if it looks like math (has operators and numbers)
        let mathChars = CharacterSet(charactersIn: "0123456789.+-*/()% ")
        let inputChars = CharacterSet(charactersIn: input)
        guard inputChars.isSubset(of: mathChars) else { return nil }

        let sanitized = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else { return nil }

        // Try NSExpression
        let expr: NSExpression
        do {
            expr = try NSExpression(format: sanitized)
        } catch {
            return nil
        }

        guard let result = expr.expressionValue(with: nil, context: nil) as? NSNumber else {
            return nil
        }

        return formatNumber(result.doubleValue)
    }

    // MARK: - Helpers

    static func preprocess(_ input: String) -> String {
        input
            .lowercased()
            .replacingOccurrences(of: "what's", with: "")
            .replacingOccurrences(of: "what is", with: "")
            .replacingOccurrences(of: "calculate", with: "")
            .replacingOccurrences(of: "compute", with: "")
            .replacingOccurrences(of: "how much is", with: "")
            .replacingOccurrences(of: "convert", with: "")
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksLikeCalculation(_ input: String) -> Bool {
        // Must contain at least one digit
        guard input.contains(where: { $0.isNumber }) else { return false }
        // Must contain a unit, operator, "to" keyword, or "%"
        let hasOperator = input.contains("+") || input.contains("-") || input.contains("*") || input.contains("/")
        let hasPercent = input.contains("%")
        let hasToKeyword = input.contains(" to ") || input.contains(" in ") || input.contains(" into ")
        let hasUnit = input.split(separator: " ").contains(where: { resolveUnit(String($0).lowercased()) != nil })
        return hasOperator || hasPercent || hasToKeyword || hasUnit
    }

    /// Resolves a unit string, handling ambiguity (e.g., "m" could be meters or million)
    static func resolveUnit(_ str: String) -> UnitInfo? {
        // Direct lookup
        if let info = unitMap[str] { return info }

        // Handle "m" ambiguity: in context of other length units or standalone "m" with "to"
        // Default "m" to meters (most common in calculations)
        // Money "m" (million) is handled separately when no dimension context

        return nil
    }

    /// Resolves "m" ambiguity based on context (are other units in the expression money or length?)
    static func resolveUnitInContext(_ str: String, contextDimension: Dimension?) -> UnitInfo? {
        if str == "m" {
            if contextDimension == .money {
                return unitMap["million"]
            }
            return unitMap["m"] // Default to meters
        }
        return resolveUnit(str)
    }

    // MARK: - Formatting

    static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 4
        f.minimumFractionDigits = 0
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f
    }()

    static func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            let intVal = Int(value)
            return numberFormatter.string(from: NSNumber(value: intVal)) ?? "\(intVal)"
        }
        // Determine appropriate precision
        let absVal = abs(value)
        if absVal < 0.01 {
            return String(format: "%.6f", value)
        } else if absVal < 1 {
            return String(format: "%.4f", value)
        } else if absVal < 100 {
            return String(format: "%.2f", value)
        }
        return numberFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// Formats a base-unit value in the most human-readable unit for its dimension.
    static func formatInBestUnit(_ baseValue: Double, dimension: Dimension) -> String {
        let absBase = abs(baseValue)

        // Get sorted unit tiers for each dimension (largest first)
        let tiers: [(threshold: Double, toBase: Double, symbol: String)]

        switch dimension {
        case .time:
            tiers = [
                (31536000, 31536000, "years"),
                (2592000, 2592000, "months"),
                (604800, 604800, "weeks"),
                (86400, 86400, "days"),
                (3600, 3600, "h"),
                (60, 60, "min"),
                (1, 1, "s"),
            ]
            // For time, use compound format (2h 30min 45s)
            return formatCompoundTime(baseValue)

        case .mass:
            tiers = [
                (1_000_000, 1_000_000, "t"),
                (1000, 1000, "kg"),
                (1, 1, "g"),
                (0.001, 0.001, "mg"),
            ]
        case .length:
            tiers = [
                (1000, 1000, "km"),
                (1, 1, "m"),
                (0.01, 0.01, "cm"),
                (0.001, 0.001, "mm"),
            ]
        case .volume:
            tiers = [
                (1000, 1000, "L"),
                (1, 1, "ml"),
            ]
        case .data:
            tiers = [
                (1_099_511_627_776, 1_099_511_627_776, "TB"),
                (1_073_741_824, 1_073_741_824, "GB"),
                (1_048_576, 1_048_576, "MB"),
                (1024, 1024, "KB"),
                (1, 1, "B"),
            ]
        case .money:
            tiers = [
                (1_000_000_000_000, 1_000_000_000_000, "trillion"),
                (1_000_000_000, 1_000_000_000, "billion"),
                (1_000_000, 1_000_000, "million"),
                (1_000, 1_000, "K"),
                (1, 1, ""),
            ]
        case .speed:
            tiers = [
                (0.277778, 0.277778, "km/h"),
                (1, 1, "m/s"),
            ]
        case .area:
            tiers = [
                (1_000_000, 1_000_000, "km²"),
                (10000, 10000, "ha"),
                (1, 1, "m²"),
            ]
        case .energy:
            tiers = [
                (3_600_000, 3_600_000, "kWh"),
                (4184, 4184, "kcal"),
                (1000, 1000, "kJ"),
                (1, 1, "J"),
            ]
        case .pressure:
            tiers = [
                (101325, 101325, "atm"),
                (1000, 1000, "kPa"),
                (1, 1, "Pa"),
            ]
        case .temperature:
            return formatNumber(baseValue) + " K"
        }

        // Find the best tier (largest unit where value >= 1)
        for tier in tiers {
            let converted = absBase / tier.toBase
            if converted >= 1 {
                let result = baseValue / tier.toBase
                if tier.symbol.isEmpty {
                    return formatNumber(result)
                }
                return "\(formatNumber(result)) \(tier.symbol)"
            }
        }

        // Fallback to smallest unit
        if let last = tiers.last {
            let result = baseValue / last.toBase
            return "\(formatNumber(result)) \(last.symbol)"
        }

        return formatNumber(baseValue)
    }

    /// Formats seconds as compound time (e.g., "2h 30min 45s")
    static func formatCompoundTime(_ totalSeconds: Double) -> String {
        let absSeconds = abs(totalSeconds)
        let sign = totalSeconds < 0 ? "-" : ""

        if absSeconds >= 31536000 {
            let years = Int(absSeconds / 31536000)
            let remaining = absSeconds - Double(years) * 31536000
            let days = Int(remaining / 86400)
            if days > 0 {
                return "\(sign)\(years)y \(days)d (\(formatNumber(absSeconds)) seconds)"
            }
            return "\(sign)\(years) years (\(formatNumber(absSeconds)) seconds)"
        }

        if absSeconds >= 86400 {
            let days = Int(absSeconds / 86400)
            let remaining = absSeconds - Double(days) * 86400
            let hours = Int(remaining / 3600)
            if hours > 0 {
                return "\(sign)\(days)d \(hours)h (\(formatNumber(absSeconds)) seconds)"
            }
            return "\(sign)\(days) days (\(formatNumber(absSeconds)) seconds)"
        }

        if absSeconds >= 3600 {
            let hours = Int(absSeconds / 3600)
            let remaining = absSeconds - Double(hours) * 3600
            let mins = Int(remaining / 60)
            let secs = Int(remaining) % 60
            var parts = "\(sign)\(hours)h"
            if mins > 0 { parts += " \(mins)min" }
            if secs > 0 { parts += " \(secs)s" }
            return "\(parts) (\(formatNumber(absSeconds)) seconds)"
        }

        if absSeconds >= 60 {
            let mins = Int(absSeconds / 60)
            let secs = Int(absSeconds) % 60
            var parts = "\(sign)\(mins)min"
            if secs > 0 { parts += " \(secs)s" }
            return "\(parts) (\(formatNumber(absSeconds)) seconds)"
        }

        return "\(formatNumber(totalSeconds)) seconds"
    }
}
