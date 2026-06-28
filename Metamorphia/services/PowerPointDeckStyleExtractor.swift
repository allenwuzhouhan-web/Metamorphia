import Foundation

enum PowerPointDeckStyleExtractor {
    enum ExtractionError: LocalizedError {
        case unsupportedFile
        case unreadableDeck

        var errorDescription: String? {
            switch self {
            case .unsupportedFile:
                return "Only .pptx and .ppt files can be used as design-language references."
            case .unreadableDeck:
                return "Metamorphia could not read the selected PowerPoint deck."
            }
        }
    }

    static func extractSample(from url: URL, allowModelAnalysis: Bool) async throws -> PresentationDeckSample {
        let ext = url.pathExtension.lowercased()
        guard ext == "pptx" || ext == "ppt" else { throw ExtractionError.unsupportedFile }
        if ext == "ppt" {
            return PresentationDeckSample(
                fileName: url.lastPathComponent,
                fileExtension: ext,
                slideCount: 0,
                shapeRoles: ["legacyBinaryDeck": 1],
                layoutPatterns: ["legacy PowerPoint deck"],
                allowModelAnalysis: allowModelAnalysis
            )
        }

        let entries = try await unzipList(url)
        let slidePaths = entries
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { naturalSlideIndex($0) < naturalSlideIndex($1) }
        guard !slidePaths.isEmpty else { throw ExtractionError.unreadableDeck }

        async let presentationXML = unzipText(url, entry: "ppt/presentation.xml")
        let slideXML = try await slidePaths.prefix(40).asyncCompactMap { path in
            try? await unzipText(url, entry: path)
        }
        let presentation = try? await presentationXML
        let dimensions = presentation.flatMap(slideDimensions)

        var fonts: [PresentationFontSample] = []
        var colors: [String] = []
        var roleCounts: [String: Int] = [:]
        var patterns: [String] = []

        for xml in slideXML {
            fonts.append(contentsOf: fontSamples(in: xml))
            colors.append(contentsOf: hexColors(in: xml))
            let roles = roleCountsInSlide(xml)
            for (role, count) in roles {
                roleCounts[role, default: 0] += count
            }
            patterns.append(layoutPattern(from: roles))
        }

        return PresentationDeckSample(
            fileName: url.lastPathComponent,
            fileExtension: ext,
            slideCount: slidePaths.count,
            slideWidth: dimensions?.width,
            slideHeight: dimensions?.height,
            typography: mergedFonts(fonts),
            colors: Array(NSOrderedSet(array: colors.map { $0.uppercased() }).array.prefix(16)) as? [String] ?? [],
            shapeRoles: roleCounts,
            layoutPatterns: Array(Set(patterns)).sorted(),
            allowModelAnalysis: allowModelAnalysis
        )
    }

    private static func unzipList(_ url: URL) async throws -> [String] {
        try await runUnzip(arguments: ["-Z1", url.path])
            .split(separator: "\n")
            .map(String.init)
    }

    private static func unzipText(_ url: URL, entry: String) async throws -> String {
        try await runUnzip(arguments: ["-p", url.path, entry])
    }

    private static func runUnzip(arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = arguments
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            // Drain stdout and stderr concurrently BEFORE waitUntilExit(): `unzip -p`
            // streams entry contents to stdout, and any slide/presentation XML larger
            // than the ~64KB pipe buffer would otherwise stall unzip on write() while
            // we block on waitUntilExit() — a classic deadlock. (Mirrors DocumentCopilot.runProcess.)
            let outputHandle = output.fileHandleForReading
            let errorHandle = error.fileHandleForReading
            let drainQueue = DispatchQueue(label: "com.metamorphia.unzip.drain", attributes: .concurrent)
            let group = DispatchGroup()
            var outputData = Data()
            var errorData = Data()
            group.enter()
            drainQueue.async {
                outputData = outputHandle.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            drainQueue.async {
                errorData = errorHandle.readDataToEndOfFile()
                group.leave()
            }

            // Defense in depth: if the child somehow can't be drained, don't hang the
            // import UI (and leak the security-scoped resource) forever. Terminate a
            // run that overshoots a generous deadline and surface it as an unreadable deck.
            let watchdog = DispatchWorkItem { [weak process] in process?.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: watchdog)

            try process.run()
            process.waitUntilExit()
            watchdog.cancel()
            group.wait()
            _ = errorData

            guard process.terminationStatus == 0 else { throw ExtractionError.unreadableDeck }
            return String(data: outputData, encoding: .utf8) ?? ""
        }.value
    }

    private static func naturalSlideIndex(_ path: String) -> Int {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return Int(name.replacingOccurrences(of: "slide", with: "")) ?? Int.max
    }

    private static func slideDimensions(in xml: String) -> (width: Double, height: Double)? {
        guard let tag = firstMatch(#"<p:sldSz[^>]*>"#, in: xml),
              let cx = attribute("cx", in: tag),
              let cy = attribute("cy", in: tag),
              let width = Double(cx),
              let height = Double(cy) else {
            return nil
        }
        return (width / 12_700.0, height / 12_700.0)
    }

    private static func fontSamples(in xml: String) -> [PresentationFontSample] {
        let names = matches(#"typeface="([^"]+)""#, in: xml)
            .map { decodeXML($0) }
            .filter { !$0.isEmpty && $0 != "+mj-lt" && $0 != "+mn-lt" }
        let sizes = matches(#"sz="(\d+)""#, in: xml).compactMap { Double($0).map { $0 / 100.0 } }
        let role = xml.contains("<p:ph type=\"title\"") || xml.contains("<p:ph type=\"ctrTitle\"") ? "title" : "body"
        return names.enumerated().map { index, name in
            PresentationFontSample(
                name: name,
                size: sizes.indices.contains(index) ? sizes[index] : (role == "title" ? 40 : 16),
                weight: xml.contains("<a:b/>") ? "bold" : nil,
                role: role
            )
        }
    }

    private static func mergedFonts(_ fonts: [PresentationFontSample]) -> [PresentationFontSample] {
        let grouped = Dictionary(grouping: fonts) { "\($0.name)|\(Int($0.size.rounded()))|\($0.role)" }
        return grouped.values.map { group in
            var first = group[0]
            first.count = group.reduce(0) { $0 + $1.count }
            return first
        }
        .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        .prefix(12)
        .map(\.self)
    }

    private static func hexColors(in xml: String) -> [String] {
        matches(#"srgbClr val="([A-Fa-f0-9]{6})""#, in: xml)
    }

    private static func roleCountsInSlide(_ xml: String) -> [String: Int] {
        var roles: [String: Int] = [:]
        roles["title"] = xml.components(separatedBy: #"type="title""#).count - 1 +
            xml.components(separatedBy: #"type="ctrTitle""#).count - 1
        roles["body"] = max(0, xml.components(separatedBy: "<p:sp>").count - 1 - (roles["title"] ?? 0))
        roles["image"] = xml.components(separatedBy: "<p:pic>").count - 1
        roles["accent"] = xml.components(separatedBy: "<p:cxnSp>").count - 1 +
            xml.components(separatedBy: "<a:ln").count - 1
        return roles.filter { $0.value > 0 }
    }

    private static func layoutPattern(from roles: [String: Int]) -> String {
        if (roles["image"] ?? 0) > 0 && (roles["body"] ?? 0) > 2 { return "image plus dense body grid" }
        if (roles["title"] ?? 0) > 0 && (roles["body"] ?? 0) <= 2 { return "title with concise supporting body" }
        if (roles["body"] ?? 0) > 5 { return "dense content grid" }
        return "balanced title and body"
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range(at: 0), in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        matches(#"\#(name)="([^"]+)""#, in: tag).first
    }

    private static func decodeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

private extension Sequence {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var values: [T] = []
        for element in self {
            if let value = try await transform(element) {
                values.append(value)
            }
        }
        return values
    }
}
