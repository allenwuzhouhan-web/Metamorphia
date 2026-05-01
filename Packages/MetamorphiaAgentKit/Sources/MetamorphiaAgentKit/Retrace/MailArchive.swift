import Foundation
import CryptoKit

/// Scans Mail.app's `.emlx` message files and archives them into Retrace.
/// Requires Full Disk Access.
///
/// Layout (as of Mail V10):
///   `~/Library/Mail/V10/<AccountUUID>/<Mailbox>.mbox/<UUID>/Data/.../N.emlx`
///
/// `.emlx` format: a line with the raw byte count, then an RFC-822 email,
/// then a small plist of Mail-internal metadata. We parse only the RFC-822
/// portion and use a minimal header + body extractor (no external deps).
///
/// Incremental: watermark stored as the highest seen `mtime`. Files older
/// than the watermark are skipped.
public final class MailArchive: @unchecked Sendable {

    public let ingest: RetraceIngest
    public let rootPath: String
    static let sourceKey = "mail.v10"

    public static let defaultRoot = NSString(string: "~/Library/Mail").expandingTildeInPath

    public init(ingest: RetraceIngest, rootPath: String = MailArchive.defaultRoot) {
        self.ingest = ingest
        self.rootPath = rootPath
    }

    @discardableResult
    public func runIncremental(maxFiles: Int = 500) async -> Int {
        guard FileManager.default.fileExists(atPath: rootPath) else { return 0 }

        let watermark = Double(await ingest.index.archiveWatermark(for: Self.sourceKey) ?? "0") ?? 0

        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var archived = 0
        var maxSeen: Double = watermark
        var processed = 0

        while let url = enumerator?.nextObject() as? URL {
            if processed >= maxFiles { break }
            guard url.pathExtension == "emlx" else { continue }

            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = attrs?.contentModificationDate?.timeIntervalSince1970 ?? 0
            if mtime <= watermark { continue }

            if await archiveEmlx(at: url, mtime: mtime) {
                archived += 1
            }
            processed += 1
            maxSeen = max(maxSeen, mtime)
        }

        if maxSeen > watermark {
            await ingest.index.setArchiveWatermark(String(maxSeen), for: Self.sourceKey)
        }
        return archived
    }

    // MARK: - emlx parser

    private func archiveEmlx(at url: URL, mtime: Double) async -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let (headers, body) = Self.parseEmlx(data) else { return false }

        let subject = headers["subject"] ?? "(no subject)"
        let from = headers["from"] ?? ""
        let dateHeader = headers["date"].flatMap { Self.parseRFC822Date($0) }
        let timestamp = dateHeader ?? Date(timeIntervalSince1970: mtime)

        let trimmedBody = body.prefix(20_000)  // cap per email — 20KB of readable text plenty
        let fromHash = Self.shortHash(Self.extractAddress(from))

        let draft = RetraceIngest.Draft(
            kind: .email,
            timestamp: timestamp,
            title: subject,
            body: String(trimmedBody),
            confidence: 0.95,
            sourceMeta: [
                "fromHash": fromHash,
                "fromDisplay": Self.extractDisplayName(from),
                "filePath": url.path,
            ],
            interestEvent: .longDwell,
            interestScale: 0.25
        )
        return await ingest.ingest(draft) != nil
    }

    static func parseEmlx(_ data: Data) -> (headers: [String: String], body: String)? {
        // First line is a byte count; skip past the first newline.
        guard let firstNL = data.firstIndex(of: 0x0A) else { return nil }
        let rfc822 = data[(firstNL + 1)...]

        // Split headers / body at the first blank line (\r\n\r\n or \n\n).
        guard let text = String(data: rfc822, encoding: .utf8) ?? String(data: rfc822, encoding: .ascii) else {
            return nil
        }
        let separator: String
        if text.contains("\r\n\r\n") { separator = "\r\n\r\n" }
        else if text.contains("\n\n") { separator = "\n\n" }
        else { return nil }

        let parts = text.range(of: separator).map { (text[..<$0.lowerBound], text[$0.upperBound...]) }
        guard let (headerText, bodyText) = parts else { return nil }

        var headers: [String: String] = [:]
        var currentKey: String?
        var currentVal = ""
        for rawLine in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty { break }
            if line.first?.isWhitespace == true, let key = currentKey {
                currentVal += " " + line.trimmingCharacters(in: .whitespaces)
                headers[key] = currentVal
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                currentKey = String(key)
                currentVal = val
                headers[String(key)] = val
            }
        }

        // Readable-text extraction: strip simple HTML tags if present.
        let body = Self.stripHTML(String(bodyText))
        return (headers, body)
    }

    static func stripHTML(_ s: String) -> String {
        guard s.contains("<") else { return s }
        let pattern = #"<[^>]+>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(location: 0, length: s.utf16.count)
        let stripped = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        return stripped.replacingOccurrences(of: "&nbsp;", with: " ")
                       .replacingOccurrences(of: "&amp;", with: "&")
                       .replacingOccurrences(of: "&lt;", with: "<")
                       .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func parseRFC822Date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.date(from: s) ?? {
            f.dateFormat = "d MMM yyyy HH:mm:ss Z"
            return f.date(from: s)
        }()
    }

    static func extractAddress(_ from: String) -> String {
        if let lt = from.firstIndex(of: "<"), let gt = from.firstIndex(of: ">"), lt < gt {
            return String(from[from.index(after: lt)..<gt])
        }
        return from.trimmingCharacters(in: .whitespaces)
    }

    static func extractDisplayName(_ from: String) -> String {
        if let lt = from.firstIndex(of: "<") {
            return String(from[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return ""
    }

    static func shortHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
