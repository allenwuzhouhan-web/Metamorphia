import Foundation
import MetamorphiaAgentKit

/// Search for files. Spotlight (`mdfind`) is the primary engine because
/// it's content-aware and matches what the user actually has indexed,
/// not just filename globs. Falls back to `find` for non-indexed
/// locations. Pass `doc_type` (or rely on inference from `query`) to
/// constrain results to a kind — paper → PDF, presentation → key/pptx,
/// code → swift/py/etc — so the result set never mixes a research
/// paper with a PowerPoint on the same topic.
public struct FindFilesTool: ToolDefinition {
    public let name = "find_files"
    public let description = """
    Locate files by content / filename via Spotlight, falling back to \
    `find` for non-indexed paths. Provide a `query` (free-text) and/or \
    a `pattern` (filename glob). `doc_type` filters by kind (paper, \
    document, presentation, spreadsheet, image, video, audio, code, \
    archive, text); when omitted it is inferred from the query so a \
    "paper" search is constrained to PDFs.
    """

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Free-text query — matched against file content and filename via Spotlight."),
            "pattern": JSONSchema.string(description: "Filename glob (e.g., '*.pdf', 'report*'). Used directly when query is empty."),
            "doc_type": JSONSchema.enumString(
                description: "Filter results to one document type. Inferred from query when omitted.",
                values: ["paper", "document", "presentation", "spreadsheet", "image", "video", "audio", "code", "archive", "text", "any"]
            ),
            "directory": JSONSchema.string(description: "Restrict search to this directory (default: index-wide). Use absolute or ~/-relative path."),
            "max_results": JSONSchema.integer(description: "Max results to return (default 20).", minimum: 1, maximum: 200),
        ])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = optionalString("query", from: args) ?? ""
        let pattern = optionalString("pattern", from: args) ?? ""
        let dir = optionalString("directory", from: args)
        let maxResults = optionalInt("max_results", from: args) ?? 20

        let intent: DocTypeIntent = {
            if let raw = optionalString("doc_type", from: args)?.lowercased(),
               let parsed = DocTypeIntent(rawValue: raw) {
                return parsed
            }
            let basis = query.isEmpty ? pattern : query
            return DocTypeIntent.infer(from: basis)
        }()

        // Compose the search seed: prefer query (semantic / content)
        // over pattern (syntactic) because Spotlight content matching is
        // what makes "the paper I wrote on attention" find the actual
        // paper without the user remembering its filename.
        let seed: String
        if !query.isEmpty {
            seed = query
        } else if !pattern.isEmpty {
            seed = pattern
                .replacingOccurrences(of: "*", with: " ")
                .replacingOccurrences(of: "?", with: " ")
        } else {
            return "Provide a `query` or `pattern` to search for."
        }

        let hits = await IndexedFileSearch.search(
            query: seed,
            intent: intent,
            directory: dir,
            maxResults: maxResults
        )

        if hits.isEmpty {
            return "No files matching '\(seed)'\(intent == .any ? "" : " (type: \(intent.rawValue))")."
        }

        let formatter = ISO8601DateFormatter()
        let lines = hits.map { hit -> String in
            var bits: [String] = ["- \(hit.path)"]
            if let m = hit.modifiedAt {
                bits.append("(modified \(formatter.string(from: m)))")
            }
            return bits.joined(separator: " ")
        }
        let header = "\(hits.count) match\(hits.count == 1 ? "" : "es")" +
            (intent == .any ? "" : " (type: \(intent.rawValue))") +
            " for '\(seed)':"
        return header + "\n\n" + lines.joined(separator: "\n")
    }
}
