import Foundation

// MARK: - AST

indirect enum MathExpression {
    case constant(Double)
    case variable(String)
    case negate(MathExpression)
    case add(MathExpression, MathExpression)
    case subtract(MathExpression, MathExpression)
    case multiply(MathExpression, MathExpression)
    case divide(MathExpression, MathExpression)
    case power(MathExpression, MathExpression)
    case call(String, [MathExpression])
}

extension MathExpression {
    func evaluate(bindings: [String: Double]) -> Double {
        switch self {
        case .constant(let v): return v
        case .variable(let name): return bindings[name, default: 0]
        case .negate(let e): return -e.evaluate(bindings: bindings)
        case .add(let a, let b):
            return a.evaluate(bindings: bindings) + b.evaluate(bindings: bindings)
        case .subtract(let a, let b):
            return a.evaluate(bindings: bindings) - b.evaluate(bindings: bindings)
        case .multiply(let a, let b):
            return a.evaluate(bindings: bindings) * b.evaluate(bindings: bindings)
        case .divide(let a, let b):
            let bv = b.evaluate(bindings: bindings)
            return bv == 0 ? .nan : a.evaluate(bindings: bindings) / bv
        case .power(let base, let exp):
            return pow(base.evaluate(bindings: bindings), exp.evaluate(bindings: bindings))
        case .call(let name, let args):
            let vals = args.map { $0.evaluate(bindings: bindings) }
            return MathExpression.evalBuiltin(name, args: vals)
        }
    }

    var variables: Set<String> {
        switch self {
        case .constant: return []
        case .variable(let name): return [name]
        case .negate(let e): return e.variables
        case .add(let a, let b), .subtract(let a, let b),
             .multiply(let a, let b), .divide(let a, let b),
             .power(let a, let b):
            return a.variables.union(b.variables)
        case .call(_, let args):
            return args.reduce(Set()) { $0.union($1.variables) }
        }
    }

    private static func evalBuiltin(_ name: String, args: [Double]) -> Double {
        guard let a = args.first else { return .nan }
        switch name {
        case "sin": return sin(a)
        case "cos": return cos(a)
        case "tan": return tan(a)
        case "asin": return asin(a)
        case "acos": return acos(a)
        case "atan": return args.count >= 2 ? atan2(a, args[1]) : atan(a)
        case "atan2": return args.count >= 2 ? atan2(a, args[1]) : .nan
        case "sinh": return sinh(a)
        case "cosh": return cosh(a)
        case "tanh": return tanh(a)
        case "sqrt": return sqrt(a)
        case "cbrt": return cbrt(a)
        case "abs": return Swift.abs(a)
        case "log", "log10": return log10(a)
        case "log2": return log2(a)
        case "ln": return Foundation.log(a)
        case "exp": return Foundation.exp(a)
        case "floor": return Foundation.floor(a)
        case "ceil": return Foundation.ceil(a)
        case "round": return a.rounded()
        case "sign": return a > 0 ? 1 : (a < 0 ? -1 : 0)
        case "min": return args.count >= 2 ? Swift.min(a, args[1]) : a
        case "max": return args.count >= 2 ? Swift.max(a, args[1]) : a
        case "pow": return args.count >= 2 ? Foundation.pow(a, args[1]) : .nan
        default: return .nan
        }
    }
}

// MARK: - Token

enum MathToken: Equatable {
    case number(Double)
    case identifier(String)
    case op(Character)
    case lparen
    case rparen
    case comma
}

// MARK: - Tokenizer

struct MathTokenizer {
    static let builtinFunctions: Set<String> = [
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
        "sinh", "cosh", "tanh",
        "sqrt", "cbrt", "abs", "log", "log2", "log10", "ln", "exp",
        "floor", "ceil", "round", "sign",
        "min", "max", "pow"
    ]

    static let builtinConstants: [String: Double] = [
        "pi": .pi, "PI": .pi,
        "e": M_E,
        "tau": .pi * 2
    ]

    private let chars: [Character]
    private var pos: Int = 0

    init(_ input: String) {
        self.chars = Array(input)
    }

    mutating func tokenize() -> [MathToken]? {
        var tokens: [MathToken] = []
        while pos < chars.count {
            let ch = chars[pos]
            if ch.isWhitespace { pos += 1; continue }

            if ch.isNumber || (ch == "." && pos + 1 < chars.count && chars[pos + 1].isNumber) {
                guard let num = readNumber() else { return nil }
                tokens.append(.number(num))
            } else if ch.isLetter || ch == "_" {
                let ident = readIdentifier()
                if let val = Self.builtinConstants[ident] {
                    tokens.append(.number(val))
                } else {
                    tokens.append(.identifier(ident))
                }
            } else if "+-*/^".contains(ch) {
                tokens.append(.op(ch))
                pos += 1
            } else if ch == "(" {
                tokens.append(.lparen)
                pos += 1
            } else if ch == ")" {
                tokens.append(.rparen)
                pos += 1
            } else if ch == "," {
                tokens.append(.comma)
                pos += 1
            } else {
                return nil
            }
        }
        return insertImplicitMultiplication(tokens)
    }

    private mutating func readNumber() -> Double? {
        var s = ""
        var hasDot = false
        while pos < chars.count {
            let ch = chars[pos]
            if ch.isNumber { s.append(ch); pos += 1 }
            else if ch == "." && !hasDot { hasDot = true; s.append(ch); pos += 1 }
            else { break }
        }
        return Double(s)
    }

    private mutating func readIdentifier() -> String {
        var s = ""
        while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_") {
            s.append(chars[pos])
            pos += 1
        }
        return s
    }

    private func insertImplicitMultiplication(_ tokens: [MathToken]) -> [MathToken] {
        guard tokens.count > 1 else { return tokens }
        var result: [MathToken] = [tokens[0]]
        for i in 1..<tokens.count {
            if needsImplicitMultiply(left: tokens[i - 1], right: tokens[i]) {
                result.append(.op("*"))
            }
            result.append(tokens[i])
        }
        return result
    }

    private func needsImplicitMultiply(left: MathToken, right: MathToken) -> Bool {
        switch (left, right) {
        case (.number, .number): return true
        case (.number, .identifier): return true
        case (.number, .lparen): return true
        case (.rparen, .number): return true
        case (.rparen, .identifier): return true
        case (.rparen, .lparen): return true
        case (.identifier(let n), _) where Self.builtinFunctions.contains(n):
            return false
        case (.identifier, .number): return true
        case (.identifier, .identifier): return true
        case (.identifier, .lparen): return true
        default: return false
        }
    }
}

// MARK: - Parser

struct MathParser {
    private let tokens: [MathToken]
    private var pos: Int = 0

    init(_ tokens: [MathToken]) {
        self.tokens = tokens
    }

    private var current: MathToken? { pos < tokens.count ? tokens[pos] : nil }
    private mutating func advance() { pos += 1 }

    mutating func parse() -> MathExpression? {
        guard let expr = parseExpression() else { return nil }
        return pos == tokens.count ? expr : nil
    }

    private mutating func parseExpression() -> MathExpression? {
        guard var left = parseTerm() else { return nil }
        while let tok = current, case .op(let ch) = tok, ch == "+" || ch == "-" {
            advance()
            guard let right = parseTerm() else { return nil }
            left = ch == "+" ? .add(left, right) : .subtract(left, right)
        }
        return left
    }

    private mutating func parseTerm() -> MathExpression? {
        guard var left = parseUnary() else { return nil }
        while let tok = current, case .op(let ch) = tok, ch == "*" || ch == "/" {
            advance()
            guard let right = parseUnary() else { return nil }
            left = ch == "*" ? .multiply(left, right) : .divide(left, right)
        }
        return left
    }

    private mutating func parseUnary() -> MathExpression? {
        if current == .op("-") {
            advance()
            guard let operand = parseUnary() else { return nil }
            return .negate(operand)
        }
        if current == .op("+") { advance() }
        return parsePower()
    }

    private mutating func parsePower() -> MathExpression? {
        guard let base = parsePrimary() else { return nil }
        if current == .op("^") {
            advance()
            guard let exp = parseUnary() else { return nil }
            return .power(base, exp)
        }
        return base
    }

    private mutating func parsePrimary() -> MathExpression? {
        guard let tok = current else { return nil }
        switch tok {
        case .number(let v):
            advance()
            return .constant(v)
        case .identifier(let name):
            if MathTokenizer.builtinFunctions.contains(name),
               pos + 1 < tokens.count, tokens[pos + 1] == .lparen {
                return parseFunctionCall(name)
            }
            advance()
            return .variable(name)
        case .lparen:
            advance()
            guard let expr = parseExpression() else { return nil }
            guard current == .rparen else { return nil }
            advance()
            return expr
        default:
            return nil
        }
    }

    private mutating func parseFunctionCall(_ name: String) -> MathExpression? {
        advance()
        guard current == .lparen else { return nil }
        advance()
        var args: [MathExpression] = []
        if current != .rparen {
            guard let first = parseExpression() else { return nil }
            args.append(first)
            while current == .comma {
                advance()
                guard let next = parseExpression() else { return nil }
                args.append(next)
            }
        }
        guard current == .rparen else { return nil }
        advance()
        return .call(name, args)
    }
}

// MARK: - Convenience

enum ExpressionParser {
    static func parse(_ input: String) -> MathExpression? {
        var tokenizer = MathTokenizer(input)
        guard let tokens = tokenizer.tokenize() else { return nil }
        var parser = MathParser(tokens)
        return parser.parse()
    }
}
