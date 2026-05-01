import Foundation
@_exported import MetamorphiaToolProtocol

/// Helpers layered on top of `ToolDefinition` that depend on AgentKit-internal
/// types (`AnyCodable`, `MetamorphiaError`). Kept separate from the bare
/// protocol (which lives in `MetamorphiaToolProtocol`) so that lightweight
/// consumers — for example, ComputerLib's native MCP bridge — can conform to
/// the protocol without pulling AgentKit into their dependency graph.
public extension ToolDefinition {
    /// Converts this tool into the OpenAI-compatible function schema format
    /// understood by DeepSeek / Kimi / Gemini / MiniMax / Anthropic.
    func toAPISchema() -> [String: AnyCodable] {
        [
            "type": AnyCodable("function"),
            "function": AnyCodable([
                "name": AnyCodable(name),
                "description": AnyCodable(description),
                "parameters": AnyCodable(parameters)
            ] as [String: AnyCodable])
        ]
    }

    /// Parse the LLM-provided arguments string (JSON) into a dictionary.
    func parseArguments(_ arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetamorphiaError.invalidArguments("Failed to parse JSON: \(arguments)")
        }
        return dict
    }

    func requiredString(_ key: String, from args: [String: Any]) throws -> String {
        guard let value = args[key] as? String else {
            throw MetamorphiaError.invalidArguments("Missing required parameter: \(key)")
        }
        return value
    }

    func optionalString(_ key: String, from args: [String: Any]) -> String? {
        args[key] as? String
    }

    func optionalInt(_ key: String, from args: [String: Any]) -> Int? {
        if let val = args[key] as? Int { return val }
        if let val = args[key] as? Double { return Int(val) }
        if let val = args[key] as? String, let num = Int(val) { return num }
        return nil
    }

    func requiredDouble(_ key: String, from args: [String: Any]) throws -> Double {
        if let val = args[key] as? Double { return val }
        if let val = args[key] as? Int { return Double(val) }
        if let val = args[key] as? String, let num = Double(val) { return num }
        throw MetamorphiaError.invalidArguments("Missing required parameter: \(key)")
    }

    func optionalDouble(_ key: String, from args: [String: Any]) -> Double? {
        if let val = args[key] as? Double { return val }
        if let val = args[key] as? Int { return Double(val) }
        if let val = args[key] as? String, let num = Double(val) { return num }
        return nil
    }

    func optionalBool(_ key: String, from args: [String: Any]) -> Bool? {
        args[key] as? Bool
    }
}
