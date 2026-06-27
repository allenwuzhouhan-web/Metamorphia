import AppKit
import Foundation

struct DocumentReviewRoute {
    let kind: DocumentReviewKind
    let sourceDescription: String
    let filePath: String?
    let commandContextBlock: String
    let systemPromptSuffix: String
    let consumesAttachmentText: Bool
    let autoInsertNativeComments: Bool
    let preferCompactDelivery: Bool
}

private struct ResolvedDocumentContext {
    let title: String
    let kind: DocumentReviewKind
    let sourceDescription: String
    let filePath: String?
    let extractedText: String
    let usesAttachmentText: Bool
}

struct DocumentActionOutcome {
    let success: Bool
    let message: String
}

private struct FrontmostEditableDocument {
    let title: String
    let kind: DocumentReviewKind
    let appName: String
    let fileURL: URL
}

private struct ClipboardSnapshot {
    let items: [NSPasteboardItem]

    @MainActor
    static func capture() -> ClipboardSnapshot {
        ClipboardSnapshot(items: NSPasteboard.general.pasteboardItems ?? [])
    }

    @MainActor
    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items)
    }
}

enum DocumentCopilot {
    private static let wordBundleID = "com.microsoft.Word"
    private static let powerPointBundleID = "com.microsoft.Powerpoint"

    private struct WordAuditComment {
        let commentID: Int
        let anchorText: String
        let commentText: String
        let suggestedRevision: String
    }

    static func prepareReviewRoute(
        prompt: String,
        attachedFiles: [CommandBarAttachedFile]
    ) async -> DocumentReviewPreparation {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notDocumentIntent }
        guard let intent = detectIntent(in: trimmed) else { return .notDocumentIntent }

        guard let context = await resolveContext(for: intent, attachedFiles: attachedFiles) else {
            let noun = intent.requestedKind?.displayName.lowercased() ?? "document"
            return .failure("I couldn't find a saved Word or PowerPoint \(noun) to review. Open the file in Microsoft Word or PowerPoint, or attach a .docx or .pptx file.")
        }

        let toneHint = inferredToneHint(from: trimmed)
        let systemPromptSuffix = """

        ## Document Copilot Review Mode
        You are reviewing an existing \(context.kind.displayName.lowercased()).
        Prioritize clarity, hierarchy, pacing, redundancy, wording, and audience fit.
        Base every finding on the supplied document content. Do not invent slides, sections, or claims that are not supported by the text.
        Start with a short human-readable summary paragraph.
        Then emit exactly one machine-readable block with no code fence:
        [DOC_REVIEW]
        {"documentTitle":"...","documentKind":"\(context.kind.rawValue)","sourceDescription":"\(escapeJSONString(context.sourceDescription))","summary":"...","nextStep":"...","findings":[{"title":"...","location":"...","severity":"high|medium|low","rationale":"...","anchorText":"...","suggestedRevision":"..."}]}
        [/DOC_REVIEW]
        Include 3 to 6 findings. Keep locations specific, like "Slide 2" or "Opening section".
        anchorText must be a short exact phrase copied verbatim from the document near the issue so the app can jump back to the right place later.
        Keep each rationale to one or two direct sentences. Suggested revisions must be short, concrete rewrites, not vague advice.
        Write finding titles as compact labels, not full sentences. Prefer "RMSE direction is backwards" over "RMSE sentence in Section 5 is numerically confusing".
        \(toneHint.map { "Bias the review toward making the document feel \($0)." } ?? "")
        """

        var contextLines: [String] = [
            "Document under review:",
            "- Title: \(context.title)",
            "- Kind: \(context.kind.displayName)",
            "- Source: \(context.sourceDescription)",
            context.filePath.map { "- File path: \($0)" } ?? "- File path: unavailable",
            "- User request: \(trimmed)",
        ]
        if !context.usesAttachmentText {
            contextLines.append("")
            contextLines.append("--- Document text: \(context.title) ---")
            contextLines.append(context.extractedText)
            contextLines.append("--- End document text ---")
        }
        let contextBlock = contextLines.joined(separator: "\n")

        return .route(DocumentReviewRoute(
            kind: context.kind,
            sourceDescription: context.sourceDescription,
            filePath: context.filePath,
            commandContextBlock: contextBlock,
            systemPromptSuffix: systemPromptSuffix,
            consumesAttachmentText: context.usesAttachmentText,
            autoInsertNativeComments: context.kind == .document && !context.usesAttachmentText,
            preferCompactDelivery: context.kind == .document && !context.usesAttachmentText
        ))
    }

    private static func detectIntent(in prompt: String) -> DetectedIntent? {
        let normalized = prompt.lowercased()
        let reviewVerbs = [
            "audit", "review", "comment", "critique", "revise", "rewrite",
            "finish", "improve", "polish", "tighten",
        ]
        let hasReviewVerb = reviewVerbs.contains { normalized.contains($0) }
        let requestedKind = requestedKind(in: normalized)
        let mentionsDemonstrative = normalized.contains("this") || normalized.contains("current") || normalized.contains("open")

        guard hasReviewVerb else { return nil }
        guard requestedKind != nil || mentionsDemonstrative else { return nil }
        return DetectedIntent(requestedKind: requestedKind)
    }

    static func isApplyAuditRequest(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let auditTerms = ["audit", "audits", "comment", "comments", "review finding", "review findings"]
        let applyTerms = [
            "apply", "make changes", "make the changes", "implement",
            "fix", "revise according", "according to", "address"
        ]
        guard auditTerms.contains(where: { normalized.contains($0) }) else { return false }
        return applyTerms.contains { normalized.contains($0) }
    }

    private static func requestedKind(in prompt: String) -> DocumentReviewKind? {
        let presentationTerms = ["presentation", "deck", "slides", "slide deck", "powerpoint", "ppt"]
        if presentationTerms.contains(where: { prompt.contains($0) }) {
            return .presentation
        }
        let documentTerms = ["document", "word", "memo", "report", "proposal", "brief", "essay"]
        if documentTerms.contains(where: { prompt.contains($0) }) {
            return .document
        }
        return nil
    }

    private static func inferredToneHint(from prompt: String) -> String? {
        let normalized = prompt.lowercased()
        let map: [(String, String)] = [
            ("executive", "executive-ready and concise"),
            ("board", "board-ready and strategic"),
            ("investor", "investor-ready and persuasive"),
            ("sales", "sales-oriented and punchy"),
            ("academic", "academic and precise"),
            ("concise", "tighter and more concise"),
            ("professional", "professional and polished"),
        ]
        return map.first(where: { normalized.contains($0.0) })?.1
    }

    private static func resolveContext(
        for intent: DetectedIntent,
        attachedFiles: [CommandBarAttachedFile]
    ) async -> ResolvedDocumentContext? {
        if let frontmost = await resolveFrontmostContext(requestedKind: intent.requestedKind) {
            return frontmost
        }
        return resolveAttachedContext(requestedKind: intent.requestedKind, attachedFiles: attachedFiles)
    }

    private static func resolveFrontmostContext(requestedKind: DocumentReviewKind?) async -> ResolvedDocumentContext? {
        guard let candidate = await resolveDocumentAppCandidate(requestedKind: requestedKind) else {
            return nil
        }

        let bundleID = candidate.bundleID
        let resolvedKind = candidate.kind
        if let requestedKind, requestedKind != resolvedKind { return nil }

        // NSAppleScript is not thread-safe — run the descriptor probe on the main actor.
        let descriptor = await MainActor.run { frontmostDocumentDescriptor(bundleID: bundleID) }

        if let descriptor,
           let path = descriptor.path,
           let url = sanitizedFileURL(path: path),
           let extracted = await FileContentExtractor.shared.extract(from: url) {
            return ResolvedDocumentContext(
                title: descriptor.title.isEmpty ? extracted.name : descriptor.title,
                kind: resolvedKind,
                sourceDescription: candidate.sourceDescription,
                filePath: url.path,
                extractedText: extracted.extractedText,
                usesAttachmentText: false
            )
        }

        if resolvedKind == .presentation,
           let snapshot = await PowerPointCopilot.captureDeckReviewSnapshot() {
            let sourceDescription = snapshot.filePath == nil
                ? "Open \(candidate.appName) deck"
                : candidate.sourceDescription
            return ResolvedDocumentContext(
                title: snapshot.presentationTitle,
                kind: .presentation,
                sourceDescription: sourceDescription,
                filePath: snapshot.filePath,
                extractedText: snapshot.extractedText,
                usesAttachmentText: false
            )
        }

        return nil
    }

    private static func resolveAttachedContext(
        requestedKind: DocumentReviewKind?,
        attachedFiles: [CommandBarAttachedFile]
    ) -> ResolvedDocumentContext? {
        let candidates = attachedFiles.filter { kind(for: $0.ext) != nil }
        guard !candidates.isEmpty else { return nil }

        let file: CommandBarAttachedFile?
        if let requestedKind {
            file = candidates.first(where: { kind(for: $0.ext) == requestedKind })
        } else {
            file = candidates.first
        }
        guard let selected = file, let kind = kind(for: selected.ext) else { return nil }

        return ResolvedDocumentContext(
            title: selected.name,
            kind: kind,
            sourceDescription: "Attached \(kind.displayName.lowercased())",
            filePath: selected.url.path,
            extractedText: selected.extractedText,
            usesAttachmentText: true
        )
    }

    private static func kind(for ext: String) -> DocumentReviewKind? {
        switch ext.lowercased() {
        case "pptx", "ppt":
            return .presentation
        case "docx", "doc":
            return .document
        default:
            return nil
        }
    }

    private static func sanitizedFileURL(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private static func frontmostDocumentDescriptor(bundleID: String) -> (title: String, path: String?)? {
        let payload: String?
        switch bundleID {
        case powerPointBundleID:
            payload = LocalCommandHelpers.runAppleScript(powerPointScript)
        case wordBundleID:
            payload = LocalCommandHelpers.runAppleScript(wordScript)
        default:
            payload = nil
        }
        guard let payload else { return nil }
        let lines = payload.components(separatedBy: "\n")
        let title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return (title, path.isEmpty ? nil : path)
    }

    private static func resolveDocumentAppCandidate(
        requestedKind: DocumentReviewKind?
    ) async -> (bundleID: String, kind: DocumentReviewKind, appName: String, sourceDescription: String)? {
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier,
           let kind = kind(forBundleID: bundleID),
           requestedKind == nil || requestedKind == kind {
            return (
                bundleID: bundleID,
                kind: kind,
                appName: app.localizedName ?? displayAppName(for: kind),
                sourceDescription: "Frontmost \(app.localizedName ?? displayAppName(for: kind)) file"
            )
        }

        let stream = await MainActor.run { MetamorphiaBootstrap.activityStream }
        guard let stream else { return nil }
        let recent = await stream.recent(since: Date().addingTimeInterval(-180))
        let selfBundleID = Bundle.main.bundleIdentifier

        for event in recent.reversed() {
            guard case let .focusChanged(bundleID, appName, _, _, _) = event else { continue }
            guard bundleID != selfBundleID else { continue }
            guard let kind = kind(forBundleID: bundleID) else { continue }
            guard requestedKind == nil || requestedKind == kind else { continue }
            return (
                bundleID: bundleID,
                kind: kind,
                appName: appName.isEmpty ? displayAppName(for: kind) : appName,
                sourceDescription: "Previously focused \(appName.isEmpty ? displayAppName(for: kind) : appName) file"
            )
        }

        if let requestedKind,
           let bundleID = bundleID(for: requestedKind),
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            // NSAppleScript is not thread-safe — run the descriptor probe on the main actor.
            let descriptor = await MainActor.run { frontmostDocumentDescriptor(bundleID: bundleID) }
            if descriptor != nil {
                return (
                    bundleID: bundleID,
                    kind: requestedKind,
                    appName: displayAppName(for: requestedKind),
                    sourceDescription: "Open \(displayAppName(for: requestedKind)) file"
                )
            }
        }

        return nil
    }

    private static func bundleID(for kind: DocumentReviewKind) -> String? {
        switch kind {
        case .presentation:
            return powerPointBundleID
        case .document:
            return wordBundleID
        }
    }

    private static func kind(forBundleID bundleID: String) -> DocumentReviewKind? {
        switch bundleID {
        case powerPointBundleID:
            return .presentation
        case wordBundleID:
            return .document
        default:
            return nil
        }
    }

    private static func displayAppName(for kind: DocumentReviewKind) -> String {
        kind == .presentation ? "Microsoft PowerPoint" : "Microsoft Word"
    }

    private static let powerPointScript = """
    tell application "Microsoft PowerPoint"
        if (count of presentations) is 0 then return ""
        set presRef to active presentation
        set presName to name of presRef
        set presPath to ""
        try
            set presPath to POSIX path of (full name of presRef as alias)
        end try
        return presName & linefeed & presPath
    end tell
    """

    private static let wordScript = """
    tell application "Microsoft Word"
        if not (exists active document) then return ""
        set docRef to active document
        set docName to name of docRef
        set docPath to ""
        try
            set docPath to POSIX path of (full name of docRef as alias)
        end try
        return docName & linefeed & docPath
    end tell
    """

    private static func escapeJSONString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func performAction(
        _ action: DocumentReviewAction,
        review: DocumentReviewResult
    ) async -> DocumentActionOutcome {
        guard let finding = review.findings.first(where: { $0.id == action.findingID }) else {
            return DocumentActionOutcome(
                success: false,
                message: "That review finding is no longer available."
            )
        }

        guard let document = await resolveEditableDocument(matching: review) else {
            return DocumentActionOutcome(
                success: false,
                message: "Open the reviewed \(review.documentKind.displayName.lowercased()) in Microsoft \(review.documentKind == .presentation ? "PowerPoint" : "Word") and bring it to the front before using review actions."
            )
        }

        switch action {
        case .jump:
            return await jumpToFinding(finding, in: document)
        case .insertComment:
            return await insertComment(for: finding, in: document)
        case .applySuggestedRevision:
            return await applySuggestedRevision(for: finding, in: document)
        }
    }

    static func applyCurrentWordAuditComments() async -> DocumentActionOutcome {
        guard let document = await resolveCurrentEditableDocument(requestedKind: .document) else {
            return DocumentActionOutcome(
                success: false,
                message: "Open the audited Word document and bring it to the front before asking Metamorphia to apply the audit."
            )
        }

        let audits: [WordAuditComment]
        do {
            audits = try readMetamorphiaWordAudits(from: document.fileURL)
        } catch {
            return DocumentActionOutcome(
                success: false,
                message: "I couldn't read the Word audit comments in \(document.title): \(error.localizedDescription)"
            )
        }

        guard !audits.isEmpty else {
            return DocumentActionOutcome(
                success: false,
                message: "I couldn't find Metamorphia audit comments with suggested rewrites in \(document.title). Run Audit first, or add rewrites to the comments."
            )
        }

        do {
            let backupURL = try createBackup(for: document.fileURL)
            try await enableWordTrackedChanges(appName: document.appName)

            var appliedCount = 0
            var failedCount = 0
            for audit in audits {
                do {
                    try await runFind(anchor: audit.anchorText, appName: document.appName)
                    try await replaceCurrentSelection(with: audit.suggestedRevision, appName: document.appName)
                    appliedCount += 1
                } catch {
                    failedCount += 1
                }
            }

            await revealReviewSurfaceIfPossible(for: document)

            guard appliedCount > 0 else {
                return DocumentActionOutcome(
                    success: false,
                    message: "I read \(audits.count) audit comment(s), but none of their anchors could be found in \(document.title)."
                )
            }

            let skipped = failedCount == 0 ? "" : " \(failedCount) audit edit(s) need manual review."
            return DocumentActionOutcome(
                success: true,
                message: "Applied \(appliedCount) audit rewrite(s) in Word Review Mode for \(document.title). Backup: \(backupURL.lastPathComponent).\(skipped)"
            )
        } catch {
            return DocumentActionOutcome(
                success: false,
                message: "I couldn't apply the audit in Review Mode for \(document.title): \(error.localizedDescription)"
            )
        }
    }

    static func insertReviewComments(_ review: DocumentReviewResult) async -> DocumentActionOutcome {
        guard review.documentKind == .document else {
            return DocumentActionOutcome(
                success: false,
                message: "Automatic native comment sync is currently limited to Word documents."
            )
        }

        guard let document = await resolveEditableDocument(matching: review) else {
            return DocumentActionOutcome(
                success: false,
                message: "I couldn't reconnect to the reviewed Word document. Keep the same document open in Microsoft Word and try the audit again."
            )
        }

        let actionableFindings = review.findings.filter { $0.trimmedAnchorText != nil }
        guard !actionableFindings.isEmpty else {
            return DocumentActionOutcome(
                success: false,
                message: "The audit didn't include exact anchor phrases, so I couldn't place native Word comments. Re-run the audit to regenerate action-ready findings."
            )
        }

        do {
            let backupURL = try createBackup(for: document.fileURL)
            let nativeResult = try writeNativeWordComments(
                findings: actionableFindings,
                to: document.fileURL
            )
            let insertedCount = nativeResult.insertedCount
            let skippedLocations = nativeResult.skippedLocations

            await reloadWordDocumentIfPossible(at: document.fileURL)
            await revealReviewSurfaceIfPossible(for: document)

            guard insertedCount > 0 else {
                return DocumentActionOutcome(
                    success: false,
                    message: "I reviewed \(document.title), but I couldn't place any Word comments reliably."
                )
            }

            let skippedNote: String
            if skippedLocations.isEmpty {
                skippedNote = ""
            } else {
                skippedNote = " \(skippedLocations.count) finding(s) still need manual review."
            }

            return DocumentActionOutcome(
                success: true,
                message: "Inserted \(insertedCount) review comment(s) into \(document.title). Backup: \(backupURL.lastPathComponent).\(skippedNote)"
            )
        } catch {
            return DocumentActionOutcome(
                success: false,
                message: "I reviewed \(document.title), but comment sync failed: \(error.localizedDescription)"
            )
        }
    }

    private static func resolveEditableDocument(
        matching review: DocumentReviewResult
    ) async -> FrontmostEditableDocument? {
        let requestedKind = review.documentKind
        guard let document = await resolveCurrentEditableDocument(requestedKind: requestedKind) else {
            return nil
        }

        if let expectedPath = review.sourceFilePath,
           !expectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expectedURL = URL(fileURLWithPath: expectedPath)
            guard document.fileURL.standardizedFileURL == expectedURL.standardizedFileURL else {
                return nil
            }
        } else {
            let actualTitle = normalizedDocumentTitle(document.title)
            let expectedTitle = normalizedDocumentTitle(review.documentTitle)
            let fileTitle = normalizedDocumentTitle(document.fileURL.deletingPathExtension().lastPathComponent)
            guard actualTitle == expectedTitle || fileTitle == expectedTitle else {
                return nil
            }
        }

        return document
    }

    private static func resolveCurrentEditableDocument(
        requestedKind: DocumentReviewKind?
    ) async -> FrontmostEditableDocument? {
        guard let candidate = await resolveDocumentAppCandidate(requestedKind: requestedKind) else {
            return nil
        }

        let bundleID = candidate.bundleID
        let kind = candidate.kind

        // NSAppleScript is not thread-safe — run the descriptor probe on the main actor.
        let descriptor = await MainActor.run { frontmostDocumentDescriptor(bundleID: bundleID) }
        guard let descriptor,
              let path = descriptor.path,
              let fileURL = sanitizedFileURL(path: path) else {
            return nil
        }

        return FrontmostEditableDocument(
            title: descriptor.title,
            kind: kind,
            appName: candidate.appName,
            fileURL: fileURL
        )
    }

    private static func jumpToFinding(
        _ finding: DocumentReviewFinding,
        in document: FrontmostEditableDocument
    ) async -> DocumentActionOutcome {
        guard let anchor = finding.trimmedAnchorText else {
            return DocumentActionOutcome(
                success: false,
                message: "This finding does not include an exact anchor phrase yet, so I can’t jump to it reliably. Re-run the review to generate action-ready anchors."
            )
        }

        do {
            try await runFind(anchor: anchor, appName: document.appName)
            return DocumentActionOutcome(
                success: true,
                message: "Jumped to “\(finding.title)” in \(document.title)."
            )
        } catch {
            return DocumentActionOutcome(
                success: false,
                message: "I couldn’t jump to that finding in \(document.title): \(error.localizedDescription)"
            )
        }
    }

    private static func insertComment(
        for finding: DocumentReviewFinding,
        in document: FrontmostEditableDocument
    ) async -> DocumentActionOutcome {
        guard let anchor = finding.trimmedAnchorText else {
            return DocumentActionOutcome(
                success: false,
                message: "This finding does not include an exact anchor phrase yet, so I can’t place a native comment reliably. Re-run the review to generate action-ready anchors."
            )
        }

        let commentText = buildCommentText(for: finding)
        do {
            let backupURL = try createBackup(for: document.fileURL)
            if document.kind == .document {
                let nativeResult = try writeNativeWordComments(
                    findings: [finding],
                    to: document.fileURL,
                    overrideCommentText: [finding.id: commentText]
                )
                guard nativeResult.insertedCount > 0 else {
                    return DocumentActionOutcome(
                        success: false,
                        message: "I couldn’t insert that comment in \(document.title): the anchor phrase did not map cleanly into the Word document XML."
                    )
                }
                await reloadWordDocumentIfPossible(at: document.fileURL)
                await revealReviewSurfaceIfPossible(for: document)
            } else {
                await revealReviewSurfaceIfPossible(for: document)
                try await runFind(anchor: anchor, appName: document.appName)
                try await pasteText(commentText, intoCommentFor: document.appName)
            }
            return DocumentActionOutcome(
                success: true,
                message: "Inserted a comment for “\(finding.title)” in \(document.title). Backup: \(backupURL.lastPathComponent)"
            )
        } catch {
            return DocumentActionOutcome(
                success: false,
                message: "I couldn’t insert that comment in \(document.title): \(error.localizedDescription)"
            )
        }
    }

    private static func applySuggestedRevision(
        for finding: DocumentReviewFinding,
        in document: FrontmostEditableDocument
    ) async -> DocumentActionOutcome {
        guard document.kind == .document else {
            return DocumentActionOutcome(
                success: false,
                message: "Direct rewrite apply is currently limited to Word documents. PowerPoint stays in review/comment mode for now."
            )
        }
        guard let anchor = finding.trimmedAnchorText else {
            return DocumentActionOutcome(
                success: false,
                message: "This finding does not include an exact anchor phrase yet, so I can’t replace the right text safely. Re-run the review to generate action-ready anchors."
            )
        }
        guard let revision = finding.trimmedSuggestedRevision else {
            return DocumentActionOutcome(
                success: false,
                message: "This finding does not include a concrete rewrite to apply."
            )
        }

        do {
            let backupURL = try createBackup(for: document.fileURL)
            try await enableWordTrackedChanges(appName: document.appName)
            try await runFind(anchor: anchor, appName: document.appName)
            try await replaceCurrentSelection(with: revision, appName: document.appName)
            await revealReviewSurfaceIfPossible(for: document)
            return DocumentActionOutcome(
                success: true,
                message: "Applied the suggested rewrite for “\(finding.title)” in Word Review Mode. Backup: \(backupURL.lastPathComponent)"
            )
        } catch {
            return DocumentActionOutcome(
                success: false,
                message: "I couldn’t apply that rewrite in \(document.title): \(error.localizedDescription)"
            )
        }
    }

    private static func buildCommentText(for finding: DocumentReviewFinding) -> String {
        var parts = [
            "\(finding.severity.displayName.uppercased()) · \(finding.location)",
            compactLine(finding.title, maxCharacters: 84),
            "",
            "Issue: \(compactLine(finding.rationale, maxCharacters: 220))",
        ]
        if let revision = finding.trimmedSuggestedRevision {
            parts.append("")
            parts.append("Rewrite: \(cleanSuggestedRevision(revision))")
        }
        return parts.joined(separator: "\n")
    }

    private static func compactLine(_ string: String, maxCharacters: Int) -> String {
        let singleLine = collapseWhitespace(string)
        guard singleLine.count > maxCharacters else { return singleLine }
        let index = singleLine.index(singleLine.startIndex, offsetBy: maxCharacters)
        let prefix = singleLine[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }

    private static func createBackup(for fileURL: URL) throws -> URL {
        let timestamp = backupTimestampFormatter.string(from: Date())
        let ext = fileURL.pathExtension
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let backupName: String
        if ext.isEmpty {
            backupName = "\(stem)-metamorphia-backup-\(timestamp)"
        } else {
            backupName = "\(stem)-metamorphia-backup-\(timestamp).\(ext)"
        }
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
        return backupURL
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func runFind(anchor: String, appName: String) async throws {
        let singleLineAnchor = normalizedAnchor(anchor)
        guard !singleLineAnchor.isEmpty else {
            throw NSError(
                domain: "DocumentCopilot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The anchor phrase was empty after normalization."]
            )
        }

        let escapedAnchor = LocalCommandHelpers.escapeAppleScript(singleLineAnchor)
        let script = """
        tell application "\(appName)"
            activate
        end tell
        delay 0.2
        tell application "System Events"
            tell process "\(appName)"
                keystroke "f" using command down
                delay 0.25
                keystroke "a" using command down
                keystroke "\(escapedAnchor)"
                delay 0.15
                key code 36
                delay 0.2
                key code 53
            end tell
        end tell
        """
        try await AppleScriptHelper.executeVoid(script)
    }

    private static func pasteText(_ text: String, intoCommentFor appName: String) async throws {
        let snapshot = await MainActor.run { ClipboardSnapshot.capture() }
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        defer {
            Task { @MainActor in
                snapshot.restore()
            }
        }

        let script = """
        tell application "\(appName)"
            activate
        end tell
        delay 0.2
        tell application "System Events"
            tell process "\(appName)"
                try
                    click menu item "New Comment" of menu 1 of menu bar item "Review" of menu bar 1
                on error
                    keystroke "m" using {command down, option down}
                end try
                delay 0.35
                keystroke "v" using command down
                delay 0.15
                key code 53
            end tell
        end tell
        """
        try await AppleScriptHelper.executeVoid(script)
    }

    private static func insertWordCommentText(_ text: String, appName: String) async throws {
        let escapedText = LocalCommandHelpers.escapeAppleScript(text)
        let nativeScript = """
        tell application "Microsoft Word"
            activate
            set newComment to make new Word comment at selection
            set content of comment_text of newComment to "\(escapedText)"
        end tell
        """

        do {
            try await AppleScriptHelper.executeVoid(nativeScript)
        } catch {
            try await pasteText(text, intoCommentFor: appName)
        }
    }

    private static func revealReviewSurfaceIfPossible(
        for document: FrontmostEditableDocument
    ) async {
        guard document.kind == .document else { return }
        let activateScript = """
        tell application "Microsoft Word"
            activate
        end tell
        """
        _ = try? await AppleScriptHelper.executeVoid(activateScript)

        let reviewTabScript = """
        tell application "System Events"
            tell process "Microsoft Word"
                try
                    click radio button "Review" of toolbar 1 of window 1
                on error
                    try
                        click button "Review" of toolbar 1 of window 1
                    end try
                end try
            end tell
        end tell
        """
        _ = try? await AppleScriptHelper.executeVoid(reviewTabScript)
    }

    private static func replaceCurrentSelection(with text: String, appName: String) async throws {
        let snapshot = await MainActor.run { ClipboardSnapshot.capture() }
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        defer {
            Task { @MainActor in
                snapshot.restore()
            }
        }

        let script = """
        tell application "\(appName)"
            activate
        end tell
        delay 0.15
        tell application "System Events"
            tell process "\(appName)"
                keystroke "v" using command down
            end tell
        end tell
        """
        try await AppleScriptHelper.executeVoid(script)
    }

    private static func enableWordTrackedChanges(appName: String) async throws {
        let script = """
        tell application "Microsoft Word"
            activate
            if exists active document then
                set track revisions of active document to true
            end if
        end tell
        delay 0.15
        tell application "System Events"
            tell process "\(appName)"
                try
                    click radio button "Review" of toolbar 1 of window 1
                on error
                    try
                        click button "Review" of toolbar 1 of window 1
                    end try
                end try
            end tell
        end tell
        """
        try await AppleScriptHelper.executeVoid(script)
    }

    private static func normalizedAnchor(_ anchor: String) -> String {
        anchor
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDocumentTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".pptx", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".ppt", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".docx", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".doc", with: "", options: .caseInsensitive)
            .lowercased()
    }

    private struct NativeWordCommentWriteResult {
        let insertedCount: Int
        let skippedLocations: [String]
    }

    private static func writeNativeWordComments(
        findings: [DocumentReviewFinding],
        to fileURL: URL,
        overrideCommentText: [UUID: String] = [:]
    ) throws -> NativeWordCommentWriteResult {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metamorphia-docx-\(UUID().uuidString)", isDirectory: true)
        let extracted = root.appendingPathComponent("doc", isDirectory: true)
        let rebuilt = root.appendingPathComponent("rebuilt.docx")

        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-qq", fileURL.path, "-d", extracted.path],
            currentDirectory: root
        )

        let documentURL = extracted.appendingPathComponent("word/document.xml")
        let relsURL = extracted.appendingPathComponent("word/_rels/document.xml.rels")
        let contentTypesURL = extracted.appendingPathComponent("[Content_Types].xml")
        let commentsURL = extracted.appendingPathComponent("word/comments.xml")

        let documentXML = try XMLDocument(contentsOf: documentURL, options: [])
        let commentsXML = try loadOrCreateCommentsDocument(at: commentsURL)
        let relsXML = try XMLDocument(contentsOf: relsURL, options: [])
        let contentTypesXML = try XMLDocument(contentsOf: contentTypesURL, options: [])

        var nextCommentID = nextWordCommentID(in: commentsXML)
        var insertedCount = 0
        var skippedLocations: [String] = []

        for finding in findings {
            guard let anchor = finding.trimmedAnchorText else {
                skippedLocations.append(finding.location)
                continue
            }

            let commentText = overrideCommentText[finding.id] ?? buildCommentText(for: finding)
            let didInsert = try insertWordComment(
                anchor: anchor,
                commentText: commentText,
                commentID: nextCommentID,
                into: documentXML,
                commentsXML: commentsXML
            )

            if didInsert {
                insertedCount += 1
                nextCommentID += 1
            } else {
                skippedLocations.append(finding.location)
            }
        }

        guard insertedCount > 0 else {
            return NativeWordCommentWriteResult(
                insertedCount: 0,
                skippedLocations: skippedLocations
            )
        }

        ensureCommentsRelationship(in: relsXML)
        ensureCommentsContentType(in: contentTypesXML)

        try saveXML(documentXML, to: documentURL)
        try saveXML(commentsXML, to: commentsURL)
        try saveXML(relsXML, to: relsURL)
        try saveXML(contentTypesXML, to: contentTypesURL)

        try runProcess(
            executable: "/usr/bin/zip",
            arguments: ["-X", "-q", "-r", rebuilt.path, "."],
            currentDirectory: extracted
        )

        try fm.removeItem(at: fileURL)
        try fm.moveItem(at: rebuilt, to: fileURL)

        return NativeWordCommentWriteResult(
            insertedCount: insertedCount,
            skippedLocations: skippedLocations
        )
    }

    private static func insertWordComment(
        anchor: String,
        commentText: String,
        commentID: Int,
        into documentXML: XMLDocument,
        commentsXML: XMLDocument
    ) throws -> Bool {
        guard let match = findWordAnchor(anchor, in: documentXML),
              let selectedRun = try splitRunForAnchor(match) else {
            return false
        }

        try insertCommentMarkers(commentID: commentID, around: selectedRun)
        appendCommentEntry(commentID: commentID, text: commentText, to: commentsXML)
        return true
    }

    private struct WordAnchorMatch {
        let textElement: XMLElement
        let runElement: XMLElement
        let startOffset: Int
        let endOffset: Int
    }

    private static func findWordAnchor(_ anchor: String, in documentXML: XMLDocument) -> WordAnchorMatch? {
        let allTextNodes = ((try? documentXML.nodes(forXPath: "//*[local-name()='t']")) as? [XMLElement]) ?? []
        for textElement in allTextNodes {
            guard let runElement = nearestRunAncestor(for: textElement),
                  textElements(in: runElement).count == 1,
                  let text = textElement.stringValue,
                  !text.isEmpty else { continue }

            if let range = exactRange(of: anchor, in: text) {
                return WordAnchorMatch(
                    textElement: textElement,
                    runElement: runElement,
                    startOffset: range.lowerBound,
                    endOffset: range.upperBound
                )
            }

            if let range = normalizedRange(of: anchor, in: text) {
                return WordAnchorMatch(
                    textElement: textElement,
                    runElement: runElement,
                    startOffset: range.lowerBound,
                    endOffset: range.upperBound
                )
            }
        }

        return nil
    }

    private static func exactRange(of needle: String, in haystack: String) -> Range<Int>? {
        guard let range = haystack.range(of: needle) else { return nil }
        let lower = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
        let upper = haystack.distance(from: haystack.startIndex, to: range.upperBound)
        return lower..<upper
    }

    private static func normalizedRange(of needle: String, in haystack: String) -> Range<Int>? {
        let normalizedNeedle = collapseWhitespace(needle)
        guard !normalizedNeedle.isEmpty else { return nil }

        let chars = Array(haystack)
        var normalizedChars: [Character] = []
        var originalIndices: [Int] = []
        var previousWasWhitespace = false

        for (idx, char) in chars.enumerated() {
            if char.isWhitespace {
                if previousWasWhitespace { continue }
                normalizedChars.append(" ")
                originalIndices.append(idx)
                previousWasWhitespace = true
            } else {
                normalizedChars.append(char)
                originalIndices.append(idx)
                previousWasWhitespace = false
            }
        }

        let normalizedHaystack = String(normalizedChars)
        guard let range = normalizedHaystack.range(of: normalizedNeedle) else { return nil }
        let lower = normalizedHaystack.distance(from: normalizedHaystack.startIndex, to: range.lowerBound)
        let upper = normalizedHaystack.distance(from: normalizedHaystack.startIndex, to: range.upperBound)
        guard lower < originalIndices.count, upper > 0, upper - 1 < originalIndices.count else { return nil }

        let start = originalIndices[lower]
        let end = originalIndices[upper - 1] + 1
        return start..<end
    }

    private static func collapseWhitespace(_ string: String) -> String {
        string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func cleanSuggestedRevision(_ revision: String) -> String {
        var cleaned = collapseWhitespace(revision)
        let prefixes = ["Reword to:", "Rewrite to:", "Suggested rewrite:"]
        for prefix in prefixes {
            if cleaned.lowercased().hasPrefix(prefix.lowercased()) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if cleaned.count >= 2,
           let first = cleaned.first,
           let last = cleaned.last,
           (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        return cleaned
    }

    private static func splitRunForAnchor(_ match: WordAnchorMatch) throws -> XMLElement? {
        guard let parent = match.runElement.parent as? XMLElement,
              let index = parent.children?.firstIndex(where: { $0 === match.runElement }),
              let text = match.textElement.stringValue else {
            return nil
        }

        let chars = Array(text)
        guard match.startOffset >= 0,
              match.endOffset <= chars.count,
              match.startOffset < match.endOffset else {
            return nil
        }

        let prefix = String(chars[..<match.startOffset])
        let middle = String(chars[match.startOffset..<match.endOffset])
        let suffix = String(chars[match.endOffset...])

        let replacementRuns = [
            prefix.isEmpty ? nil : clonedRun(from: match.runElement, text: prefix),
            clonedRun(from: match.runElement, text: middle),
            suffix.isEmpty ? nil : clonedRun(from: match.runElement, text: suffix),
        ].compactMap { $0 }

        guard !replacementRuns.isEmpty else { return nil }

        parent.removeChild(at: index)
        for (offset, run) in replacementRuns.enumerated() {
            parent.insertChild(run, at: index + offset)
        }

        if prefix.isEmpty {
            return replacementRuns.first
        }
        return replacementRuns.dropFirst().first
    }

    private static func clonedRun(from run: XMLElement, text: String) -> XMLElement? {
        guard let clone = run.copy() as? XMLElement else { return nil }
        let texts = textElements(in: clone)
        guard texts.count == 1, let textElement = texts.first else { return nil }
        textElement.stringValue = text
        return clone
    }

    private static func insertCommentMarkers(commentID: Int, around selectedRun: XMLElement) throws {
        guard let parent = selectedRun.parent as? XMLElement,
              let index = parent.children?.firstIndex(where: { $0 === selectedRun }) else {
            throw NSError(
                domain: "DocumentCopilot",
                code: 91,
                userInfo: [NSLocalizedDescriptionKey: "Could not place comment markers in the Word XML."]
            )
        }

        let start = XMLElement(name: "w:commentRangeStart")
        start.addAttribute(XMLNode.attribute(withName: "w:id", stringValue: "\(commentID)") as! XMLNode)

        let end = XMLElement(name: "w:commentRangeEnd")
        end.addAttribute(XMLNode.attribute(withName: "w:id", stringValue: "\(commentID)") as! XMLNode)

        let referenceRun = XMLElement(name: "w:r")
        let rPr = XMLElement(name: "w:rPr")
        let rStyle = XMLElement(name: "w:rStyle")
        rStyle.addAttribute(XMLNode.attribute(withName: "w:val", stringValue: "CommentReference") as! XMLNode)
        rPr.addChild(rStyle)
        let reference = XMLElement(name: "w:commentReference")
        reference.addAttribute(XMLNode.attribute(withName: "w:id", stringValue: "\(commentID)") as! XMLNode)
        referenceRun.addChild(rPr)
        referenceRun.addChild(reference)

        parent.insertChild(start, at: index)
        parent.insertChild(end, at: index + 2)
        parent.insertChild(referenceRun, at: index + 3)
    }

    private static func appendCommentEntry(commentID: Int, text: String, to commentsXML: XMLDocument) {
        let root = commentsXML.rootElement() ?? XMLElement(name: "w:comments")
        if commentsXML.rootElement() == nil {
            commentsXML.setRootElement(root)
        }

        let comment = XMLElement(name: "w:comment")
        comment.addAttribute(XMLNode.attribute(withName: "w:id", stringValue: "\(commentID)") as! XMLNode)
        comment.addAttribute(XMLNode.attribute(withName: "w:author", stringValue: "Metamorphia") as! XMLNode)
        comment.addAttribute(XMLNode.attribute(withName: "w:initials", stringValue: "M") as! XMLNode)
        comment.addAttribute(XMLNode.attribute(
            withName: "w:date",
            stringValue: ISO8601DateFormatter().string(from: Date())
        ) as! XMLNode)

        let rawLines = text.components(separatedBy: .newlines)
        let lines = trimmingEmptyEdges(rawLines)
        for line in lines {
            let paragraph = XMLElement(name: "w:p")
            let run = XMLElement(name: "w:r")
            let textNode = XMLElement(name: "w:t", stringValue: line)
            if line.first == " " || line.last == " " {
                textNode.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
            }
            run.addChild(textNode)
            paragraph.addChild(run)
            comment.addChild(paragraph)
        }

        root.addChild(comment)
    }

    private static func trimmingEmptyEdges(_ lines: [String]) -> [String] {
        var result = lines
        while result.first?.isEmpty == true {
            result.removeFirst()
        }
        while result.last?.isEmpty == true {
            result.removeLast()
        }
        return result.isEmpty ? [""] : result
    }

    private static func loadOrCreateCommentsDocument(at url: URL) throws -> XMLDocument {
        if FileManager.default.fileExists(atPath: url.path) {
            return try XMLDocument(contentsOf: url, options: [])
        }

        let root = XMLElement(name: "w:comments")
        root.addNamespace(XMLNode.namespace(withName: "w", stringValue: "http://schemas.openxmlformats.org/wordprocessingml/2006/main") as! XMLNode)
        let doc = XMLDocument(rootElement: root)
        doc.version = "1.0"
        doc.characterEncoding = "UTF-8"
        return doc
    }

    private static func nextWordCommentID(in commentsXML: XMLDocument) -> Int {
        let comments = ((try? commentsXML.nodes(forXPath: "//*[local-name()='comment']")) as? [XMLElement]) ?? []
        let ids = comments.compactMap { element -> Int? in
            element.attribute(forName: "w:id")?.stringValue.flatMap(Int.init)
                ?? element.attribute(forName: "id")?.stringValue.flatMap(Int.init)
        }
        return (ids.max() ?? -1) + 1
    }

    private static func ensureCommentsRelationship(in relsXML: XMLDocument) {
        let relationships = ((try? relsXML.nodes(forXPath: "//*[local-name()='Relationship']")) as? [XMLElement]) ?? []
        let commentsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
        if relationships.contains(where: { $0.attribute(forName: "Type")?.stringValue == commentsType }) {
            return
        }

        let existingIDs = relationships.compactMap { relationship -> Int? in
            guard let id = relationship.attribute(forName: "Id")?.stringValue,
                  id.hasPrefix("rId") else { return nil }
            return Int(id.dropFirst(3))
        }
        let nextID = (existingIDs.max() ?? 0) + 1

        let relationship = XMLElement(name: "Relationship")
        relationship.addAttribute(XMLNode.attribute(withName: "Id", stringValue: "rId\(nextID)") as! XMLNode)
        relationship.addAttribute(XMLNode.attribute(withName: "Type", stringValue: commentsType) as! XMLNode)
        relationship.addAttribute(XMLNode.attribute(withName: "Target", stringValue: "comments.xml") as! XMLNode)
        relsXML.rootElement()?.addChild(relationship)
    }

    private static func ensureCommentsContentType(in contentTypesXML: XMLDocument) {
        let overrides = ((try? contentTypesXML.nodes(forXPath: "//*[local-name()='Override']")) as? [XMLElement]) ?? []
        if overrides.contains(where: { $0.attribute(forName: "PartName")?.stringValue == "/word/comments.xml" }) {
            return
        }

        let override = XMLElement(name: "Override")
        override.addAttribute(XMLNode.attribute(withName: "PartName", stringValue: "/word/comments.xml") as! XMLNode)
        override.addAttribute(
            XMLNode.attribute(
                withName: "ContentType",
                stringValue: "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"
            ) as! XMLNode
        )
        contentTypesXML.rootElement()?.addChild(override)
    }

    private static func saveXML(_ document: XMLDocument, to url: URL) throws {
        let data = document.xmlData(options: [])
        try data.write(to: url, options: .atomic)
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DocumentCopilot",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "Package process failed." : stderr]
            )
        }
    }

    private static func nearestRunAncestor(for textElement: XMLElement) -> XMLElement? {
        var node = textElement.parent
        while let current = node {
            if current.name?.hasSuffix(":r") == true || current.name == "r" {
                return current as? XMLElement
            }
            node = current.parent
        }
        return nil
    }

    private static func textElements(in element: XMLElement) -> [XMLElement] {
        ((try? element.nodes(forXPath: ".//*[local-name()='t']")) as? [XMLElement]) ?? []
    }

    private static func readMetamorphiaWordAudits(from fileURL: URL) throws -> [WordAuditComment] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metamorphia-read-audits-\(UUID().uuidString)", isDirectory: true)
        let extracted = root.appendingPathComponent("doc", isDirectory: true)

        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-qq", fileURL.path, "-d", extracted.path],
            currentDirectory: root
        )

        let documentURL = extracted.appendingPathComponent("word/document.xml")
        let commentsURL = extracted.appendingPathComponent("word/comments.xml")
        guard fm.fileExists(atPath: commentsURL.path) else { return [] }

        let documentXML = try XMLDocument(contentsOf: documentURL, options: [])
        let commentsXML = try XMLDocument(contentsOf: commentsURL, options: [])
        let comments = ((try? commentsXML.nodes(forXPath: "//*[local-name()='comment']")) as? [XMLElement]) ?? []

        return comments.compactMap { comment in
            let author = attributeValue(named: "author", in: comment) ?? ""
            guard author.caseInsensitiveCompare("Metamorphia") == .orderedSame else { return nil }
            guard let idString = attributeValue(named: "id", in: comment),
                  let commentID = Int(idString),
                  let anchor = anchorTextForComment(id: idString, in: documentXML) else {
                return nil
            }

            let commentText = plainText(fromComment: comment)
            guard let suggestedRevision = suggestedRevision(fromAuditComment: commentText) else {
                return nil
            }

            return WordAuditComment(
                commentID: commentID,
                anchorText: anchor,
                commentText: commentText,
                suggestedRevision: suggestedRevision
            )
        }
    }

    private static func plainText(fromComment comment: XMLElement) -> String {
        let paragraphs = ((try? comment.nodes(forXPath: ".//*[local-name()='p']")) as? [XMLElement]) ?? []
        let lines = paragraphs.map { paragraph in
            textElements(in: paragraph)
                .compactMap(\.stringValue)
                .joined()
        }
        if !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
        return textElements(in: comment)
            .compactMap(\.stringValue)
            .joined(separator: "\n")
    }

    private static func suggestedRevision(fromAuditComment text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            let labels = ["rewrite:", "suggested rewrite:"]
            for label in labels where lowered.hasPrefix(label) {
                let start = trimmed.index(trimmed.startIndex, offsetBy: label.count)
                let revision = cleanSuggestedRevision(String(trimmed[start...]))
                return revision.isEmpty ? nil : revision
            }
        }
        return nil
    }

    private static func anchorTextForComment(id: String, in documentXML: XMLDocument) -> String? {
        let elements = ((try? documentXML.nodes(forXPath: "//*")) as? [XMLElement]) ?? []
        var isCollecting = false
        var chunks: [String] = []

        for element in elements {
            switch localName(of: element) {
            case "commentRangeStart" where attributeValue(named: "id", in: element) == id:
                isCollecting = true
            case "commentRangeEnd" where attributeValue(named: "id", in: element) == id:
                let text = chunks.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            case "t" where isCollecting:
                if let value = element.stringValue {
                    chunks.append(value)
                }
            default:
                break
            }
        }

        let text = chunks.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func attributeValue(named localAttributeName: String, in element: XMLElement) -> String? {
        element.attributes?
            .first(where: { attribute in
                guard let name = attribute.name else { return false }
                return name == localAttributeName || name.hasSuffix(":\(localAttributeName)")
            })?
            .stringValue
    }

    private static func localName(of element: XMLElement) -> String {
        guard let name = element.name else { return "" }
        return name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func reloadWordDocumentIfPossible(at fileURL: URL) async {
        let escapedPath = LocalCommandHelpers.escapeAppleScript(fileURL.path)
        let script = """
        tell application "Microsoft Word"
            activate
            try
                if exists active document then close active document saving no
            end try
            try
                open POSIX file "\(escapedPath)"
            end try
        end tell
        """
        _ = try? await AppleScriptHelper.executeVoid(script)
    }
}

private struct DetectedIntent {
    let requestedKind: DocumentReviewKind?
}

enum DocumentReviewPreparation {
    case notDocumentIntent
    case route(DocumentReviewRoute)
    case failure(String)
}
