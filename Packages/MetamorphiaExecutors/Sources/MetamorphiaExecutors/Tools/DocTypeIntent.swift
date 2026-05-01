import Foundation

/// Maps natural-language hints in a query ("paper", "slides", "code",
/// "screenshot") to a concrete intent that constrains downstream search.
/// Used by ``FindFilesTool`` and the ``RecallSceneTool`` fallback so a
/// request for a "research paper" never returns a PowerPoint or a Swift
/// file on the same topic — the intent filter clamps the result set
/// to extensions consistent with the asked-for kind.
public enum DocTypeIntent: String, Sendable {
    case paper
    case document
    case presentation
    case spreadsheet
    case image
    case video
    case audio
    case code
    case archive
    case text
    case any

    /// File extensions (lower-cased, no dot) that match this intent.
    /// Empty for ``any``, which means "no extension filter".
    public var extensions: [String] {
        switch self {
        case .paper:        return ["pdf"]
        case .document:     return ["doc", "docx", "pages", "rtf", "odt"]
        case .presentation: return ["ppt", "pptx", "key", "odp"]
        case .spreadsheet:  return ["xls", "xlsx", "numbers", "csv", "ods"]
        case .image:        return ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"]
        case .video:        return ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        case .audio:        return ["mp3", "m4a", "wav", "aiff", "flac", "aac"]
        case .code:         return ["swift", "py", "js", "ts", "tsx", "jsx", "c", "cpp", "cc", "h", "hpp", "rs", "go", "java", "kt", "sh", "zsh", "bash", "rb", "php", "lua", "scala", "m", "mm", "cs"]
        case .archive:      return ["zip", "tar", "gz", "dmg", "7z", "bz2", "xz", "rar"]
        case .text:         return ["txt", "md", "log"]
        case .any:          return []
        }
    }

    /// Phrases that, when present in a query, signal an intent. The
    /// table is ordered most-specific-first so a `paper` hint wins over
    /// a generic `document` hint.
    private static let keywordTable: [(DocTypeIntent, [String])] = [
        (.paper,        ["research paper", "paper", "preprint", "manuscript", "thesis", "dissertation", "whitepaper", "white paper", "publication", "journal article", "arxiv", "academic"]),
        (.presentation, ["presentation", "slides", "slide deck", "deck", "keynote", "powerpoint", "pptx", "ppt", ".key"]),
        (.spreadsheet,  ["spreadsheet", "excel", "xlsx", "csv", "numbers file", "workbook"]),
        (.code,         ["source code", "swift file", "python file", "code file", "script", "snippet", "header file", "implementation"]),
        (.image,        ["screenshot", "screen shot", "photo", "picture", "image", "diagram"]),
        (.video,        ["video", "movie", "mp4", "screen recording", "recording"]),
        (.audio,        ["voice memo", "podcast", "song", "music", "audio", "mp3"]),
        (.archive,      ["archive", "zip file", "tarball", "dmg"]),
        (.document,     ["word doc", "word document", "docx", "pages document", "letter", "report", "memo", "essay"]),
        (.text,         ["readme", "markdown", "log file", "notes file"]),
    ]

    /// Best-guess intent from a free-text query. Returns ``any`` when
    /// nothing recognised fires — callers should treat that as "no
    /// extension filter, score across kinds".
    public static func infer(from query: String) -> DocTypeIntent {
        let q = query.lowercased()
        for (intent, keywords) in keywordTable {
            for kw in keywords where q.contains(kw) {
                return intent
            }
        }
        return .any
    }

    /// Strip the intent-signalling phrases out of a query so the
    /// residual is the topic ("research paper on attention mechanisms"
    /// → "attention mechanisms"). Stop words are also dropped so the
    /// remaining tokens are reasonable seeds for filename/content
    /// matching.
    public func extractTopicKeywords(from query: String) -> String {
        var stripped = query.lowercased()
        for (intent, keywords) in Self.keywordTable where intent == self {
            for kw in keywords {
                stripped = stripped.replacingOccurrences(of: kw, with: " ")
            }
        }
        let stopwords: Set<String> = [
            "the", "a", "an", "of", "on", "about", "for", "from", "with",
            "to", "in", "at", "by", "i", "my", "our", "find", "search",
            "look", "locate", "where", "is", "that", "this", "wrote",
            "made", "ago", "long", "did", "had", "called", "named",
        ]
        let tokens = stripped
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) && $0.count > 1 }
        return tokens.joined(separator: " ")
    }
}
