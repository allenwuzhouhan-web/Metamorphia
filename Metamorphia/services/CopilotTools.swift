import AppKit
import Foundation
import MetamorphiaAgentKit

// MARK: - capture_deck (.documents, read-only, .safe)

/// Read-only shape inventory of the frontmost PowerPoint slide or whole deck.
/// Call this BEFORE design_deck or rewrite_slides so the model uses real
/// shapeIndex/shapeName values from the live presentation rather than inventing
/// them.
public struct CaptureDeckTool: ToolDefinition {
    public let name = "capture_deck"
    public let description = """
    Read the frontmost PowerPoint slide or whole deck and return exact shape \
    indices, names, roles, and current text. Call BEFORE design_deck or \
    rewrite_slides so you reference real shapeIndex/shapeName values instead of \
    inventing them.
    """
    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "scope": JSONSchema.enumString(
                description: "currentSlide (default) or wholeDeck",
                values: ["currentSlide", "wholeDeck"]
            )
        ])
    }
    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let scopeRaw = (args["scope"] as? String) ?? "currentSlide"
        let scope: PowerPointAutomationScope = scopeRaw == "wholeDeck" ? .wholeDeck : .currentSlide
        switch await PowerPointCopilot.captureShapesForTool(scope: scope) {
        case .success(let listing):
            return listing
        case .failure(let error):
            throw ToolExecutionError(error.message)
        }
    }
}

// MARK: - design_deck (.documents, .critical)

/// Apply a visual design plan to the current PowerPoint slide or whole deck.
/// Provide the design plan arguments (palette, typography, operations, textBlocks)
/// referencing shapeIndex values from capture_deck. Honors the [PPT_DESIGN]
/// contract; restoreData is captured automatically and the result card exposes
/// Apply/Restore/Undo controls.
public struct DesignDeckTool: ToolDefinition {
    public let name = "design_deck"
    public let description = """
    Apply a visual design plan to the current PowerPoint slide (or whole deck). \
    Provide palette/typography/recipe/operations/textBlocks referencing \
    shapeIndex values from capture_deck. Honors the [PPT_DESIGN] contract; \
    backup is taken automatically and the result card exposes Apply/Restore/Undo.
    """
    public var parameters: [String: Any] {
        JSONSchema.object(
            properties: [
                "presentationTitle": JSONSchema.string(description: "Presentation title"),
                "slideIndex": JSONSchema.integer(description: "Slide index (1-based)"),
                "slideTitle": JSONSchema.string(description: "Slide title (optional)"),
                "scope": JSONSchema.enumString(
                    description: "currentSlide or wholeDeck",
                    values: ["currentSlide", "wholeDeck"]
                ),
                "summary": JSONSchema.string(description: "Human-readable design summary"),
                "recipe": JSONSchema.enumString(
                    description: "Design recipe",
                    values: [
                        "Editorial feature", "Insight cards",
                        "Contrast panel", "Definition spotlight"
                    ]
                ),
                "motif": JSONSchema.string(description: "Short recurring motif name"),
                "palette": JSONSchema.object(properties: [
                    "name": JSONSchema.string(description: "Palette name"),
                    "primary": JSONSchema.string(description: "Primary hex color (no #)"),
                    "secondary": JSONSchema.string(description: "Secondary hex color"),
                    "accent": JSONSchema.string(description: "Accent hex color"),
                    "background": JSONSchema.string(description: "Background hex color"),
                    "text": JSONSchema.string(description: "Text hex color"),
                    "mutedText": JSONSchema.string(description: "Muted text hex color"),
                ]),
                "typography": JSONSchema.object(properties: [
                    "titleFont": JSONSchema.string(description: "Title font name"),
                    "bodyFont": JSONSchema.string(description: "Body font name"),
                    "titleSize": JSONSchema.integer(description: "Title font size (30-48)"),
                    "bodySize": JSONSchema.integer(description: "Body font size (12-22)"),
                ]),
                "operations": JSONSchema.array(
                    items: JSONSchema.object(properties: [
                        "kind": JSONSchema.string(description: "palette|typography|content|hierarchy|alignment|motif|whitespace"),
                        "target": JSONSchema.string(description: "Target description"),
                        "detail": JSONSchema.string(description: "Operation detail"),
                    ]),
                    description: "Design operations list"
                ),
                "textBlocks": JSONSchema.array(
                    items: JSONSchema.object(properties: [
                        "shapeIndex": JSONSchema.integer(description: "Shape index from capture_deck"),
                        "shapeName": JSONSchema.string(description: "Shape name from capture_deck"),
                        "role": JSONSchema.string(description: "title|body|footer|other"),
                        "originalText": JSONSchema.string(description: "Original text (exact)"),
                        "replacementText": JSONSchema.string(description: "Replacement text"),
                        "rationale": JSONSchema.string(description: "Rationale for the change"),
                    ]),
                    description: "Text block rewrites"
                ),
            ],
            required: ["presentationTitle", "slideIndex", "summary", "recipe", "palette", "typography"]
        )
    }
    public init() {}

    public func execute(arguments: String) async throws -> String {
        // 1. Determine scope from args so we know which capture path to use.
        let args = try parseArguments(arguments)
        let scopeRaw = (args["scope"] as? String) ?? "currentSlide"
        let isWholeDeck = scopeRaw == "wholeDeck"

        // 2. Build the route (captures current slide or deck, producing
        //    restoreData/shapeSnapshots). We use a synthetic prompt that hits
        //    the design router unconditionally via the internal helper.
        let route: PowerPointDesignRoute
        switch await PowerPointCopilot.prepareDesignRouteForTool(isWholeDeck: isWholeDeck) {
        case .success(let r):
            route = r
        case .failure(let error):
            throw ToolExecutionError(error.message)
        }

        // 3. Decode the model's design plan from the tool arguments using the
        //    same lenient path as RichResultParser so partial palette/typography
        //    output (fields absent from the schema's required list) gets defaults
        //    instead of throwing.
        let rawDesign: PowerPointDesignResult
        let wrappedArguments = "[PPT_DESIGN]\n\(arguments)\n[/PPT_DESIGN]"
        if let parsed = RichResultParser.parsePowerPointDesign(in: wrappedArguments),
           case .powerPointDesign(let design) = parsed.content {
            rawDesign = design
        } else {
            throw ToolExecutionError("Could not decode design_deck arguments: the model's tool-call JSON is missing required fields (presentationTitle, slideIndex, or summary).")
        }

        // 4. Resolve — fills in restoreData, shapeSnapshots, palette normalization.
        let resolved = PowerPointCopilot.resolvedDesign(rawDesign, route: route)

        // 5. Encode the resolved result as a [PPT_DESIGN] block so the
        //    RichResultParser can reconstruct the result card (with working
        //    Apply/Restore/Undo buttons) via the opportunistic parse path.
        let encoded: String
        do {
            let data = try JSONEncoder().encode(resolved)
            encoded = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw ToolExecutionError("Could not encode design result: \(error.localizedDescription)")
        }

        return """
        \(resolved.summary)

        [PPT_DESIGN]
        \(encoded)
        [/PPT_DESIGN]
        """
    }
}

// MARK: - rewrite_slides (.documents, .critical)

/// Rewrite editable text on the current PowerPoint slide. Provide replacements
/// referencing shapeIndex values from capture_deck. Honors the [PPT_REWRITE]
/// contract; the result card exposes Apply/Restore controls.
public struct RewriteSlidesTool: ToolDefinition {
    public let name = "rewrite_slides"
    public let description = """
    Rewrite editable text on the current PowerPoint slide. Provide replacements \
    referencing shapeIndex values from capture_deck. Honors the [PPT_REWRITE] \
    contract; the result card exposes Apply/Restore controls.
    """
    public var parameters: [String: Any] {
        JSONSchema.object(
            properties: [
                "presentationTitle": JSONSchema.string(description: "Presentation title"),
                "sourceFilePath": JSONSchema.string(description: "File path (optional)"),
                "slideIndex": JSONSchema.integer(description: "Slide index (1-based)"),
                "slideTitle": JSONSchema.string(description: "Slide title (optional)"),
                "summary": JSONSchema.string(description: "Human-readable summary of the rewrites"),
                "replacements": JSONSchema.array(
                    items: JSONSchema.object(properties: [
                        "shapeIndex": JSONSchema.integer(description: "Shape index from capture_deck"),
                        "shapeName": JSONSchema.string(description: "Shape name from capture_deck"),
                        "role": JSONSchema.string(description: "title|body|footer|other"),
                        "originalText": JSONSchema.string(description: "Original text (exact)"),
                        "replacementText": JSONSchema.string(description: "Replacement text"),
                        "rationale": JSONSchema.string(description: "Rationale for the change"),
                    ]),
                    description: "Text replacements list"
                ),
            ],
            required: ["presentationTitle", "slideIndex", "summary", "replacements"]
        )
    }
    public init() {}

    public func execute(arguments: String) async throws -> String {
        // 1. Build the rewrite route (captures current slide, producing shapeSnapshots).
        let route: PowerPointRewriteRoute
        switch await PowerPointCopilot.prepareRewriteRouteForTool() {
        case .success(let r):
            route = r
        case .failure(let error):
            throw ToolExecutionError(error.message)
        }

        // 2. Decode the model's rewrite plan.
        let rawRewrite: PowerPointRewriteResult
        do {
            rawRewrite = try JSONDecoder().decode(
                PowerPointRewriteResult.self,
                from: arguments.data(using: .utf8) ?? Data()
            )
        } catch {
            throw ToolExecutionError("Could not decode rewrite_slides arguments: \(error.localizedDescription)")
        }

        // 3. Resolve — validates shapeIndex/originalText against snapshots.
        let resolved = PowerPointCopilot.resolvedRewrite(rawRewrite, route: route)

        guard !resolved.replacements.isEmpty else {
            let failure = PowerPointCopilot.resolutionFailureMessage(for: rawRewrite, route: route)
            throw ToolExecutionError(failure)
        }

        // 4. Encode and return as a [PPT_REWRITE] block.
        let encoded: String
        do {
            let data = try JSONEncoder().encode(resolved)
            encoded = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw ToolExecutionError("Could not encode rewrite result: \(error.localizedDescription)")
        }

        return """
        \(resolved.summary)

        [PPT_REWRITE]
        \(encoded)
        [/PPT_REWRITE]
        """
    }
}

// MARK: - direct_edit (.documents, .critical)

/// Apply a single deterministic formatting property (bold, italic, underline,
/// fontSize, textColor, alignment) to all editable text boxes on the current
/// PowerPoint slide. The edit is applied immediately; a restore snapshot is
/// captured before the change so the result card exposes Restore/Undo controls.
/// Use this instead of design_deck/rewrite_slides when the user asks for a
/// simple "make everything bold" or "set font size to 24" type of edit.
public struct DirectEditTool: ToolDefinition {
    public let name = "direct_edit"
    public let description = """
    Apply a single formatting property to all editable text boxes on the current \
    PowerPoint slide (bold, italic, underline, fontSize, textColor, alignment). \
    The edit is applied immediately; a restore snapshot is captured so the \
    result card exposes Restore/Undo controls. Use for simple slide-wide \
    formatting commands like "make all text bold" or "set font size to 24".
    """
    public var parameters: [String: Any] {
        JSONSchema.object(
            properties: [
                "property": JSONSchema.enumString(
                    description: "Formatting property to change",
                    values: ["bold", "italic", "underline", "fontSize", "textColor", "alignment"]
                ),
                "value": JSONSchema.string(
                    description: """
                    Value for the property:
                    • bold/italic/underline: "on" or "off"
                    • fontSize: integer as a string (e.g. "24")
                    • textColor: color name (black, white, red, green, blue, yellow, orange, purple, gray, lime green) or hex code (#RRGGBB)
                    • alignment: "left", "center", "right", or "justified"
                    """
                ),
            ],
            required: ["property", "value"]
        )
    }
    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let propertyRaw = args["property"] as? String,
              let property = PowerPointDirectEditKind(rawValue: propertyRaw) else {
            throw ToolExecutionError("Missing or invalid 'property'. Provide one of: bold, italic, underline, fontSize, textColor, alignment.")
        }
        guard let value = args["value"] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolExecutionError("Missing or empty 'value'.")
        }

        // Execute the formatting change immediately (captures restore snapshot).
        let result: PowerPointDirectEditResult
        switch await PowerPointCopilot.performDirectEditForTool(property: property, value: value) {
        case .success(let r):
            result = r
        case .failure(let error):
            throw ToolExecutionError(error.message)
        }

        // Encode as [PPT_DIRECT] so RichResultParser dispatches to
        // .powerPointDirectEdit and the result card shows Restore/Undo.
        let encoded: String
        do {
            let data = try JSONEncoder().encode(result)
            encoded = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw ToolExecutionError("Could not encode direct-edit result: \(error.localizedDescription)")
        }

        return """
        \(result.summary)

        [PPT_DIRECT]
        \(encoded)
        [/PPT_DIRECT]
        """
    }
}

// MARK: - review_document (.documents, .critical)

/// Review the frontmost Word or PowerPoint document and produce structured
/// findings. For saved Word documents, native comments are inserted inline.
/// Returns a [DOC_REVIEW] block so the result card exposes Jump/Comment/Apply
/// controls per finding.
public struct ReviewDocumentTool: ToolDefinition {
    public let name = "review_document"
    public let description = """
    Review the frontmost Word or PowerPoint document and produce structured \
    findings with anchor text, severity, and suggested revisions. For saved \
    Word documents, findings are inserted as native comments. Returns a \
    [DOC_REVIEW] block so the result card exposes Jump/Comment/Apply controls.
    """
    public var parameters: [String: Any] {
        JSONSchema.object(
            properties: [
                "documentTitle": JSONSchema.string(description: "Document title"),
                "documentKind": JSONSchema.enumString(
                    description: "document or presentation",
                    values: ["document", "presentation"]
                ),
                "sourceDescription": JSONSchema.string(description: "Source description"),
                "summary": JSONSchema.string(description: "Human-readable review summary"),
                "nextStep": JSONSchema.string(description: "Recommended next step (optional)"),
                "findings": JSONSchema.array(
                    items: JSONSchema.object(properties: [
                        "title": JSONSchema.string(description: "Compact finding label"),
                        "location": JSONSchema.string(description: "Specific location (e.g. 'Slide 2' or 'Opening section')"),
                        "severity": JSONSchema.enumString(
                            description: "Severity level",
                            values: ["high", "medium", "low"]
                        ),
                        "rationale": JSONSchema.string(description: "1-2 sentence rationale"),
                        "anchorText": JSONSchema.string(description: "Short exact phrase from the document"),
                        "suggestedRevision": JSONSchema.string(description: "Concrete suggested rewrite"),
                    ]),
                    description: "3 to 6 review findings"
                ),
            ],
            required: ["documentTitle", "documentKind", "sourceDescription", "summary", "findings"]
        )
    }
    public init() {}

    public func execute(arguments: String) async throws -> String {
        // 1. Capture the document's file path via the route builder.
        let route: DocumentReviewRoute
        switch await DocumentCopilot.prepareReviewRoute(prompt: "review this document", attachedFiles: []) {
        case .notDocumentIntent:
            throw ToolExecutionError("No Word or PowerPoint document is currently open and frontmost.")
        case .failure(let message):
            throw ToolExecutionError(message)
        case .route(let r):
            route = r
        }

        // 2. Decode the model's review findings from tool arguments.
        let rawReview: DocumentReviewResult
        do {
            rawReview = try JSONDecoder().decode(
                DocumentReviewResult.self,
                from: arguments.data(using: .utf8) ?? Data()
            )
        } catch {
            throw ToolExecutionError("Could not decode review_document arguments: \(error.localizedDescription)")
        }

        // 3. Inject the captured file path so Jump/Comment actions can locate
        //    the document later.
        let resolved = rawReview.withSourceFilePath(route.filePath)

        // 4. For saved Word documents, insert native comments inline.
        if route.autoInsertNativeComments {
            let insertOutcome = await DocumentCopilot.insertReviewComments(resolved)
            if route.preferCompactDelivery && insertOutcome.success {
                // Compact delivery: just the outcome message, no card.
                return insertOutcome.message
            }
        }

        // 5. Encode and return as a [DOC_REVIEW] block so the result card renders.
        let encoded: String
        do {
            let data = try JSONEncoder().encode(resolved)
            encoded = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw ToolExecutionError("Could not encode review result: \(error.localizedDescription)")
        }

        return """
        \(resolved.summary)

        [DOC_REVIEW]
        \(encoded)
        [/DOC_REVIEW]
        """
    }
}

// MARK: - edit_word_comments (.documents, .critical)

/// Apply tracked-change rewrites from Metamorphia audit comments in the
/// frontmost Word document. Equivalent to the old "apply audit" fast path;
/// backs up the document first and uses Word's Review Mode.
public struct EditWordCommentsTool: ToolDefinition {
    public let name = "edit_word_comments"
    public let description = """
    Apply Metamorphia audit comments as tracked changes in the frontmost Word \
    document. The document is backed up first; edits appear in Word Review Mode \
    so the user can accept or reject each change individually.
    """
    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }
    public init() {}

    public func execute(arguments: String) async throws -> String {
        let outcome = await DocumentCopilot.applyCurrentWordAuditComments()
        guard outcome.success else {
            throw ToolExecutionError(outcome.message)
        }
        return outcome.message
    }
}

// MARK: - ToolExecutionError

/// Lightweight error type for copilot tool failures. The message is surfaced
/// verbatim as the tool's result so the model can relay it to the user.
private struct ToolExecutionError: Error, LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        self.errorDescription = message
    }
}

// MARK: - Registrar

public enum CopilotTools {
    public static let allTools: [(tool: any ToolDefinition, category: ToolCategory)] = [
        (CaptureDeckTool(), .documents),
        (DesignDeckTool(), .documents),
        (RewriteSlidesTool(), .documents),
        (DirectEditTool(), .documents),
        (ReviewDocumentTool(), .documents),
        (EditWordCommentsTool(), .documents),
    ]

    public static func register(into registry: ToolRegistry) {
        registry.register(allTools)
    }
}
