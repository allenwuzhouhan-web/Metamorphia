import Foundation

@MainActor
public enum ModeRouter {

    public struct ParsedCommand: Equatable {
        public let modeName: String
        public let argument: String
    }

    public static func parse(_ input: String) -> ParsedCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let withoutSlash = String(trimmed.dropFirst())
        guard let splitIndex = withoutSlash.firstIndex(where: { $0.isWhitespace }) else {
            return ParsedCommand(modeName: withoutSlash.lowercased(), argument: "")
        }
        let name = String(withoutSlash[..<splitIndex]).lowercased()
        let arg = String(withoutSlash[withoutSlash.index(after: splitIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedCommand(modeName: name, argument: arg)
    }

    private static let handlers: [String: any MetamorphiaMode.Type] = [
        LearningMode.slashKeyword: LearningMode.self,
    ]

    public static func registeredModes() -> [String] {
        handlers.keys.sorted()
    }

    public static func isKnownMode(_ name: String) -> Bool {
        handlers[name.lowercased()] != nil
    }

    @discardableResult
    public static func tryHandle(_ input: String, viewModel: AICommandViewModel) async -> Bool {
        guard let parsed = parse(input) else { return false }
        guard let modeType = handlers[parsed.modeName] else { return false }
        await modeType.handle(argument: parsed.argument, viewModel: viewModel)
        return true
    }
}
