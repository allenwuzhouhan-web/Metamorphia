import Foundation

/// Parses a math expression once (into an RPN program) and evaluates it fast and safely.
///
/// No `NSExpression`, no `format:` strings, no code-eval: the program is a flat array of
/// `PlotRPNNode`s walked with a small numeric stack. Evaluation never throws and never
/// force-unwraps; any domain error (e.g. `ln(-1)`, divide-by-zero) yields `nil`.
public struct PlotExpression: Equatable {

    private let program: [PlotRPNNode]

    /// The free variables found in the source (e.g. `["x"]`, `["t"]`, `["a"]`).
    public let variableNames: Set<String>

    /// Returns nil when the source can't be parsed (unknown name, illegal char,
    /// unbalanced parens, empty input, …).
    public init?(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let tokens = PlotLexer.tokenize(trimmed) else { return nil }
        guard let compiled = PlotShuntingYard.compile(tokens) else { return nil }
        self.program = compiled.program
        self.variableNames = compiled.variables
    }

    /// Evaluates the expression with the given variable bindings.
    /// Returns nil on a domain error or a non-finite (`NaN`/`±inf`) result.
    public func evaluate(_ variables: [String: Double]) -> Double? {
        var stack: [Double] = []
        stack.reserveCapacity(program.count)

        for node in program {
            switch node {
            case .constant(let value):
                stack.append(value)

            case .variable(let name):
                guard let value = variables[name] else { return nil }
                stack.append(value)

            case .negate:
                guard let a = stack.popLast() else { return nil }
                stack.append(-a)

            case .binary(let op):
                guard let b = stack.popLast(), let a = stack.popLast() else { return nil }
                guard let result = Self.applyBinary(op, a, b) else { return nil }
                stack.append(result)

            case .call(let name, let argc):
                guard stack.count >= argc else { return nil }
                let args = Array(stack.suffix(argc))
                stack.removeLast(argc)
                guard let result = Self.applyFunction(name, args) else { return nil }
                stack.append(result)
            }
        }

        guard stack.count == 1, let result = stack.last, result.isFinite else { return nil }
        return result
    }

    // MARK: - Operator & function evaluation (pure, nonisolated)

    private static func applyBinary(_ op: PlotOperator, _ a: Double, _ b: Double) -> Double? {
        let value: Double
        switch op {
        case .add: value = a + b
        case .subtract: value = a - b
        case .multiply: value = a * b
        case .divide:
            if b == 0 { return nil }
            value = a / b
        case .power:
            value = pow(a, b)
        }
        return value.isFinite ? value : nil
    }

    private static func applyFunction(_ name: String, _ args: [Double]) -> Double? {
        let value: Double
        switch (name, args.count) {
        case ("sin", 1): value = sin(args[0])
        case ("cos", 1): value = cos(args[0])
        case ("tan", 1): value = tan(args[0])
        case ("asin", 1):
            if args[0] < -1 || args[0] > 1 { return nil }
            value = asin(args[0])
        case ("acos", 1):
            if args[0] < -1 || args[0] > 1 { return nil }
            value = acos(args[0])
        case ("atan", 1): value = atan(args[0])
        case ("atan2", 2): value = atan2(args[0], args[1])
        case ("sinh", 1): value = sinh(args[0])
        case ("cosh", 1): value = cosh(args[0])
        case ("tanh", 1): value = tanh(args[0])
        case ("exp", 1): value = exp(args[0])
        case ("ln", 1):
            if args[0] <= 0 { return nil }
            value = log(args[0])
        case ("log", 1):
            if args[0] <= 0 { return nil }
            value = log(args[0])
        case ("log", 2):
            // log(base, x)
            let base = args[0], x = args[1]
            if base <= 0 || base == 1 || x <= 0 { return nil }
            value = log(x) / log(base)
        case ("log2", 1):
            if args[0] <= 0 { return nil }
            value = log2(args[0])
        case ("log10", 1):
            if args[0] <= 0 { return nil }
            value = log10(args[0])
        case ("sqrt", 1):
            if args[0] < 0 { return nil }
            value = sqrt(args[0])
        case ("cbrt", 1): value = cbrt(args[0])
        case ("abs", 1): value = abs(args[0])
        case ("floor", 1): value = floor(args[0])
        case ("ceil", 1): value = ceil(args[0])
        case ("round", 1): value = (args[0]).rounded()
        case ("sign", 1): value = args[0] > 0 ? 1 : (args[0] < 0 ? -1 : 0)
        case ("min", 2): value = Swift.min(args[0], args[1])
        case ("max", 2): value = Swift.max(args[0], args[1])
        case ("mod", 2):
            if args[1] == 0 { return nil }
            value = args[0].truncatingRemainder(dividingBy: args[1])
        default:
            return nil
        }
        return value.isFinite ? value : nil
    }
}
