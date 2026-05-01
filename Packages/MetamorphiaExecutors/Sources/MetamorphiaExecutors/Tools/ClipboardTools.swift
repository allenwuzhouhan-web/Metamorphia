import Foundation
import AppKit
import MetamorphiaAgentKit

/// Read the current clipboard text contents.
public struct GetClipboardTextTool: ToolDefinition {
    public let name = "get_clipboard_text"
    public let description = "Read the current clipboard's text contents. Returns the text or a notice if the clipboard doesn't have text."

    public var parameters: [String: Any] { JSONSchema.object(properties: [:]) }
    public init() {}

    public func execute(arguments: String) async throws -> String {
        let text: String? = await MainActor.run {
            NSPasteboard.general.string(forType: .string)
        }
        return text ?? "Clipboard contains no text."
    }
}

/// Write text to the clipboard.
public struct SetClipboardTextTool: ToolDefinition {
    public let name = "set_clipboard_text"
    public let description = "Place text on the clipboard so the user can paste it into other apps."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "Text to place on the clipboard"),
        ], required: ["text"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let text = try requiredString("text", from: args)
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        return "Copied \(text.count) chars to clipboard."
    }
}
