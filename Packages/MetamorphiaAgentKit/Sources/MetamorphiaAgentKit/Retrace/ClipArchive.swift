import Foundation

/// Archives clipboard items into Retrace. The host app's existing
/// `ClipboardManager` polls `NSPasteboard` and produces a value (text, URL,
/// file path, image metadata) — it just forwards that value to
/// ``ClipArchive/record(kind:content:title:appBundleID:sourceURL:at:)``.
/// The archive then builds a Retrace `Draft` and ingests it.
///
/// Content lives in the encrypted index, not in the activity stream. The
/// stream receipt (`clipIndexed`) carries only kind + byte count.
public struct ClipArchive: Sendable {

    public let ingest: RetraceIngest

    public init(ingest: RetraceIngest) {
        self.ingest = ingest
    }

    @discardableResult
    public func record(
        kind: ClipboardKind,
        content: String,
        title: String? = nil,
        appBundleID: String? = nil,
        sourceURL: String? = nil,
        at: Date = Date()
    ) async -> Int64? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let draft = RetraceIngest.Draft(
            kind: .clip,
            timestamp: at,
            appBundleID: appBundleID,
            url: sourceURL,
            title: title ?? kind.defaultTitle(for: trimmed),
            body: trimmed,
            confidence: 1.0,
            sourceMeta: ["clipboardKind": kind.rawValue],
            interestEvent: .clipboardCopy,
            interestScale: 0.4
        )
        return await ingest.ingest(draft)
    }
}

private extension ClipboardKind {
    func defaultTitle(for content: String) -> String {
        switch self {
        case .text:
            let firstLine = content.split(separator: "\n").first.map(String.init) ?? content
            return String(firstLine.prefix(80))
        case .url:
            return URL(string: content)?.host ?? content
        case .file:
            return (content as NSString).lastPathComponent
        case .image:
            return "Image (\(content.count) bytes)"
        case .other:
            return "Clipboard item"
        }
    }
}
