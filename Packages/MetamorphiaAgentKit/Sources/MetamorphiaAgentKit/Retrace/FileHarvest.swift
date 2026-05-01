import Foundation
import PDFKit
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Watches selected folders and ingests file content into Retrace. Uses
/// FSEvents for change detection (via `DispatchSource.makeFileSystemObjectSource`
/// on each watched root) plus an initial full crawl with incremental
/// watermark (`file_state`).
///
/// Content extraction:
/// - `.pdf` → `PDFKit.PDFDocument.string`
/// - `.txt`, `.md`, `.markdown`, source code → UTF-8 read
/// - `.rtf`, `.rtfd` → `NSAttributedString(data:options:documentAttributes:)`
/// - Images (`.png`, `.jpg`, `.heic`, ...) → Vision `VNRecognizeTextRequest`
/// - Audio (opt-in, expensive) → `SFSpeechRecognizer` (host must wire)
///
/// Each watched root is opt-in via `Defaults[.retraceFolder_*]` style settings.
/// File size cap: 50 MB (skip larger files; they're usually not text-heavy).
public final class FileHarvest: @unchecked Sendable {

    public let ingest: RetraceIngest
    private var watches: [URL: DispatchSourceFileSystemObject] = [:]
    private var rescanTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.metamorphia.retrace.fileharvest", qos: .utility)
    private let maxFileBytes: Int64 = 50 * 1024 * 1024

    public init(ingest: RetraceIngest) {
        self.ingest = ingest
    }

    public func start(watching roots: [URL]) {
        queue.async { [weak self] in
            guard let self else { return }
            for root in roots {
                self.beginWatch(root: root)
            }
        }
        // Kick off an initial crawl in the background.
        rescanTask = Task.detached(priority: .background) { [weak self] in
            for root in roots {
                await self?.fullCrawl(root: root)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, source) in self.watches { source.cancel() }
            self.watches.removeAll()
        }
        rescanTask?.cancel()
    }

    // MARK: - FSEvents watching

    private func beginWatch(root: URL) {
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task.detached(priority: .utility) {
                await self?.incrementalScan(root: root)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watches[root] = source
    }

    // MARK: - Crawling

    private func fullCrawl(root: URL) async {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        guard let enumerator else { return }

        var count = 0
        while let url = enumerator.nextObject() as? URL {
            await processFile(at: url)
            count += 1
            // Yield cooperatively every 50 files so we don't monopolize.
            if count % 50 == 0 { await Task.yield() }
            if Task.isCancelled { break }
        }
    }

    private func incrementalScan(root: URL) async {
        // Light-weight: re-enumerate but each file short-circuits on
        // unchanged mtime+size via `file_state`.
        await fullCrawl(root: root)
    }

    // MARK: - Per-file processing

    private func processFile(at url: URL) async {
        do {
            let rv = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard rv.isRegularFile == true else { return }
            let size = Int64(rv.fileSize ?? 0)
            guard size > 0, size <= maxFileBytes else { return }
            let mtime = rv.contentModificationDate?.timeIntervalSince1970 ?? 0

            // Incremental skip.
            if let prior = await ingest.index.fileStateHash(forPath: url.path),
               prior.mtime == mtime, prior.size == size {
                return
            }

            guard let extracted = await Self.extract(from: url) else { return }
            let trimmed = extracted.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 16 else { return }

            let contentHash = RetraceIngest.hash64(of: trimmed)

            let draft = RetraceIngest.Draft(
                kind: .file,
                timestamp: Date(timeIntervalSince1970: mtime),
                docPath: url.path,
                title: url.lastPathComponent,
                body: trimmed,
                confidence: extracted.confidence,
                sourceMeta: [
                    "extractor": extracted.extractor,
                    "uti": extracted.uti ?? "",
                    "size": String(size),
                ],
                interestEvent: .longDwell,
                interestScale: 0.3
            )
            let rowid = await ingest.ingest(draft)
            await ingest.index.upsertFileState(path: url.path, mtime: mtime, size: size, contentHash: contentHash, itemRowid: rowid)
        } catch {
            // Not every file is readable (permissions, dead symlinks).
            // Swallow errors; logging would be too chatty.
        }
    }

    // MARK: - Extraction dispatch

    public struct Extracted: Sendable {
        public let body: String
        public let extractor: String
        public let confidence: Double
        public let uti: String?
    }

    public static func extract(from url: URL) async -> Extracted? {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return pdf(at: url)
        case "txt", "md", "markdown", "tex", "org", "log",
             "swift", "m", "mm", "h", "c", "cpp", "cc", "js", "ts", "tsx", "jsx",
             "py", "rb", "go", "rs", "java", "kt", "scala", "sh", "bash", "zsh",
             "json", "yaml", "yml", "toml", "xml", "html", "css", "scss", "less":
            return plainText(at: url)
        case "rtf", "rtfd":
            return rtf(at: url)
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "bmp", "webp":
            return await imageOCR(at: url)
        default:
            return nil
        }
    }

    // MARK: - Extractors

    static func pdf(at url: URL) -> Extracted? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let text = page.string {
                parts.append(text)
            }
        }
        let body = parts.joined(separator: "\n\n")
        guard !body.isEmpty else { return nil }
        return Extracted(body: body, extractor: "PDFKit", confidence: 0.95, uti: "com.adobe.pdf")
    }

    static func plainText(at url: URL) -> Extracted? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let body = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? String(data: data, encoding: .isoLatin1)
        guard let body, !body.isEmpty else { return nil }
        return Extracted(body: body, extractor: "plain", confidence: 1.0, uti: "public.plain-text")
    }

    static func rtf(at url: URL) -> Extracted? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var docAttrs: NSDictionary?
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        let ref = AutoreleasingUnsafeMutablePointer<NSDictionary?>(&docAttrs)
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: ref) else {
            return nil
        }
        let body = attributed.string
        guard !body.isEmpty else { return nil }
        return Extracted(body: body, extractor: "rtf", confidence: 1.0, uti: "public.rtf")
    }

    static func imageOCR(at url: URL) async -> Extracted? {
#if canImport(Vision)
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        return await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { request, _ in
                guard let results = request.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: nil); return
                }
                let text = results
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                guard !text.isEmpty else { cont.resume(returning: nil); return }
                cont.resume(returning: Extracted(body: text, extractor: "Vision", confidence: 0.7, uti: "public.image"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .utility).async {
                try? handler.perform([request])
            }
        }
#else
        return nil
#endif
    }
}
