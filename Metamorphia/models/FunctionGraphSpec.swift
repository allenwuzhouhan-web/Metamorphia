import Foundation

public struct FunctionGraphSpec: Hashable, Sendable {
    public let rawInput: String
    public let expressionBody: String
    public let parameters: [String]
    public let independentVar: String
}

enum FunctionDetector {
    static func detect(in input: String) -> FunctionGraphSpec? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Direct forms: "y = x^2", "f(x) = ..."
        if let spec = matchExplicitY(trimmed) { return spec }
        if let spec = matchFunctionNotation(trimmed) { return spec }
        // Natural-language graph/plot requests: "graph y=x^2", "plot the function x^2",
        // "draw y = sin(x)". Strip the intent prefix, then retry — treating a bare
        // expression (no "=") as y = <expr> over x.
        if let stripped = stripGraphIntent(trimmed) {
            if let spec = matchExplicitY(stripped) { return spec }
            if let spec = matchFunctionNotation(stripped) { return spec }
            if !stripped.contains("="), let ast = ExpressionParser.parse(stripped) {
                // Only graph when it's actually a function of x (or a constant) —
                // "graph hello" shouldn't render a plot.
                let vars = ast.variables
                if vars.isEmpty || vars.contains("x") {
                    return buildSpec(body: stripped, independentVar: "x",
                                     excludeVars: ["x", "y"], rawInput: input)
                }
            }
        }
        return nil
    }

    /// Returns the expression part of an explicit "graph/plot this" request, or nil
    /// if the input isn't a graphing request. Recognizes a leading verb (graph, plot,
    /// draw, sketch, chart, visualize) optionally followed by filler like "the
    /// function", "the graph of", "of", "me", "this".
    private static func stripGraphIntent(_ input: String) -> String? {
        let lower = input.lowercased()
        let verbs = ["graph", "plot", "draw", "sketch", "chart", "visualize", "visualise"]
        guard let verb = verbs.first(where: { lower == $0 || lower.hasPrefix($0 + " ") }) else {
            return nil
        }
        var rest = String(input.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        let fillers = ["the function", "the graph of", "the curve", "a graph of",
                       "graph of", "the equation", "equation", "function",
                       "for me", "of", "me", "this"]
        var changed = true
        while changed {
            changed = false
            let fl = rest.lowercased()
            for f in fillers {
                if fl == f { rest = ""; changed = true; break }
                if fl.hasPrefix(f + " ") {
                    rest = String(rest.dropFirst(f.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    private static func matchExplicitY(_ input: String) -> FunctionGraphSpec? {
        guard let eqIdx = input.firstIndex(of: "=") else { return nil }
        let lhs = input[input.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces).lowercased()
        guard lhs == "y" else { return nil }
        let body = String(input[input.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return buildSpec(body: body, independentVar: "x", excludeVars: ["x", "y"], rawInput: input)
    }

    private static func matchFunctionNotation(_ input: String) -> FunctionGraphSpec? {
        guard let eqIdx = input.firstIndex(of: "=") else { return nil }
        let lhs = input[input.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
        guard lhs.count >= 4,
              let lp = lhs.firstIndex(of: "("),
              let rp = lhs.firstIndex(of: ")"),
              lp < rp else { return nil }

        let funcName = lhs[lhs.startIndex..<lp].trimmingCharacters(in: .whitespaces)
        guard funcName.count == 1,
              let ch = funcName.first, ch.isLetter,
              !MathTokenizer.builtinFunctions.contains(funcName.lowercased()) else { return nil }

        let varName = lhs[lhs.index(after: lp)..<rp].trimmingCharacters(in: .whitespaces)
        guard varName.count == 1, let vc = varName.first, vc.isLetter else { return nil }

        let body = String(input[input.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return buildSpec(body: body, independentVar: varName, excludeVars: [varName], rawInput: input)
    }

    private static func buildSpec(
        body: String,
        independentVar: String,
        excludeVars: Set<String>,
        rawInput: String
    ) -> FunctionGraphSpec? {
        guard let ast = ExpressionParser.parse(body) else { return nil }
        let params = ast.variables.subtracting(excludeVars).sorted()
        return FunctionGraphSpec(
            rawInput: rawInput,
            expressionBody: body,
            parameters: params,
            independentVar: independentVar
        )
    }
}
