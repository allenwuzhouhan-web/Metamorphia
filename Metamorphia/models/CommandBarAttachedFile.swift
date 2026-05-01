import Foundation

/// A file attached to the command bar, extracted to plain text for prompt
/// injection. Prefixed to avoid colliding with `ScreenAssistantFile`.
public struct CommandBarAttachedFile: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let ext: String
    public let extractedText: String
    public let extractedAt: Date
    public let sizeBytes: Int64

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        ext: String,
        extractedText: String,
        extractedAt: Date = Date(),
        sizeBytes: Int64
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.ext = ext
        self.extractedText = extractedText
        self.extractedAt = extractedAt
        self.sizeBytes = sizeBytes
    }

    public static let supportedExtensions: Set<String> = [
        "txt", "md", "swift", "js", "ts", "py", "cpp", "c", "h", "hpp",
        "java", "go", "rs", "rb", "php", "css", "html", "xml", "json",
        "yaml", "yml", "toml", "sh", "zsh", "bash", "csv", "log", "tex",
        "pdf", "docx", "doc", "pages",
        "pptx", "ppt", "xlsx", "xls",
        "rtf", "rtfd",
    ]

    public var formattedForPrompt: String {
        "--- Attached file: \(name) ---\n\(extractedText)\n--- End of \(name) ---"
    }
}
