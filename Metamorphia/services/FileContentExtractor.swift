import Foundation
import PDFKit
import AppKit

public actor FileContentExtractor {
    public static let shared = FileContentExtractor()

    public static let perFileCharCap = 30_000
    public static let totalCharCap = 100_000
    private static let shellTimeout: TimeInterval = 10

    public init() {}

    public func extract(from url: URL) async -> CommandBarAttachedFile? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        guard CommandBarAttachedFile.supportedExtensions.contains(ext) else {
            print("[FileContentExtractor] Unsupported extension: \(ext)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            print("[FileContentExtractor] File missing or unreadable: \(url.path)")
            return nil
        }

        let size: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let rawContent: String
        switch ext {
        case "pdf":
            rawContent = extractPDF(url: url)
        case "rtf", "rtfd":
            rawContent = extractRTF(url: url)
        case "docx", "doc", "pages", "pptx", "ppt", "xlsx", "xls":
            rawContent = extractViaTextutil(url: url)
        default:
            rawContent = extractPlainText(url: url, maxChars: Self.perFileCharCap)
        }

        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("[FileContentExtractor] Empty content: \(name)")
            return nil
        }

        let capped: String = rawContent.count > Self.perFileCharCap
            ? String(rawContent.prefix(Self.perFileCharCap))
                + "\n\n[... truncated at \(Self.perFileCharCap) characters]"
            : rawContent

        return CommandBarAttachedFile(
            url: url, name: name, ext: ext,
            extractedText: capped, sizeBytes: size
        )
    }

    private func extractPDF(url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        let pageCount = min(doc.pageCount, 200)
        for i in 0..<pageCount {
            if let page = doc.page(at: i), let text = page.string {
                out.append(text)
                out.append("\n")
                if out.count > Self.perFileCharCap { break }
            }
        }
        return out
    }

    private func extractRTF(url: URL) -> String {
        if let data = try? Data(contentsOf: url),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil) {
            return attr.string
        }
        return runTextutil(url: url)
    }

    private func extractViaTextutil(url: URL) -> String {
        return runTextutil(url: url)
    }

    private func runTextutil(url: URL) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        task.arguments = ["-convert", "txt", "-stdout", url.path]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do { try task.run() } catch {
            print("[FileContentExtractor] textutil launch failed: \(error)")
            return ""
        }

        let deadline = Date().addingTimeInterval(Self.shellTimeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate()
            print("[FileContentExtractor] textutil timed out: \(url.lastPathComponent)")
            return ""
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func extractPlainText(url: URL, maxChars: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size > maxChars * 4 {
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return "" }
            defer { try? handle.close() }
            let data = handle.readData(ofLength: maxChars * 4)
            return String(data: data, encoding: .utf8) ?? ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Adjust a list so total extractedText.count <= totalCharCap.
    /// Repeatedly halves the longest file until under cap (bottoming at 2K/file).
    public static func enforceTotalCap(
        _ files: [CommandBarAttachedFile]
    ) -> [CommandBarAttachedFile] {
        var working = files
        var total = working.map { $0.extractedText.count }.reduce(0, +)
        guard total > totalCharCap else { return working }
        while total > totalCharCap {
            guard let (idx, _) = working.enumerated().max(by: {
                $0.element.extractedText.count < $1.element.extractedText.count
            }) else { break }
            let current = working[idx]
            let currentLen = current.extractedText.count
            guard currentLen > 2_000 else { break }
            let newLen = max(2_000, currentLen / 2)
            let newText = String(current.extractedText.prefix(newLen))
                + "\n\n[... truncated to \(newLen) characters to fit total cap]"
            working[idx] = CommandBarAttachedFile(
                id: current.id, url: current.url, name: current.name,
                ext: current.ext, extractedText: newText,
                extractedAt: current.extractedAt, sizeBytes: current.sizeBytes
            )
            total = working.map { $0.extractedText.count }.reduce(0, +)
        }
        return working
    }
}
