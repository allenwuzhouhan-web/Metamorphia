import Foundation

// Hand-written tokenizer + shunting-yard parser producing reverse-Polish notation.
// Deliberately avoids NSExpression / any string-eval: every token is recognized
// explicitly, so an unknown name fails the parse instead of running arbitrary code.
//
// This file is pure value-type logic — nonisolated, deterministic, no force-unwraps.
// Type names are `Plot`-prefixed to stay out of the math-render engine's namespace.

// MARK: - Tokens

/// A single lexical unit of a math expression.
enum PlotToken: Equatable {
    case number(Double)
    case identifier(String)   // a variable or a function/constant name
    case op(PlotOperator)
    case leftParen
    case rightParen
    case comma
}

/// Binary/unary operators recognized by the parser.
enum PlotOperator: Character, Equatable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case power = "^"

    /// Precedence: higher binds tighter.
    var precedence: Int {
        switch self {
        case .add, .subtract: return 1
        case .multiply, .divide: return 2
        case .power: return 4   // above unary minus (3) so -x^2 == -(x^2)
        }
    }

    /// `^` is right-associative; everything else is left-associative.
    var isRightAssociative: Bool { self == .power }
}

// MARK: - RPN node

/// A node in the compiled reverse-Polish program.
enum PlotRPNNode: Equatable {
    case constant(Double)         // literal or named constant (pi, e, tau)
    case variable(String)         // resolved at evaluation time
    case binary(PlotOperator)
    case negate                   // unary minus
    case call(String, Int)        // function name + argument count
}

// MARK: - Lexer

/// Splits a source string into `PlotToken`s. Returns nil on an illegal character.
enum PlotLexer {

    static func tokenize(_ source: String) -> [PlotToken]? {
        let scalars = Array(source.unicodeScalars)
        var tokens: [PlotToken] = []
        var i = 0
        let n = scalars.count

        func isIdentStart(_ s: Unicode.Scalar) -> Bool {
            CharacterSet.letters.contains(s) || s == "_"
        }
        func isIdentBody(_ s: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(s) || s == "_"
        }
        func isDigit(_ s: Unicode.Scalar) -> Bool {
            s >= "0" && s <= "9"
        }

        while i < n {
            let s = scalars[i]

            if CharacterSet.whitespacesAndNewlines.contains(s) {
                i += 1
                continue
            }

            // Number: digits with optional single dot and optional exponent (1e-3).
            if isDigit(s) || (s == "." && i + 1 < n && isDigit(scalars[i + 1])) {
                let start = i
                var seenDot = false
                var seenExp = false
                while i < n {
                    let c = scalars[i]
                    if isDigit(c) {
                        i += 1
                    } else if c == "." && !seenDot && !seenExp {
                        seenDot = true
                        i += 1
                    } else if (c == "e" || c == "E") && !seenExp
                                && i + 1 < n
                                && (isDigit(scalars[i + 1])
                                    || ((scalars[i + 1] == "+" || scalars[i + 1] == "-")
                                        && i + 2 < n && isDigit(scalars[i + 2]))) {
                        seenExp = true
                        i += 1
                        if i < n && (scalars[i] == "+" || scalars[i] == "-") { i += 1 }
                    } else {
                        break
                    }
                }
                let text = String(String.UnicodeScalarView(scalars[start..<i]))
                guard let value = Double(text) else { return nil }
                tokens.append(.number(value))
                continue
            }

            // Identifier: variable, function, or constant name.
            if isIdentStart(s) {
                let start = i
                i += 1
                while i < n && isIdentBody(scalars[i]) { i += 1 }
                let text = String(String.UnicodeScalarView(scalars[start..<i]))
                tokens.append(.identifier(text))
                continue
            }

            // Operators & punctuation.
            switch s {
            case "+": tokens.append(.op(.add)); i += 1
            case "-": tokens.append(.op(.subtract)); i += 1
            case "*", "×": tokens.append(.op(.multiply)); i += 1
            case "/", "÷": tokens.append(.op(.divide)); i += 1
            case "^": tokens.append(.op(.power)); i += 1
            case "(", "[", "{": tokens.append(.leftParen); i += 1
            case ")", "]", "}": tokens.append(.rightParen); i += 1
            case ",": tokens.append(.comma); i += 1
            default:
                return nil   // illegal character — fail the whole parse
            }
        }

        return tokens
    }
}

// MARK: - Parser (shunting-yard with implicit multiplication)

/// Compiles a token stream into an RPN program plus the set of free variables.
enum PlotShuntingYard {

    struct Compiled {
        var program: [PlotRPNNode]
        var variables: Set<String>
    }

    /// Names with a defined value or callable behaviour. Anything else is treated as
    /// a free variable. Constants resolve to literals at compile time.
    private static let constants: [String: Double] = [
        "pi": .pi,
        "e": M_E,
        "tau": 2 * .pi,
    ]

    /// Maps a function name to its accepted argument count (or counts).
    static let functionArity: [String: Set<Int>] = [
        "sin": [1], "cos": [1], "tan": [1],
        "asin": [1], "acos": [1], "atan": [1],
        "sinh": [1], "cosh": [1], "tanh": [1],
        "exp": [1], "ln": [1], "log2": [1], "log10": [1],
        "log": [1, 2],      // log(x) = natural log; log(b, x) = log base b
        "sqrt": [1], "cbrt": [1], "abs": [1],
        "floor": [1], "ceil": [1], "round": [1], "sign": [1],
        "atan2": [2], "min": [2], "max": [2], "mod": [2],
    ]

    static func compile(_ tokens: [PlotToken]) -> Compiled? {
        var output: [PlotRPNNode] = []
        var operators: [OpStackEntry] = []
        var variables: Set<String> = []
        // Argument counters for function calls currently being parsed.
        var argCounts: [Int] = []

        // Tracks whether the previous meaningful token can end an operand. Used to
        // distinguish unary from binary minus and to insert implicit multiplication.
        var prevEndsOperand = false

        func popOperatorsUntilLower(than precedence: Int, rightAssoc: Bool) {
            while let top = operators.last {
                switch top {
                case .op(let o):
                    let higher = o.precedence > precedence
                    let equalLeft = o.precedence == precedence && !rightAssoc
                    if higher || equalLeft {
                        output.append(.binary(o))
                        operators.removeLast()
                    } else { return }
                case .unaryMinus:
                    // Unary minus precedence is 3 (between multiply and power).
                    if 3 > precedence || (3 == precedence && !rightAssoc) {
                        output.append(.negate)
                        operators.removeLast()
                    } else { return }
                case .leftParen, .function:
                    return
                }
            }
        }

        func insertImplicitMultiply() {
            // Implicit multiplication binds like explicit '*'.
            popOperatorsUntilLower(than: PlotOperator.multiply.precedence, rightAssoc: false)
            operators.append(.op(.multiply))
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            switch token {
            case .number(let value):
                if prevEndsOperand { insertImplicitMultiply() }  // e.g. ")2" -> )*2
                output.append(.constant(value))
                prevEndsOperand = true

            case .identifier(let rawName):
                let name = rawName.lowercased()
                let isFunction = functionArity[name] != nil
                // Look ahead for a '(' to confirm a function call.
                let nextIsParen = index + 1 < tokens.count && tokens[index + 1] == .leftParen

                if prevEndsOperand { insertImplicitMultiply() }  // e.g. 2x, 3sin(x)

                if isFunction {
                    guard nextIsParen else { return nil }   // function without args -> fail
                    operators.append(.function(name))
                    argCounts.append(1)
                    prevEndsOperand = false
                } else if let value = constants[name] {
                    if nextIsParen { return nil }           // pi(...) is nonsense
                    output.append(.constant(value))
                    prevEndsOperand = true
                } else {
                    // A free variable. A bare name followed by '(' is an unknown
                    // function call -> reject rather than guess.
                    if nextIsParen { return nil }
                    variables.insert(name)
                    output.append(.variable(name))
                    prevEndsOperand = true
                }

            case .op(let o):
                if o == .subtract && !prevEndsOperand {
                    // Unary minus.
                    operators.append(.unaryMinus)
                    prevEndsOperand = false
                } else if o == .add && !prevEndsOperand {
                    // Unary plus is a no-op; just skip it.
                    prevEndsOperand = false
                } else {
                    guard prevEndsOperand else { return nil }  // e.g. leading '*'
                    popOperatorsUntilLower(than: o.precedence, rightAssoc: o.isRightAssociative)
                    operators.append(.op(o))
                    prevEndsOperand = false
                }

            case .leftParen:
                if prevEndsOperand { insertImplicitMultiply() }  // e.g. 2(x+1)
                operators.append(.leftParen)
                prevEndsOperand = false

            case .rightParen:
                guard popUntilLeftParen(&operators, &output) else { return nil }
                // If a function sits atop the stack, emit the call.
                if case .function(let name)? = operators.last {
                    operators.removeLast()
                    guard let count = argCounts.popLast(),
                          let arity = functionArity[name], arity.contains(count) else { return nil }
                    output.append(.call(name, count))
                }
                prevEndsOperand = true

            case .comma:
                // Separates function arguments: flush to the enclosing '(' and bump count.
                guard flushToLeftParen(&operators, &output) else { return nil }
                guard !argCounts.isEmpty else { return nil }
                argCounts[argCounts.count - 1] += 1
                prevEndsOperand = false
            }

            index += 1
        }

        // Drain remaining operators.
        while let top = operators.last {
            switch top {
            case .op(let o): output.append(.binary(o)); operators.removeLast()
            case .unaryMinus: output.append(.negate); operators.removeLast()
            case .leftParen, .function: return nil   // unbalanced parens
            }
        }

        guard !output.isEmpty else { return nil }
        // A well-formed RPN program must reduce the stack to exactly one value.
        guard stackDepthIsValid(output) else { return nil }

        return Compiled(program: output, variables: variables)
    }

    // MARK: Stack helpers

    private enum OpStackEntry {
        case op(PlotOperator)
        case unaryMinus
        case leftParen
        case function(String)
    }

    /// Pops operators into output until a left paren, which is also removed.
    private static func popUntilLeftParen(_ operators: inout [OpStackEntry],
                                          _ output: inout [PlotRPNNode]) -> Bool {
        while let top = operators.last {
            switch top {
            case .op(let o): output.append(.binary(o)); operators.removeLast()
            case .unaryMinus: output.append(.negate); operators.removeLast()
            case .leftParen: operators.removeLast(); return true
            case .function: return false   // '(' expected before a function name
            }
        }
        return false   // no matching left paren
    }

    /// Pops operators into output up to (but not removing) the enclosing left paren.
    private static func flushToLeftParen(_ operators: inout [OpStackEntry],
                                         _ output: inout [PlotRPNNode]) -> Bool {
        while let top = operators.last {
            switch top {
            case .op(let o): output.append(.binary(o)); operators.removeLast()
            case .unaryMinus: output.append(.negate); operators.removeLast()
            case .leftParen: return true
            case .function: return false
            }
        }
        return false
    }

    /// Verifies the RPN program is structurally sound by simulating stack depth.
    private static func stackDepthIsValid(_ program: [PlotRPNNode]) -> Bool {
        var depth = 0
        for node in program {
            switch node {
            case .constant, .variable:
                depth += 1
            case .negate:
                if depth < 1 { return false }
            case .binary:
                if depth < 2 { return false }
                depth -= 1
            case .call(_, let argc):
                if depth < argc { return false }
                depth -= (argc - 1)
            }
        }
        return depth == 1
    }
}
