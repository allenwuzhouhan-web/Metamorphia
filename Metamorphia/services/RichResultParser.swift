/*
 * Metamorphia
 * T11 — Rich Result Parser
 *
 * Inspects the agent's terminal text for structured shapes.
 * Parse order: event marker → list (≥3 items, ≥50% ratio) → date (<300 chars).
 * Returns nil when no shape matches; callers guard against overwriting an
 * existing richContent (preserves the functionGraph pre-seed).
 */

import Foundation

public struct RichParseResult: Sendable, Hashable {
    public let content: RichTurnContent
    public let displayText: String
}

public enum RichResultParser {

    public static func parse(_ text: String) -> RichParseResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let powerPointDesign = parsePowerPointDesign(in: trimmed) { return powerPointDesign }
        if let powerPoint = parsePowerPointRewrite(in: trimmed) { return powerPoint }
        if let document = parseDocumentReview(in: trimmed) { return document }
        if let event = parseEvent(in: trimmed) {
            return RichParseResult(content: .eventResult(event), displayText: trimmed)
        }
        if let list = parseList(in: trimmed) {
            return RichParseResult(content: .listResult(list), displayText: trimmed)
        }
        if let date = parseDate(in: trimmed) {
            return RichParseResult(content: .dateResult(date), displayText: trimmed)
        }
        return nil
    }

    // MARK: - PowerPoint design marker: [PPT_DESIGN] ... [/PPT_DESIGN]

    public static func parsePowerPointDesign(in text: String) -> RichParseResult? {
        guard let payload = extractMarkedPayload(
            in: text,
            startToken: "[PPT_DESIGN]",
            endToken: "[/PPT_DESIGN]"
        ), let design = decodePowerPointDesign(from: payload) else { return nil }

        let cleaned = removeMarkedPayload(
            from: text,
            startToken: "[PPT_DESIGN]",
            endToken: "[/PPT_DESIGN]"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = cleaned.isEmpty ? design.summary : cleaned
        return RichParseResult(
            content: .powerPointDesign(design),
            displayText: displayText
        )
    }

    private static func decodePowerPointDesign(from payload: String) -> PowerPointDesignResult? {
        let normalizedPayload = normalizeDocumentReviewPayload(payload)
        if let data = normalizedPayload.data(using: .utf8),
           let design = try? JSONDecoder().decode(PowerPointDesignResult.self, from: data) {
            return design
        }

        guard let data = normalizedPayload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return powerPointDesign(from: object)
    }

    private static func powerPointDesign(from object: [String: Any]) -> PowerPointDesignResult? {
        guard let presentationTitle = firstString(in: object, keys: ["presentationTitle", "presentation", "deckTitle"]),
              let slideIndex = firstInt(in: object, keys: ["slideIndex", "slide_index", "slide"]),
              let summary = firstString(in: object, keys: ["summary", "message", "overview"]) else {
            return nil
        }

        let paletteObject = object["palette"] as? [String: Any] ?? [:]
        let typographyObject = object["typography"] as? [String: Any] ?? [:]
        let palette = PowerPointDesignPalette(
            name: firstString(in: paletteObject, keys: ["name"]) ?? "Custom",
            primary: firstString(in: paletteObject, keys: ["primary"]) ?? "2F3C7E",
            secondary: firstString(in: paletteObject, keys: ["secondary"]) ?? "F2F2F2",
            accent: firstString(in: paletteObject, keys: ["accent"]) ?? "F96167",
            background: firstString(in: paletteObject, keys: ["background"]) ?? "FFFFFF",
            text: firstString(in: paletteObject, keys: ["text"]) ?? "111827",
            mutedText: firstString(in: paletteObject, keys: ["mutedText", "muted_text"]) ?? "4B5563"
        )
        let typography = PowerPointDesignTypography(
            titleFont: firstString(in: typographyObject, keys: ["titleFont", "title_font"]) ?? "Aptos Display",
            bodyFont: firstString(in: typographyObject, keys: ["bodyFont", "body_font"]) ?? "Aptos",
            titleSize: firstDouble(in: typographyObject, keys: ["titleSize", "title_size"]) ?? 38,
            bodySize: firstDouble(in: typographyObject, keys: ["bodySize", "body_size"]) ?? 16
        )
        return PowerPointDesignResult(
            presentationTitle: presentationTitle,
            sourceFilePath: normalizedOptional(firstString(in: object, keys: ["sourceFilePath", "source_file_path", "filePath"])),
            slideIndex: slideIndex,
            slideTitle: normalizedOptional(firstString(in: object, keys: ["slideTitle", "slide_title"])),
            scope: firstString(in: object, keys: ["scope"])?.lowercased() == "wholedeck" ? .wholeDeck : nil,
            slideCount: firstInt(in: object, keys: ["slideCount", "slide_count"]),
            summary: summary,
            recipe: firstString(in: object, keys: ["recipe", "layout", "designRecipe"]) ?? "Editorial feature",
            palette: palette,
            typography: typography,
            motif: firstString(in: object, keys: ["motif"]) ?? "Accent bar",
            operations: powerPointDesignOperations(from: object["operations"] ?? object["changes"]),
            textBlocks: powerPointDesignTextBlocks(from: object["textBlocks"] ?? object["text_blocks"] ?? object["contentBlocks"])
        )
    }

    private static func powerPointDesignOperations(from raw: Any?) -> [PowerPointDesignOperation] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            let kindRaw = firstString(in: object, keys: ["kind", "type"])?.lowercased() ?? "hierarchy"
            return PowerPointDesignOperation(
                kind: PowerPointDesignOperationKind(rawValue: kindRaw) ?? .hierarchy,
                target: firstString(in: object, keys: ["target", "scope"]) ?? "Current slide",
                detail: firstString(in: object, keys: ["detail", "description", "change"]) ?? ""
            )
        }
    }

    private static func powerPointDesignTextBlocks(from raw: Any?) -> [PowerPointDesignTextBlock] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { item in
            guard let object = item as? [String: Any],
                  let shapeIndex = firstInt(in: object, keys: ["shapeIndex", "shape_index", "index", "id"]),
                  let replacementText = firstString(
                    in: object,
                    keys: [
                        "replacementText", "replacement_text", "newText", "new_text",
                        "structuredText", "structured_text", "after", "text"
                    ]
                  ) else {
                return nil
            }
            let roleRaw = firstString(in: object, keys: ["role", "shapeRole", "shape_role"])?.lowercased() ?? "other"
            return PowerPointDesignTextBlock(
                shapeIndex: shapeIndex,
                shapeName: firstString(in: object, keys: ["shapeName", "shape_name", "name"]) ?? "",
                role: PowerPointShapeRole(rawValue: roleRaw) ?? .other,
                originalText: firstString(in: object, keys: ["originalText", "original_text", "before"]) ?? "",
                replacementText: replacementText,
                rationale: firstString(in: object, keys: ["rationale", "reason", "why"])
            )
        }
    }

    // MARK: - PowerPoint finish marker: [PPT_FINISH] ... [/PPT_FINISH]

    public static func parsePowerPointFinish(in text: String) -> RichParseResult? {
        guard let payload = extractMarkedPayload(
            in: text,
            startToken: "[PPT_FINISH]",
            endToken: "[/PPT_FINISH]"
        ), let finish = decodePowerPointFinish(from: payload) else { return nil }

        let cleaned = removeMarkedPayload(
            from: text,
            startToken: "[PPT_FINISH]",
            endToken: "[/PPT_FINISH]"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = cleaned.isEmpty ? finish.summary : cleaned
        return RichParseResult(
            content: .powerPointFinish(finish),
            displayText: displayText
        )
    }

    private static func decodePowerPointFinish(from payload: String) -> PowerPointFinishResult? {
        let normalizedPayload = normalizeDocumentReviewPayload(payload)
        guard let data = normalizedPayload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PowerPointFinishResult.self, from: data)
    }

    // MARK: - Excel analysis marker: [XL_ANALYSIS] ... [/XL_ANALYSIS]

    /// Decodes only the model's PLAN (kind + columns + interpretation) into a
    /// placeholder result. The view model fills the statistics via
    /// `ExcelCopilot.computeResult` against the captured table.
    public static func parseExcelAnalysis(in text: String) -> RichParseResult? {
        guard let payload = extractMarkedPayload(
            in: text,
            startToken: "[XL_ANALYSIS]",
            endToken: "[/XL_ANALYSIS]"
        ) else { return nil }

        let normalized = normalizeDocumentReviewPayload(payload)
        guard let data = normalized.data(using: .utf8),
              let plan = try? JSONDecoder().decode(ExcelAnalysisPlan.self, from: data) else { return nil }

        let placeholder = ExcelAnalysisResult(
            kind: plan.kind,
            workbookName: "",
            sheetName: "",
            sourceAddress: "",
            yColumn: plan.yColumn,
            xColumns: plan.xColumns,
            groupColumn: plan.groupColumn,
            interpretation: plan.interpretation
        )

        let cleaned = removeMarkedPayload(
            from: text,
            startToken: "[XL_ANALYSIS]",
            endToken: "[/XL_ANALYSIS]"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = cleaned.isEmpty ? plan.interpretation : cleaned
        return RichParseResult(content: .excelAnalysis(placeholder), displayText: displayText)
    }

    // MARK: - PowerPoint rewrite marker: [PPT_REWRITE] ... [/PPT_REWRITE]

    public static func parsePowerPointRewrite(in text: String) -> RichParseResult? {
        guard let payload = extractMarkedPayload(
            in: text,
            startToken: "[PPT_REWRITE]",
            endToken: "[/PPT_REWRITE]"
        ), let rewrite = decodePowerPointRewrite(from: payload) else { return nil }

        let cleaned = removeMarkedPayload(
            from: text,
            startToken: "[PPT_REWRITE]",
            endToken: "[/PPT_REWRITE]"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = cleaned.isEmpty ? rewrite.summary : cleaned
        return RichParseResult(
            content: .powerPointRewrite(rewrite),
            displayText: displayText
        )
    }

    private static func decodePowerPointRewrite(from payload: String) -> PowerPointRewriteResult? {
        let normalizedPayload = normalizeDocumentReviewPayload(payload)
        if let data = normalizedPayload.data(using: .utf8),
           let rewrite = try? JSONDecoder().decode(PowerPointRewriteResult.self, from: data) {
            return rewrite
        }

        guard let data = normalizedPayload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return decodePowerPointRewriteLeniently(from: normalizedPayload)
        }

        return powerPointRewrite(from: object)
    }

    private static func decodePowerPointRewriteLeniently(from payload: String) -> PowerPointRewriteResult? {
        guard let presentationTitle = firstExtractedJSONStringValue(
                forKeys: ["presentationTitle", "presentation", "deckTitle"],
                in: payload
              ),
              let slideIndexRaw = firstExtractedJSONNumberValue(
                forKeys: ["slideIndex", "slide_index", "slide"],
                in: payload
              ),
              let slideIndex = Int(slideIndexRaw),
              let summary = firstExtractedJSONStringValue(
                forKeys: ["summary", "message", "overview"],
                in: payload
              ) else {
            return nil
        }

        let replacementsPayload = extractJSONArrayPayload(forKey: "replacements", in: payload) ??
            extractJSONArrayPayload(forKey: "edits", in: payload) ??
            extractJSONArrayPayload(forKey: "changes", in: payload) ??
            ""
        let replacementObjects = splitTopLevelJSONObjectArray(replacementsPayload)
        let replacements = replacementObjects.compactMap(powerPointReplacementLenient(from:))

        return PowerPointRewriteResult(
            presentationTitle: presentationTitle,
            sourceFilePath: normalizedOptional(firstExtractedJSONStringValue(
                forKeys: ["sourceFilePath", "source_file_path", "filePath"],
                in: payload
            )),
            slideIndex: slideIndex,
            slideTitle: normalizedOptional(firstExtractedJSONStringValue(
                forKeys: ["slideTitle", "slide_title"],
                in: payload
            )),
            summary: summary,
            replacements: replacements
        )
    }

    private static func powerPointRewrite(from object: [String: Any]) -> PowerPointRewriteResult? {
        guard let presentationTitle = firstString(in: object, keys: ["presentationTitle", "presentation", "deckTitle"]),
              let slideIndex = firstInt(in: object, keys: ["slideIndex", "slide_index", "slide"]),
              let summary = firstString(in: object, keys: ["summary", "message", "overview"]) else {
            return nil
        }

        let replacements = powerPointReplacements(from: object["replacements"] ?? object["edits"] ?? object["changes"])
        return PowerPointRewriteResult(
            presentationTitle: presentationTitle,
            sourceFilePath: normalizedOptional(firstString(in: object, keys: ["sourceFilePath", "source_file_path", "filePath"])),
            slideIndex: slideIndex,
            slideTitle: normalizedOptional(firstString(in: object, keys: ["slideTitle", "slide_title"])),
            summary: summary,
            replacements: replacements
        )
    }

    private static func powerPointReplacement(from object: [String: Any]) -> PowerPointRewriteReplacement? {
        guard let shapeIndex = firstInt(in: object, keys: ["shapeIndex", "shape_index", "index", "id"]),
              let replacementText = firstString(
                in: object,
                keys: [
                    "replacementText", "replacement_text", "newText", "new_text",
                    "revisedText", "revised_text", "after", "conciseText", "text"
                ]
              ) else {
            return nil
        }
        let roleRaw = firstString(in: object, keys: ["role", "shapeRole", "shape_role"])?.lowercased() ?? "other"
        return PowerPointRewriteReplacement(
            shapeIndex: shapeIndex,
            shapeName: firstString(in: object, keys: ["shapeName", "shape_name", "name"]) ?? "",
            role: PowerPointShapeRole(rawValue: roleRaw) ?? .other,
            originalText: firstString(in: object, keys: ["originalText", "original_text", "before"]) ?? "",
            replacementText: replacementText,
            rationale: firstString(in: object, keys: ["rationale", "reason", "why"])
        )
    }

    private static func powerPointReplacements(from raw: Any?) -> [PowerPointRewriteReplacement] {
        if let array = raw as? [Any] {
            return array.compactMap { item in
                guard let object = item as? [String: Any] else { return nil }
                return powerPointReplacement(from: object)
            }
        }

        if let object = raw as? [String: Any] {
            return object.compactMap { key, value in
                var replacementObject: [String: Any]
                if let nested = value as? [String: Any] {
                    replacementObject = nested
                } else if let text = stringValue(value) {
                    replacementObject = ["replacementText": text]
                } else {
                    return nil
                }

                if replacementObject["shapeIndex"] == nil,
                   replacementObject["shape_index"] == nil,
                   let shapeIndex = Int(key) {
                    replacementObject["shapeIndex"] = shapeIndex
                }
                return powerPointReplacement(from: replacementObject)
            }
        }

        return []
    }

    private static func powerPointReplacementLenient(from objectPayload: String) -> PowerPointRewriteReplacement? {
        guard let shapeIndexRaw = firstExtractedJSONNumberValue(
                forKeys: ["shapeIndex", "shape_index", "index", "id"],
                in: objectPayload
              ),
              let shapeIndex = Int(shapeIndexRaw),
              let replacementText = firstExtractedJSONStringValue(
                forKeys: [
                    "replacementText", "replacement_text", "newText", "new_text",
                    "revisedText", "revised_text", "after", "conciseText", "text"
                ],
                in: objectPayload
              ) else {
            return nil
        }
        let roleRaw = firstExtractedJSONStringValue(
            forKeys: ["role", "shapeRole", "shape_role"],
            in: objectPayload
        )?.lowercased() ?? "other"
        return PowerPointRewriteReplacement(
            shapeIndex: shapeIndex,
            shapeName: firstExtractedJSONStringValue(forKeys: ["shapeName", "shape_name", "name"], in: objectPayload) ?? "",
            role: PowerPointShapeRole(rawValue: roleRaw) ?? .other,
            originalText: firstExtractedJSONStringValue(forKeys: ["originalText", "original_text", "before"], in: objectPayload) ?? "",
            replacementText: replacementText,
            rationale: firstExtractedJSONStringValue(forKeys: ["rationale", "reason", "why"], in: objectPayload)
        )
    }

    // MARK: - Document review marker: [DOC_REVIEW] ... [/DOC_REVIEW]

    private static let documentReviewPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?s)\[DOC_REVIEW\]\s*(.*?)\s*\[/DOC_REVIEW\]"#,
            options: []
        )
    }()

    public static func parseDocumentReview(in text: String) -> RichParseResult? {
        guard let payload = extractDocumentReviewPayload(in: text),
              let review = decodeDocumentReview(from: payload) else { return nil }

        let cleaned = removeDocumentReviewBlock(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = cleaned.isEmpty ? review.summary : cleaned
        return RichParseResult(
            content: .documentReview(review),
            displayText: displayText
        )
    }

    private static func extractDocumentReviewPayload(in text: String) -> String? {
        extractMarkedPayload(
            in: text,
            startToken: "[DOC_REVIEW]",
            endToken: "[/DOC_REVIEW]"
        )
    }

    private static func removeDocumentReviewBlock(from text: String) -> String {
        removeMarkedPayload(
            from: text,
            startToken: "[DOC_REVIEW]",
            endToken: "[/DOC_REVIEW]"
        )
    }

    private static func extractMarkedPayload(
        in text: String,
        startToken: String,
        endToken: String
    ) -> String? {
        guard let start = text.range(of: startToken),
              let end = text.range(of: endToken, range: start.upperBound..<text.endIndex) else {
            return nil
        }

        let payload = text[start.upperBound..<end.lowerBound]
        return String(payload).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeMarkedPayload(
        from text: String,
        startToken: String,
        endToken: String
    ) -> String {
        guard let start = text.range(of: startToken),
              let end = text.range(of: endToken, range: start.lowerBound..<text.endIndex) else {
            return text
        }
        var cleaned = text
        cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        return cleaned
    }

    private static func decodeDocumentReview(from payload: String) -> DocumentReviewResult? {
        let normalizedPayload = normalizeDocumentReviewPayload(payload)
        if let data = normalizedPayload.data(using: .utf8),
           let review = try? JSONDecoder().decode(DocumentReviewResult.self, from: data) {
            return review
        }

        guard let data = normalizedPayload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return decodeDocumentReviewLeniently(from: normalizedPayload)
        }

        return documentReview(from: object)
    }

    private static func decodeDocumentReviewLeniently(from payload: String) -> DocumentReviewResult? {
        guard let documentTitle = extractJSONStringValue(forKey: "documentTitle", in: payload),
              let kindRaw = extractJSONStringValue(forKey: "documentKind", in: payload)?.lowercased(),
              let documentKind = DocumentReviewKind(rawValue: kindRaw),
              let sourceDescription = extractJSONStringValue(forKey: "sourceDescription", in: payload),
              let summary = extractJSONStringValue(forKey: "summary", in: payload) else {
            return nil
        }

        let nextStep = extractJSONStringValue(forKey: "nextStep", in: payload)
        let sourceFilePath = extractJSONStringValue(forKey: "sourceFilePath", in: payload)
        let findingsPayload = extractJSONArrayPayload(forKey: "findings", in: payload) ?? ""
        let findingObjects = splitTopLevelJSONObjectArray(findingsPayload)
        let findings = findingObjects.compactMap(documentReviewFindingLenient(from:))

        return DocumentReviewResult(
            documentTitle: documentTitle,
            documentKind: documentKind,
            sourceDescription: sourceDescription,
            sourceFilePath: sourceFilePath,
            summary: summary,
            nextStep: nextStep,
            findings: findings
        )
    }

    private static func normalizeDocumentReviewPayload(_ payload: String) -> String {
        let stripped = payload
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidate: String
        if let firstBrace = stripped.firstIndex(of: "{"),
           let lastBrace = stripped.lastIndex(of: "}") {
            candidate = String(stripped[firstBrace...lastBrace])
        } else {
            candidate = stripped
        }

        let filteredScalars = candidate.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return true
            case 0x00...0x1F:
                return false
            default:
                return true
            }
        }

        return String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func documentReview(from object: [String: Any]) -> DocumentReviewResult? {
        guard let documentTitle = object["documentTitle"] as? String,
              let kindRaw = (object["documentKind"] as? String)?.lowercased(),
              let documentKind = DocumentReviewKind(rawValue: kindRaw),
              let sourceDescription = object["sourceDescription"] as? String,
              let summary = object["summary"] as? String else {
            return nil
        }

        let findingsArray = object["findings"] as? [[String: Any]] ?? []
        let findings = findingsArray.compactMap(documentReviewFinding(from:))

        return DocumentReviewResult(
            documentTitle: documentTitle,
            documentKind: documentKind,
            sourceDescription: sourceDescription,
            sourceFilePath: object["sourceFilePath"] as? String,
            summary: summary,
            nextStep: object["nextStep"] as? String,
            findings: findings
        )
    }

    private static func documentReviewFinding(from object: [String: Any]) -> DocumentReviewFinding? {
        guard let title = object["title"] as? String,
              let location = object["location"] as? String,
              let rationale = object["rationale"] as? String else {
            return nil
        }

        let severityRaw = (object["severity"] as? String)?.lowercased() ?? "medium"
        let severity = DocumentReviewSeverity(rawValue: severityRaw) ?? .medium

        return DocumentReviewFinding(
            title: title,
            location: location,
            severity: severity,
            rationale: rationale,
            anchorText: object["anchorText"] as? String,
            suggestedRevision: object["suggestedRevision"] as? String
        )
    }

    private static func documentReviewFindingLenient(from objectPayload: String) -> DocumentReviewFinding? {
        guard let title = extractJSONStringValue(forKey: "title", in: objectPayload),
              let location = extractJSONStringValue(forKey: "location", in: objectPayload),
              let rationale = extractJSONStringValue(forKey: "rationale", in: objectPayload) else {
            return nil
        }

        let severityRaw = extractJSONStringValue(forKey: "severity", in: objectPayload)?.lowercased() ?? "medium"
        let severity = DocumentReviewSeverity(rawValue: severityRaw) ?? .medium

        return DocumentReviewFinding(
            title: title,
            location: location,
            severity: severity,
            rationale: rationale,
            anchorText: extractJSONStringValue(forKey: "anchorText", in: objectPayload),
            suggestedRevision: extractJSONStringValue(forKey: "suggestedRevision", in: objectPayload)
        )
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func firstInt(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func firstDouble(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = doubleValue(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func firstExtractedJSONStringValue(forKeys keys: [String], in payload: String) -> String? {
        for key in keys {
            if let value = extractJSONStringValue(forKey: key, in: payload) {
                return value
            }
        }
        return nil
    }

    private static func firstExtractedJSONNumberValue(forKeys keys: [String], in payload: String) -> String? {
        for key in keys {
            if let value = extractJSONNumberValue(forKey: key, in: payload) {
                return value
            }
            if let stringValue = extractJSONStringValue(forKey: key, in: payload),
               Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                return stringValue
            }
        }
        return nil
    }

    private static func extractJSONStringValue(forKey key: String, in payload: String) -> String? {
        let pattern = #""\#(key)"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
        guard let match = regex.firstMatch(in: payload, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: payload) else {
            return nil
        }

        let rawValue = String(payload[valueRange])
        let escaped = rawValue
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\n"#, with: "\n")
            .replacingOccurrences(of: #"\\r"#, with: "\r")
            .replacingOccurrences(of: #"\\t"#, with: "\t")
            .replacingOccurrences(of: #"\\/"#, with: "/")
            .replacingOccurrences(of: #"\\\\"#, with: "\\")
        return escaped
    }

    private static func extractJSONNumberValue(forKey key: String, in payload: String) -> String? {
        let pattern = #""\#(key)"\s*:\s*(-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
        guard let match = regex.firstMatch(in: payload, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: payload) else {
            return nil
        }
        return String(payload[valueRange])
    }

    private static func normalizedOptional(_ string: String?) -> String? {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractJSONArrayPayload(forKey key: String, in payload: String) -> String? {
        guard let keyRange = payload.range(of: #""\#(key)""#, options: .regularExpression) else {
            return nil
        }
        guard let colonRange = payload.range(of: ":", range: keyRange.upperBound..<payload.endIndex),
              let arrayStart = payload.range(of: "[", range: colonRange.upperBound..<payload.endIndex) else {
            return nil
        }

        var index = arrayStart.upperBound
        var depth = 1
        var inString = false
        var escaped = false

        while index < payload.endIndex {
            let char = payload[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "[" {
                    depth += 1
                } else if char == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(payload[arrayStart.upperBound..<index])
                    }
                }
            }
            index = payload.index(after: index)
        }

        return nil
    }

    private static func splitTopLevelJSONObjectArray(_ payload: String) -> [String] {
        var objects: [String] = []
        var startIndex: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        var index = payload.startIndex

        while index < payload.endIndex {
            let char = payload[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    if depth == 0 {
                        startIndex = index
                    }
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0, let objectStart = startIndex {
                        let end = payload.index(after: index)
                        objects.append(String(payload[objectStart..<end]))
                        startIndex = nil
                    }
                }
            }
            index = payload.index(after: index)
        }

        return objects
    }

    // MARK: - Event marker: [EVENT: title | ISO-date | location?]

    private static let eventPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\[EVENT:\s*(.+?)\s*\|\s*(.+?)\s*(?:\|\s*(.+?))?\s*\]"#,
            options: [.caseInsensitive]
        )
    }()

    public static func parseEvent(in text: String) -> EventResult? {
        guard let regex = eventPattern else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        let title = ns.substring(with: m.range(at: 1))
        let dateStr = ns.substring(with: m.range(at: 2))
        let location: String? = m.range(at: 3).location != NSNotFound
            ? ns.substring(with: m.range(at: 3))
            : nil
        guard let date = parseAnyDate(dateStr) else { return nil }

        let notes = ns.replacingCharacters(in: m.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return EventResult(
            title: title,
            date: date,
            endDate: nil,
            location: location,
            attendeeCount: nil,
            notes: notes.isEmpty ? nil : notes
        )
    }

    // MARK: - Lists

    private static let listMarkerPattern = #"^(?:\d+[\.\)]\s*|-\s*|\*\s*|•\s*)"#

    public static func parseList(in text: String) -> ListResult? {
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard rawLines.count >= 3 else { return nil }
        guard let regex = try? NSRegularExpression(pattern: listMarkerPattern) else { return nil }

        var items: [ListItem] = []
        var title: String?
        var listLineCount = 0

        for (i, line) in rawLines.enumerated() {
            let ns = line as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            if let m = regex.firstMatch(in: line, range: fullRange) {
                let body = ns.substring(from: m.range.upperBound)
                    .trimmingCharacters(in: .whitespaces)
                let parts = body.components(separatedBy: " - ")
                if parts.count >= 2 {
                    items.append(ListItem(
                        text: parts[0],
                        detail: parts.dropFirst().joined(separator: " - ")
                    ))
                } else {
                    items.append(ListItem(text: body, detail: nil))
                }
                listLineCount += 1
            } else if i == 0 && items.isEmpty {
                title = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*: "))
            }
        }

        let ratio = Double(listLineCount) / Double(rawLines.count)
        guard items.count >= 3, ratio >= 0.5 else { return nil }
        return ListResult(title: title, items: items)
    }

    // MARK: - Dates

    public static func parseDate(in text: String) -> DateResult? {
        guard text.count < 300 else { return nil }

        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        )
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = detector?.matches(in: text, range: range).first,
              let date = match.date else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = match.duration > 0 ? .short : .none

        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full

        let contextText = ns.replacingCharacters(in: match.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:- "))

        return DateResult(
            date: date,
            formattedDate: formatter.string(from: date),
            relativeDescription: relative.localizedString(for: date, relativeTo: Date()),
            context: contextText.isEmpty ? nil : contextText
        )
    }

    // MARK: - Shared

    private static func parseAnyDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }

        let formats = ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "MMM d, yyyy", "MMMM d, yyyy", "MM/dd/yyyy"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: string) { return d }
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let r = NSRange(location: 0, length: (string as NSString).length)
        return detector?.firstMatch(in: string, range: r)?.date
    }
}

// MARK: - Result types

public struct DateResult: Hashable, Sendable {
    public let date: Date
    public let formattedDate: String
    public let relativeDescription: String
    public let context: String?
}

public struct EventResult: Hashable, Sendable {
    public let title: String
    public let date: Date
    public let endDate: Date?
    public let location: String?
    public let attendeeCount: Int?
    public let notes: String?
}

public struct ListResult: Hashable, Sendable {
    public let title: String?
    public let items: [ListItem]
}

public struct ListItem: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let detail: String?

    public init(id: UUID = UUID(), text: String, detail: String? = nil) {
        self.id = id
        self.text = text
        self.detail = detail
    }
}
