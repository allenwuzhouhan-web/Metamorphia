import Foundation

/// JSON Schema helpers for building tool parameter definitions inline.
///
/// These mirror the OpenAI function-calling schema subset and are consumed by
/// every `ToolDefinition.parameters` declaration in the codebase.
public enum JSONSchema {
    public static func object(properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    public static func string(description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    public static func integer(description: String, minimum: Int? = nil, maximum: Int? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer", "description": description]
        if let min = minimum { schema["minimum"] = min }
        if let max = maximum { schema["maximum"] = max }
        return schema
    }

    public static func boolean(description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    public static func number(description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    public static func array(items: [String: Any], description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }

    public static func enumString(description: String, values: [String]) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }
}
