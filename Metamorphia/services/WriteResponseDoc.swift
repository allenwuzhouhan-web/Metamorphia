/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation
import AppKit

enum WriteResponseDocError: Error {
    case rtfEncodingFailed
    case writeFailed(underlying: Error)
    case textutilFailed(status: Int32, stderr: String)
}

/// Write a command-bar response to a Word document on disk and open it in
/// the user's default word processor (Pages, Microsoft Word, or TextEdit).
///
/// Path: markdown -> NSAttributedString -> RTF -> textutil -> .docx.
/// `textutil` ships with macOS and produces a real OOXML file, so users can
/// edit and save without format-conversion prompts.
///
/// The returned URL is the `.docx`; the intermediate `.rtf` is deleted on
/// success.
func writeResponseDoc(
    markdown: String,
    prompt: String
) throws -> URL {
    let directory = try responseDocsDirectory()
    let fileStem = fileStem(prompt: prompt)
    let rtfURL = directory.appendingPathComponent("\(fileStem).rtf")
    let docxURL = directory.appendingPathComponent("\(fileStem).docx")

    let attributed = buildAttributedString(markdown: markdown, prompt: prompt)
    let range = NSRange(location: 0, length: attributed.length)
    guard let rtfData = try? attributed.data(
        from: range,
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    ) else {
        throw WriteResponseDocError.rtfEncodingFailed
    }

    do {
        try rtfData.write(to: rtfURL, options: .atomic)
    } catch {
        throw WriteResponseDocError.writeFailed(underlying: error)
    }

    // Convert RTF to .docx via /usr/bin/textutil. This is the same tool the
    // rest of the app uses to extract text from Office files (see
    // FileContentExtractor) so we know it's on every supported macOS.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
    task.arguments = [
        "-convert", "docx",
        "-output", docxURL.path,
        rtfURL.path
    ]
    let stderrPipe = Pipe()
    task.standardError = stderrPipe
    task.standardOutput = Pipe()
    try task.run()
    task.waitUntilExit()

    if task.terminationStatus != 0 {
        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        throw WriteResponseDocError.textutilFailed(status: task.terminationStatus, stderr: err)
    }

    try? FileManager.default.removeItem(at: rtfURL)
    return docxURL
}

/// `~/Documents/Metamorphia Research/` — created on demand.
private func responseDocsDirectory() throws -> URL {
    let fm = FileManager.default
    let documents = try fm.url(
        for: .documentDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let directory = documents.appendingPathComponent("Metamorphia Research", isDirectory: true)
    if !fm.fileExists(atPath: directory.path) {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return directory
}

/// `research-2026-04-25-1423-effects_of_matcha.docx` — timestamp + slugged
/// prompt so repeated exports in one day don't clobber each other.
private func fileStem(prompt: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    let timestamp = formatter.string(from: Date())

    let stripped = prompt
        .replacingOccurrences(of: "[deep research] ", with: "")
        .replacingOccurrences(of: "[light research] ", with: "")
        .replacingOccurrences(of: "[browser visible] ", with: "")
        .replacingOccurrences(of: "[browser background] ", with: "")
        .lowercased()

    let allowed = CharacterSet.lowercaseLetters
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: " "))
    let cleaned = stripped.unicodeScalars
        .map { allowed.contains($0) ? Character($0) : " " }
        .reduce(into: "") { $0.append($1) }
    let slug = cleaned
        .split(separator: " ", omittingEmptySubsequences: true)
        .prefix(6)
        .joined(separator: "_")

    let suffix = slug.isEmpty ? "response" : slug
    return "research-\(timestamp)-\(suffix)"
}

/// Render markdown into a styled `NSAttributedString` suitable for Word.
/// Lightweight: title + prompt subheader, then markdown-interpreted body.
private func buildAttributedString(markdown: String, prompt: String) -> NSAttributedString {
    let output = NSMutableAttributedString()

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor.black
    ]
    output.append(NSAttributedString(string: "Metamorphia research\n", attributes: titleAttrs))

    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.darkGray
    ]
    let cleanedPrompt = prompt
        .replacingOccurrences(of: "[deep research] ", with: "")
        .replacingOccurrences(of: "[light research] ", with: "")
        .replacingOccurrences(of: "[browser visible] ", with: "")
        .replacingOccurrences(of: "[browser background] ", with: "")
    let dateLine = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
    output.append(NSAttributedString(string: "\(cleanedPrompt)\n", attributes: subAttrs))
    output.append(NSAttributedString(string: "\(dateLine)\n\n", attributes: subAttrs))

    let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.black
    ]

    // `AttributedString(markdown:)` handles bold/italic/code/links inline.
    // We render block structure (paragraphs, headings, lists) by splitting
    // on newlines and re-joining with paragraph breaks — the simple path
    // covers 95% of LLM output without pulling in a markdown engine.
    let body: NSAttributedString = {
        if let attr = try? AttributedString(
            markdown: markdown,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            let ns = NSMutableAttributedString(attributedString: NSAttributedString(attr))
            ns.addAttributes(bodyAttrs, range: NSRange(location: 0, length: ns.length))
            return ns
        }
        return NSAttributedString(string: markdown, attributes: bodyAttrs)
    }()

    output.append(body)
    return output
}
