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
        if let spec = matchExplicitY(trimmed) { return spec }
        if let spec = matchFunctionNotation(trimmed) { return spec }
        return nil
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
