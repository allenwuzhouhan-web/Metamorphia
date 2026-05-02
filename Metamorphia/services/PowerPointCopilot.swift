import AppKit
import Defaults
import Foundation

struct PowerPointRewriteRoute {
    let filePath: String?
    let commandContextBlock: String
    let systemPromptSuffix: String
    let shapeSnapshots: [Int: PowerPointShapeSnapshot]
}

struct PowerPointDesignRoute {
    let filePath: String?
    let commandContextBlock: String
    let systemPromptSuffix: String
    let restoreData: PowerPointRestoreData
    let shapeSnapshots: [Int: PowerPointShapeSnapshot]
    fileprivate let deckContext: PowerPointDeckContext?
    let deckRestoreData: [PowerPointRestoreData]
}

struct PowerPointDeckReviewSnapshot: Sendable, Hashable {
    let presentationTitle: String
    let filePath: String?
    let slideCount: Int
    let activeSlideIndex: Int
    let extractedText: String
}

struct PowerPointShapeSnapshot: Sendable, Hashable {
    let name: String
    let text: String
    let role: PowerPointShapeRole
}

struct PowerPointRewriteOutcome {
    let success: Bool
    let message: String
}

typealias PowerPointDirectEditOutcome = PowerPointRewriteOutcome

private struct PowerPointDirectEditCommand {
    let kind: PowerPointDirectEditKind
    let value: String
    let appleScriptValue: String
}

private struct PowerPointSlideContext {
    let presentationTitle: String
    let filePath: String?
    let slideIndex: Int
    let slideTitle: String?
    let shapes: [PowerPointSlideShape]
}

private struct PowerPointDeckContext {
    let presentationTitle: String
    let filePath: String?
    let activeSlideIndex: Int
    let slideCount: Int
    let slides: [PowerPointSlideContext]
}

private struct PowerPointSlideShape: Hashable {
    let index: Int
    let name: String
    let text: String
    let role: PowerPointShapeRole
    let left: Double
    let top: Double
    let width: Double
    let height: Double
    let fontName: String?
    let fontSize: Double?
    let bold: Bool?
    let italic: Bool?
    let underline: Bool?
    let alignment: Int?
    let fontColor: [Int]?
}

private struct PowerPointTextMutation {
    let shapeIndex: Int
    let shapeName: String
    let expectedText: String
    let newText: String
}

private struct PowerPointDesignLayout {
    let slideWidth: Double
    let slideHeight: Double
    let titleLeft: Double
    let titleTop: Double
    let titleWidth: Double
    let titleHeight: Double
    let bodyLeft: Double
    let bodyTop: Double
    let bodyWidth: Double
    let bodyHeight: Double
    let panelLeft: Double
    let panelTop: Double
    let panelWidth: Double
    let panelHeight: Double
    let accentLeft: Double
    let accentTop: Double
    let accentWidth: Double
    let accentHeight: Double
}

enum PowerPointRewritePreparation {
    case notPowerPointRewriteIntent
    case route(PowerPointRewriteRoute)
    case failure(String)
}

enum PowerPointDirectEditPreparation {
    case notPowerPointDirectEditIntent
    case result(PowerPointDirectEditResult)
    case failure(String)
}

enum PowerPointDesignPreparation {
    case notPowerPointDesignIntent
    case route(PowerPointDesignRoute)
    case failure(String)
}

private enum PowerPointSlideCaptureResult {
    case success(PowerPointSlideContext)
    case failure(String)
}

private enum PowerPointDeckCaptureResult {
    case success(PowerPointDeckContext)
    case failure(String)
}

enum PowerPointCopilot {
    private static let powerPointBundleID = "com.microsoft.Powerpoint"
    private static let maxPromptShapes = 24
    private static let maxPromptCharacters = 14_000
    private static let maxPromptCharactersPerShape = 1_500
    private static let maxDirectEditShapeSlots = 200
    private static let automationTimeoutSeconds: TimeInterval = 8

    private static var isPowerPointFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == powerPointBundleID
    }

    private static var isPowerPointOpen: Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: powerPointBundleID)
            .contains { !$0.isTerminated }
    }

    static func isDirectEditIntent(prompt: String) -> Bool {
        guard case .deterministic(let routedCommand) = PowerPointAutomationRouter.route(prompt: prompt),
              isCurrentSlideImmediateCommand(routedCommand) else {
            return false
        }
        return directEditCommand(for: prompt.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    static func performDirectEditIfNeeded(prompt: String) async -> PowerPointDirectEditPreparation {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notPowerPointDirectEditIntent }
        guard case .deterministic(let routedCommand) = PowerPointAutomationRouter.route(prompt: trimmed),
              isCurrentSlideImmediateCommand(routedCommand) else {
            return .notPowerPointDirectEditIntent
        }
        guard let command = directEditCommand(for: trimmed) else {
            return .notPowerPointDirectEditIntent
        }

        let script = directEditScript(command: command)
        do {
            let scriptResult = try await PowerPointExecutor.runJSON(
                script,
                as: PowerPointExecutor.JSONEnvelope.self,
                timeoutSeconds: automationTimeoutSeconds
            )
            if scriptResult.ok == false, let scriptError = scriptResult.error {
                return .failure(scriptError)
            }
            let appliedIndexes = scriptResult.applied ?? []
            let skippedIndexes = scriptResult.skipped ?? []
            let slideIndex = scriptResult.slideIndex ?? 0
            let presentationTitle = scriptResult.presentationTitle ?? ""
            let sourceFilePath = normalizedOptionalString(scriptResult.filePath)
            let slideTitle = normalizedOptionalString(scriptResult.slideTitle)
            let warnings = scriptResult.warnings ?? []
            let restoreData = PowerPointRestoreData(
                presentationTitle: presentationTitle.isEmpty ? "PowerPoint presentation" : presentationTitle,
                sourceFilePath: sourceFilePath,
                slideIndex: slideIndex,
                slideTitle: slideTitle,
                snapshots: scriptResult.snapshots ?? []
            )
            guard !appliedIndexes.isEmpty else {
                let shapeCount = scriptResult.shapeCount ?? 0
                let errorSummary = warnings.joined(separator: " ")
                let diagnosticSuffix = errorSummary.isEmpty
                    ? " PowerPoint reported \(shapeCount) shape(s) on the slide and skipped all of them."
                    : " PowerPoint reported \(shapeCount) shape(s). First errors: \(errorSummary)"
                return .failure("I couldn’t format any editable text on the current PowerPoint slide.\(diagnosticSuffix)")
            }

            let affectedCount = appliedIndexes.count
            let skippedCount = skippedIndexes.count
            let skippedSuffix = skippedCount == 0 ? "" : " \(skippedCount) text box(es) were skipped."
            let result = PowerPointDirectEditResult(
                presentationTitle: presentationTitle.isEmpty ? "PowerPoint presentation" : presentationTitle,
                sourceFilePath: sourceFilePath,
                slideIndex: slideIndex,
                slideTitle: slideTitle,
                summary: "Changed \(affectedCount) editable text box(es) on slide \(slideIndex) to \(command.value).\(skippedSuffix)",
                actions: [
                    PowerPointDirectEditAction(
                        targetScope: "All editable text on current slide",
                        property: command.kind,
                        value: command.value,
                        affectedShapeIndexes: appliedIndexes
                    )
                ],
                skippedShapeCount: skippedCount,
                warnings: warnings,
                restoreData: restoreData.snapshots.isEmpty ? nil : restoreData
            )
            return .result(result)
        } catch where (error as NSError).code == 408 {
            return .failure("PowerPoint did not finish the direct formatting command within \(Int(automationTimeoutSeconds)) seconds. I stopped waiting so the command bar will not stay stuck.")
        } catch {
            return .failure("I couldn’t update PowerPoint formatting: \(error.localizedDescription)")
        }
    }

    static func captureDeckReviewSnapshot() async -> PowerPointDeckReviewSnapshot? {
        let deck: PowerPointDeckContext
        do {
            let payload = try await runAppleScriptViaOSAScript(
                deckCaptureScript,
                timeoutSeconds: max(automationTimeoutSeconds, 18)
            )
            switch parseDeckPayload(payload) {
            case .success(let captured):
                deck = captured
            case .failure:
                return nil
            }
        } catch {
            return nil
        }

        let extractedText = deckReviewText(for: deck)
        guard !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PowerPointDeckReviewSnapshot(
            presentationTitle: deck.presentationTitle,
            filePath: deck.filePath,
            slideCount: deck.slideCount,
            activeSlideIndex: deck.activeSlideIndex,
            extractedText: extractedText
        )
    }

    private static func runAppleScriptViaOSAScript(
        _ script: String,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let scriptURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("metamorphia-ppt-review-\(UUID().uuidString).applescript")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let lock = NSLock()
            var stdoutData = Data()
            var stderrData = Data()
            var didResume = false

            func resumeOnce(_ result: Result<String, Error>) {
                lock.lock()
                guard !didResume else {
                    lock.unlock()
                    return
                }
                didResume = true
                lock.unlock()

                switch result {
                case .success(let output):
                    continuation.resume(returning: output)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [scriptURL.path]
            process.standardOutput = stdout
            process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock()
                stdoutData.append(chunk)
                lock.unlock()
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock()
                stderrData.append(chunk)
                lock.unlock()
            }
            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let finalStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                let finalStderr = stderr.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                stdoutData.append(finalStdout)
                stderrData.append(finalStderr)
                let output = String(data: stdoutData, encoding: .utf8) ?? ""
                let errorText = String(data: stderrData, encoding: .utf8) ?? ""
                lock.unlock()
                if process.terminationStatus == 0 {
                    resumeOnce(.success(output))
                } else {
                    resumeOnce(.failure(NSError(
                        domain: "PowerPointAutomation",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "osascript failed" : errorText]
                    )))
                }
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(error))
                return
            }

            Task.detached(priority: .userInitiated) {
                let nanoseconds = UInt64(max(timeoutSeconds, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                lock.lock()
                let alreadyResumed = didResume
                lock.unlock()
                guard !alreadyResumed else { return }
                if process.isRunning {
                    process.terminate()
                }
                resumeOnce(.failure(NSError(
                    domain: "PowerPointAutomation",
                    code: 408,
                    userInfo: [NSLocalizedDescriptionKey: "osascript timed out after \(timeoutSeconds) seconds"]
                )))
            }
        }
    }

    private static func parseDeckPayload(_ payload: String) -> PowerPointDeckCaptureResult {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("PowerPoint did not report an active deck. Click the slide canvas in PowerPoint, then ask again.")
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("PowerPoint returned deck data Metamorphia could not parse.")
        }
        let presentationTitle = object["presentationTitle"] as? String ?? ""
        let filePath = normalizedOptionalString(object["filePath"] as? String)
        let activeSlideIndex = object["activeSlideIndex"] as? Int ?? 1
        let slideCount = object["slideCount"] as? Int ?? 0
        let rawSlides = object["slides"] as? [[String: Any]] ?? []
        let slides = rawSlides.compactMap { slideObject -> PowerPointSlideContext? in
            let slideIndex = slideObject["slideIndex"] as? Int ?? 0
            guard slideIndex > 0 else { return nil }
            let rawShapes = slideObject["shapes"] as? [[String: Any]] ?? []
            let shapes = rawShapes.compactMap(parseShape).sorted {
                if abs($0.top - $1.top) > 8 { return $0.top < $1.top }
                return $0.left < $1.left
            }
            return PowerPointSlideContext(
                presentationTitle: presentationTitle,
                filePath: filePath,
                slideIndex: slideIndex,
                slideTitle: normalizedOptionalString(slideObject["slideTitle"] as? String),
                shapes: shapes
            )
        }
        guard !presentationTitle.isEmpty, slideCount > 0, !slides.isEmpty else {
            return .failure("PowerPoint did not return editable deck structure. Make sure the deck is open and active.")
        }
        return .success(PowerPointDeckContext(
            presentationTitle: presentationTitle,
            filePath: filePath,
            activeSlideIndex: activeSlideIndex,
            slideCount: slideCount,
            slides: slides
        ))
    }

    static func prepareRewriteRoute(prompt: String) async -> PowerPointRewritePreparation {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notPowerPointRewriteIntent }
        guard case .rewrite = PowerPointAutomationRouter.route(prompt: trimmed) else {
            return .notPowerPointRewriteIntent
        }

        let context: PowerPointSlideContext
        switch await captureCurrentSlide() {
        case .success(let captured):
            context = captured
        case .failure(let message):
            return .failure(message)
        }
        guard !context.shapes.isEmpty else {
            return .failure("The current PowerPoint slide does not have editable text boxes to rewrite.")
        }

        let promptShapes = cappedPromptShapes(context.shapes)
        let shapeLines = promptShapes.map { shape in
            """
            [shapeIndex=\(shape.index) role=\(shape.role.rawValue) name="\(shape.name)"]
            \(promptText(shape.text))
            [/shape]
            """
        }.joined(separator: "\n\n")
        let omittedCount = max(0, context.shapes.count - promptShapes.count)
        let omittedLine = omittedCount == 0 ? "" : "\n\n\(omittedCount) lower-priority text box(es) were omitted to keep the rewrite fast. Rewrite only the listed shapes."

        let contextBlock = """
        PowerPoint slide under rewrite:
        - Presentation: \(context.presentationTitle)
        - File path: \(context.filePath ?? "unavailable")
        - Slide index: \(context.slideIndex)
        - Slide title: \(context.slideTitle ?? "Untitled slide")
        - User request: \(trimmed)

        Editable text shapes on the current slide:
        \(shapeLines)\(omittedLine)
        """

        let systemPromptSuffix = """

        ## PowerPoint Current-Slide Rewrite Mode
        You are rewriting the user's current Microsoft PowerPoint slide.
        Rewrite text only. Do not add, remove, reorder, or redesign slides. Do not invent charts, images, or layout changes.
        Preserve the user's intent and make the slide fit the request. Prefer concise slide language over prose.
        Return replacements only for shapes that should change.
        Use the exact shapeIndex and shapeName from the supplied slide context.
        Do not return replacements for shapes not listed in the slide context.
        Keep replacementText suitable for the existing text box. Use line breaks for bullets when helpful.
        Start with a short human-readable summary paragraph.
        Then emit exactly one machine-readable block with no code fence:
        [PPT_REWRITE]
        {"presentationTitle":"\(escapeJSONString(context.presentationTitle))","sourceFilePath":"\(escapeJSONString(context.filePath ?? ""))","slideIndex":\(context.slideIndex),"slideTitle":"\(escapeJSONString(context.slideTitle ?? ""))","summary":"...","replacements":[{"shapeIndex":1,"shapeName":"...","role":"title|body|footer|other","originalText":"...","replacementText":"...","rationale":"..."}]}
        [/PPT_REWRITE]
        """

        return .route(PowerPointRewriteRoute(
            filePath: context.filePath,
            commandContextBlock: contextBlock,
            systemPromptSuffix: systemPromptSuffix,
            shapeSnapshots: Dictionary(
                uniqueKeysWithValues: promptShapes.map {
                    ($0.index, PowerPointShapeSnapshot(name: $0.name, text: $0.text, role: $0.role))
                }
            )
        ))
    }

    static func prepareDesignRoute(prompt: String) async -> PowerPointDesignPreparation {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notPowerPointDesignIntent }
        guard case .rewrite(.design(let scope, _)) = PowerPointAutomationRouter.route(prompt: trimmed),
              isDesignIntent(trimmed) else { return .notPowerPointDesignIntent }

        if scope == .wholeDeck {
            return await prepareDeckDesignRoute(prompt: trimmed)
        }

        let context: PowerPointSlideContext
        switch await captureCurrentSlide() {
        case .success(let captured):
            context = captured
        case .failure(let message):
            return .failure(message)
        }
        guard !context.shapes.isEmpty else {
            return .failure("The current PowerPoint slide does not have editable text boxes to design around.")
        }

        let promptShapes = cappedPromptShapes(context.shapes)
        let shapeLines = promptShapes.map { shape in
            """
            [shapeIndex=\(shape.index) role=\(shape.role.rawValue) name="\(shape.name)" x=\(Int(shape.left)) y=\(Int(shape.top)) w=\(Int(shape.width)) h=\(Int(shape.height))]
            \(promptText(shape.text))
            [/shape]
            """
        }.joined(separator: "\n\n")

        let restoreData = restoreData(for: context)
        let tasteProfileBlock = await presentationTastePromptBlock()
        let contextBlock = """
        PowerPoint slide under design review:
        - Presentation: \(context.presentationTitle)
        - File path: \(context.filePath ?? "unavailable")
        - Slide index: \(context.slideIndex)
        - Slide title: \(context.slideTitle ?? "Untitled slide")
        - User request: \(trimmed)
        \(tasteProfileBlock)

        Editable text shapes on the current slide:
        \(shapeLines)
        """

        let systemPromptSuffix = """

        ## PowerPoint Current-Slide Design Mode
        You are creating a visual design plan for the user's current Microsoft PowerPoint slide.
        Your job is to make the slide noticeably better, not merely recolor it.

        Design principles to apply:
        - Kill walls of text. If a body shape is dense prose, preserve its meaning but turn it into 2-4 skim-friendly blocks with short headings.
        - Create hierarchy: one dominant title or key idea, supporting text clearly secondary, and enough whitespace to breathe.
        - Use contrast deliberately. Pick one dominant content-informed color, one quiet supporting tone, and one sharp accent.
        - Respect existing logos, school headers, footers, and master artwork. Put new structure below existing header/logo areas.
        - Every design should include a visible structure: panel, side rail, card field, or editorial feature block. Avoid title-underlines.

        Choose exactly one recipe:
        - Editorial feature: strong title, inset content panel, accent rail, structured body blocks.
        - Insight cards: 3-4 short content blocks that read like cards inside one text box.
        - Contrast panel: light content panel on a branded/dark accent field.
        - Definition spotlight: compact definition plus purpose/process blocks.

        The app can apply: text replacement for listed editable shapes, typography, colors, alignment, whitespace/layout geometry, and simple PowerPoint shape motifs. Do not propose images, charts, slide reordering, or free-form scripts.
        Use textBlocks when the existing prose should be chunked for design. Keep title text mostly intact unless it is weak or missing.
        Use the exact shapeIndex and shapeName from the supplied slide context.
        Return a preview plan only for the current slide.
        Start with a short human-readable summary paragraph.
        Then emit exactly one machine-readable block with no code fence:
        [PPT_DESIGN]
        {"presentationTitle":"\(escapeJSONString(context.presentationTitle))","sourceFilePath":"\(escapeJSONString(context.filePath ?? ""))","slideIndex":\(context.slideIndex),"slideTitle":"\(escapeJSONString(context.slideTitle ?? ""))","summary":"...","recipe":"Editorial feature|Insight cards|Contrast panel|Definition spotlight","palette":{"name":"...","primary":"1E2761","secondary":"CADCFC","accent":"F96167","background":"FFFFFF","text":"111827","mutedText":"4B5563"},"typography":{"titleFont":"Aptos Display","bodyFont":"Aptos","titleSize":40,"bodySize":16},"motif":"short motif name","operations":[{"kind":"palette|typography|content|hierarchy|alignment|motif|whitespace","target":"...","detail":"..."}],"textBlocks":[{"shapeIndex":2,"shapeName":"...","role":"body","originalText":"exact original text from context","replacementText":"Short heading\\nConcise supporting line.\\n\\nShort heading\\nConcise supporting line.","rationale":"Breaks dense prose into scanable blocks."}]}
        [/PPT_DESIGN]
        """

        return .route(PowerPointDesignRoute(
            filePath: context.filePath,
            commandContextBlock: contextBlock,
            systemPromptSuffix: systemPromptSuffix,
            restoreData: restoreData,
            shapeSnapshots: Dictionary(
                uniqueKeysWithValues: promptShapes.map {
                    ($0.index, PowerPointShapeSnapshot(name: $0.name, text: $0.text, role: $0.role))
                }
            ),
            deckContext: nil,
            deckRestoreData: []
        ))
    }

    private static func prepareDeckDesignRoute(prompt trimmed: String) async -> PowerPointDesignPreparation {
        let deck: PowerPointDeckContext
        switch await captureDeck() {
        case .success(let captured):
            deck = captured
        case .failure(let message):
            return .failure(message)
        }

        let slides = Array(deck.slides.prefix(18))
        let slideLines = slides.map { slide in
            let title = slide.slideTitle ?? slide.shapes.first(where: { $0.role == .title })?.text ?? "Untitled"
            let shapeSummary = slide.shapes.prefix(8).map { shape in
                "#\(shape.index) \(shape.role.rawValue) \(Int(shape.left)),\(Int(shape.top)) \(Int(shape.width))x\(Int(shape.height)) \(shape.fontName ?? "font?") \(Int((shape.fontSize ?? 0).rounded()))pt"
            }.joined(separator: "; ")
            return "Slide \(slide.slideIndex): \(promptText(title))\nShapes: \(shapeSummary)"
        }.joined(separator: "\n\n")
        let omitted = deck.slideCount > slides.count
            ? "\n\n\(deck.slideCount - slides.count) additional slide(s) were omitted from prompt detail but should receive the same design language."
            : ""
        let tasteProfileBlock = await presentationTastePromptBlock()
        let restoreItems = deck.slides.map(restoreData(for:))

        let contextBlock = """
        PowerPoint whole-deck design review:
        - Presentation: \(deck.presentationTitle)
        - File path: \(deck.filePath ?? "unavailable")
        - Slide count: \(deck.slideCount)
        - Active slide: \(deck.activeSlideIndex)
        - User request: \(trimmed)
        \(tasteProfileBlock)

        Deck slide/style summary:
        \(slideLines)\(omitted)
        """

        let systemPromptSuffix = """

        ## PowerPoint Whole-Deck Design Mode
        You are creating a visual design plan for the user's entire open Microsoft PowerPoint deck.
        Apply the user's learned design language when provided. Keep the existing deck content and slide order.
        The app can apply only controlled deck-wide edits: typography, text colors, alignment, safe layout normalization, backgrounds, and restrained geometric motifs. Do not propose images, charts, slide insertion/deletion, or free-form scripts.
        Design for consistency across all slides: one palette, one title/body font pairing, stable spacing rhythm, and recurring motif.
        Start with a short human-readable summary paragraph.
        Then emit exactly one machine-readable block with no code fence:
        [PPT_DESIGN]
        {"presentationTitle":"\(escapeJSONString(deck.presentationTitle))","sourceFilePath":"\(escapeJSONString(deck.filePath ?? ""))","slideIndex":\(deck.activeSlideIndex),"slideTitle":"","scope":"wholeDeck","slideCount":\(deck.slideCount),"summary":"...","recipe":"Editorial feature|Insight cards|Contrast panel|Definition spotlight","palette":{"name":"...","primary":"1E2761","secondary":"CADCFC","accent":"F96167","background":"FFFFFF","text":"111827","mutedText":"4B5563"},"typography":{"titleFont":"Aptos Display","bodyFont":"Aptos","titleSize":40,"bodySize":16},"motif":"short recurring motif name","operations":[{"kind":"palette|typography|hierarchy|alignment|motif|whitespace","target":"Whole deck","detail":"..."}],"textBlocks":[]}
        [/PPT_DESIGN]
        """

        let promptShapes = deck.slides.flatMap { cappedPromptShapes($0.shapes) }
        return .route(PowerPointDesignRoute(
            filePath: deck.filePath,
            commandContextBlock: contextBlock,
            systemPromptSuffix: systemPromptSuffix,
            restoreData: restoreItems.first ?? PowerPointRestoreData(
                presentationTitle: deck.presentationTitle,
                sourceFilePath: deck.filePath,
                slideIndex: deck.activeSlideIndex,
                slideTitle: nil,
                snapshots: []
            ),
            shapeSnapshots: Dictionary(
                uniqueKeysWithValues: promptShapes.enumerated().map { offset, shape in
                    (offset + 1, PowerPointShapeSnapshot(name: shape.name, text: shape.text, role: shape.role))
                }
            ),
            deckContext: deck,
            deckRestoreData: restoreItems
        ))
    }

    static func resolvedRewrite(
        _ rewrite: PowerPointRewriteResult,
        route: PowerPointRewriteRoute
    ) -> PowerPointRewriteResult {
        var seen = Set<Int>()
        let replacements = rewrite.replacements.compactMap { replacement -> PowerPointRewriteReplacement? in
            guard !seen.contains(replacement.shapeIndex),
                  let snapshot = route.shapeSnapshots[replacement.shapeIndex],
                  let replacementText = replacement.trimmedReplacementText else {
                return nil
            }
            guard !textsEquivalent(snapshot.text, replacementText) else { return nil }
            seen.insert(replacement.shapeIndex)
            return PowerPointRewriteReplacement(
                shapeIndex: replacement.shapeIndex,
                shapeName: snapshot.name,
                role: snapshot.role,
                originalText: snapshot.text,
                replacementText: replacementText,
                rationale: replacement.rationale
            )
        }

        return PowerPointRewriteResult(
            presentationTitle: rewrite.presentationTitle,
            sourceFilePath: route.filePath,
            slideIndex: rewrite.slideIndex,
            slideTitle: rewrite.slideTitle,
            summary: rewrite.summary,
            replacements: replacements
        )
    }

    static func resolutionFailureMessage(
        for rewrite: PowerPointRewriteResult,
        route: PowerPointRewriteRoute
    ) -> String {
        let available = route.shapeSnapshots.keys.sorted().map(String.init).joined(separator: ", ")
        let proposed = rewrite.replacements.map { replacement in
            let textState = replacement.trimmedReplacementText == nil ? "empty text" : "has text"
            return "#\(replacement.shapeIndex) (\(textState))"
        }.joined(separator: ", ")

        if rewrite.replacements.isEmpty {
            return """
            I drafted a PowerPoint rewrite, but I couldn't find any structured replacement edits in the model response. Re-run the rewrite on the current slide.
            """
        }

        return """
        I drafted a PowerPoint rewrite, but none of the proposed edits matched the captured slide text.

        Captured editable shape indexes: \(available.isEmpty ? "none" : available)
        Proposed edit indexes: \(proposed)

        Re-run the rewrite on the current slide.
        """
    }

    static func resolvedDesign(
        _ design: PowerPointDesignResult,
        route: PowerPointDesignRoute
    ) -> PowerPointDesignResult {
        let palette = PowerPointDesignPalette(
            name: design.palette.name,
            primary: normalizedHexColor(design.palette.primary, fallback: "1E2761"),
            secondary: normalizedHexColor(design.palette.secondary, fallback: "CADCFC"),
            accent: normalizedHexColor(design.palette.accent, fallback: "F96167"),
            background: normalizedHexColor(design.palette.background, fallback: "FFFFFF"),
            text: normalizedHexColor(design.palette.text, fallback: "111827"),
            mutedText: normalizedHexColor(design.palette.mutedText, fallback: "4B5563")
        )
        let typography = PowerPointDesignTypography(
            titleFont: allowedDesignFont(design.typography.titleFont, fallback: "Aptos Display"),
            bodyFont: allowedDesignFont(design.typography.bodyFont, fallback: "Aptos"),
            titleSize: min(max(design.typography.titleSize, 30), 48),
            bodySize: min(max(design.typography.bodySize, 12), 22)
        )
        let operations = design.operations.isEmpty ? [
            PowerPointDesignOperation(kind: .palette, target: "Current slide", detail: "Apply a stronger color hierarchy."),
            PowerPointDesignOperation(kind: .typography, target: "Title and body", detail: "Increase size contrast and use a cleaner font pairing."),
            PowerPointDesignOperation(kind: .content, target: "Dense body text", detail: "Break prose into short, scanable content blocks when needed."),
            PowerPointDesignOperation(kind: .motif, target: "Slide edge", detail: "Add a restrained accent motif.")
        ] : design.operations
        let textBlocks = resolvedDesignTextBlocks(design.textBlocks, route: route)

        return PowerPointDesignResult(
            presentationTitle: design.presentationTitle,
            sourceFilePath: route.filePath,
            slideIndex: route.deckContext?.activeSlideIndex ?? design.slideIndex,
            slideTitle: route.deckContext == nil ? design.slideTitle : nil,
            scope: route.deckContext == nil ? .currentSlide : .wholeDeck,
            slideCount: route.deckContext?.slideCount,
            slidePreviews: route.deckContext.map(deckPreviews(for:)),
            summary: design.summary,
            recipe: resolvedDesignRecipe(design.recipe),
            palette: palette,
            typography: typography,
            motif: design.motif,
            operations: operations,
            textBlocks: route.deckContext == nil ? textBlocks : [],
            restoreData: route.restoreData,
            deckRestoreData: route.deckRestoreData.isEmpty ? nil : route.deckRestoreData
        )
    }

    static func performAction(
        _ action: PowerPointRewriteAction,
        rewrite: PowerPointRewriteResult
    ) async -> PowerPointRewriteOutcome {
        switch action {
        case .jump:
            return await jump(to: rewrite)
        case .apply:
            return await apply(rewrite: rewrite, useOriginals: false)
        case .restore:
            return await apply(rewrite: rewrite, useOriginals: true)
        }
    }

    static func performDirectEditAction(
        _ action: PowerPointDirectEditControlAction,
        result: PowerPointDirectEditResult
    ) async -> PowerPointDirectEditOutcome {
        switch action {
        case .jump:
            return await jump(toSlide: result.slideIndex, presentationTitle: result.presentationTitle)
        case .restore:
            return await restoreDirectEdit(result)
        case .undo:
            return await undoLastPowerPointEdit(onSlide: result.slideIndex)
        }
    }

    static func performDesignAction(
        _ action: PowerPointDesignAction,
        design: PowerPointDesignResult
    ) async -> PowerPointRewriteOutcome {
        switch action {
        case .jump:
            return await jump(toSlide: design.slideIndex, presentationTitle: design.presentationTitle)
        case .apply:
            if design.isWholeDeck { return await applyDeckDesign(design) }
            return await applyDesign(design)
        case .restore:
            if design.isWholeDeck { return await restoreDeckDesign(design) }
            return await restoreDesign(design)
        case .undo:
            return await undoLastPowerPointEdit(onSlide: design.slideIndex)
        }
    }

    private static func directEditCommand(for prompt: String) -> PowerPointDirectEditCommand? {
        let normalized = prompt.lowercased()
        guard isCurrentSlideFormattingIntent(normalized) else { return nil }
        guard mentionsAllTextScope(normalized) else { return nil }

        if let color = directTextColor(from: normalized),
           isTextColorIntent(normalized) || normalized.contains("text") || normalized.contains("font") {
            return PowerPointDirectEditCommand(
                kind: .textColor,
                value: color.name,
                appleScriptValue: color.appleScriptValue
            )
        }

        if let fontSize = directFontSize(from: normalized) {
            return PowerPointDirectEditCommand(
                kind: .fontSize,
                value: "\(fontSize) pt",
                appleScriptValue: "\(fontSize)"
            )
        }

        if normalized.contains("bold") {
            let enabled = !(normalized.contains("unbold") ||
                normalized.contains("not bold") ||
                normalized.contains("remove bold"))
            return PowerPointDirectEditCommand(
                kind: .bold,
                value: enabled ? "on" : "off",
                appleScriptValue: enabled ? "true" : "false"
            )
        }

        if normalized.contains("italic") || normalized.contains("italics") {
            let enabled = !(normalized.contains("unitalic") ||
                normalized.contains("not italic") ||
                normalized.contains("remove italic") ||
                normalized.contains("remove italics"))
            return PowerPointDirectEditCommand(
                kind: .italic,
                value: enabled ? "on" : "off",
                appleScriptValue: enabled ? "true" : "false"
            )
        }

        if normalized.contains("underline") {
            let enabled = !(normalized.contains("remove underline") ||
                normalized.contains("not underlined") ||
                normalized.contains("no underline"))
            return PowerPointDirectEditCommand(
                kind: .underline,
                value: enabled ? "on" : "off",
                appleScriptValue: enabled ? "true" : "false"
            )
        }

        if let alignment = directAlignment(from: normalized) {
            return alignment
        }

        return nil
    }

    private static func isCurrentSlideImmediateCommand(_ command: PowerPointCommand) -> Bool {
        guard !command.requiresPreview else { return false }
        switch command {
        case .textFormatting(let scope, _, _):
            return scope == .currentSlide
        case .slideBackground(let scope, _):
            return scope == .currentSlide
        case .rewrite, .design, .review, .clarification:
            return false
        }
    }

    private static func isTextColorIntent(_ normalized: String) -> Bool {
        (normalized.contains("color") || normalized.contains("colour")) &&
            (normalized.contains("text") || normalized.contains("font"))
    }

    private static func directTextColor(from normalized: String) -> (name: String, appleScriptValue: String)? {
        let colors: [(tokens: [String], name: String, rgb16: (Int, Int, Int))] = [
            (["lime green", "lime"], "lime green", (0, 65535, 0)),
            (["black"], "black", (0, 0, 0)),
            (["white"], "white", (65535, 65535, 65535)),
            (["red"], "red", (65535, 0, 0)),
            (["green"], "green", (0, 32768, 0)),
            (["blue"], "blue", (0, 0, 65535)),
            (["yellow"], "yellow", (65535, 65535, 0)),
            (["orange"], "orange", (65535, 32768, 0)),
            (["purple"], "purple", (32768, 0, 32768)),
            (["gray", "grey"], "gray", (32768, 32768, 32768))
        ]
        guard let match = colors.first(where: { color in
            color.tokens.contains { normalized.contains($0) }
        }) else {
            return nil
        }
        return (
            match.name,
            "{\(match.rgb16.0), \(match.rgb16.1), \(match.rgb16.2)}"
        )
    }

    private static func directFontSize(from normalized: String) -> Int? {
        let patterns = [
            #"font size(?:\D{0,20})(\d{1,3})"#,
            #"text size(?:\D{0,20})(\d{1,3})"#,
            #"(\d{1,3})\s*(?:pt|point|points)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range),
                  match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: normalized),
                  let value = Int(normalized[swiftRange]),
                  (4...200).contains(value) else {
                continue
            }
            return value
        }
        return nil
    }

    private static func directAlignment(from normalized: String) -> PowerPointDirectEditCommand? {
        let candidates: [(tokens: [String], value: String, appleScriptValue: String)] = [
            (["align left", "left align", "left aligned"], "left", "1"),
            (["align center", "center align", "centered", "centre align", "align centre"], "center", "2"),
            (["align right", "right align", "right aligned"], "right", "3"),
            (["justify"], "justified", "4")
        ]
        guard let match = candidates.first(where: { candidate in
            candidate.tokens.contains { normalized.contains($0) }
        }) else {
            return nil
        }
        return PowerPointDirectEditCommand(
            kind: .alignment,
            value: match.value,
            appleScriptValue: match.appleScriptValue
        )
    }

    private static func isCurrentSlideFormattingIntent(_ normalized: String) -> Bool {
        let currentTargets = [
            "this slide", "current slide", "open slide", "selected slide",
            "active slide", "slide's", "slide’s"
        ]
        let formattingTerms = [
            "color", "colour", "font size", "bold", "italic", "align",
            "underline", "alignment", "background", "fill", "outline"
        ]
        let mentionsCurrentSlide = currentTargets.contains { normalized.contains($0) }
        let frontmostPowerPoint = isPowerPointFrontmost
        let openPowerPoint = isPowerPointOpen
        let mentionsPowerPointThing = [
            "slide", "slides", "deck", "presentation", "powerpoint", "ppt", "pptx"
        ].contains { normalized.contains($0) }
        let hasFormattingTerm = formattingTerms.contains { normalized.contains($0) } ||
            directTextColor(from: normalized) != nil
        return hasFormattingTerm &&
            (mentionsCurrentSlide || frontmostPowerPoint || (openPowerPoint && mentionsPowerPointThing))
    }

    private static func mentionsAllTextScope(_ normalized: String) -> Bool {
        let allTextScopes = [
            "all text", "every text", "all editable text", "all the text",
            "text on this slide", "text on the current slide",
            "this slide's text", "this slide’s text"
        ]
        return allTextScopes.contains { normalized.contains($0) }
    }

    private static func isDesignIntent(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let designTerms = [
            "design", "redesign", "make it look better", "make this look better",
            "make this slide look better", "make the slide look better",
            "improve the design", "better layout", "visual polish", "polish the design",
            "make it prettier", "make it more professional", "improve visuals",
            "style this slide", "restyle this slide", "style this deck",
            "restyle this deck", "design language"
        ]
        let targetTerms = [
            "this slide", "current slide", "open slide", "selected slide",
            "this powerpoint", "current powerpoint", "this presentation",
            "this deck", "current deck", "open deck", "deck", "slide"
        ]
        let currentOpenTerms = ["this", "current", "open", "selected", "active"]
        let frontmostPowerPoint = isPowerPointFrontmost
        let openPowerPoint = isPowerPointOpen
        return designTerms.contains { normalized.contains($0) } &&
            (
                targetTerms.contains { normalized.contains($0) } ||
                frontmostPowerPoint ||
                (openPowerPoint && currentOpenTerms.contains { normalized.contains($0) })
            )
    }

    private static func isRewriteIntent(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        if normalized.contains("presentation skills") ||
            normalized.contains("public speaking") ||
            normalized.contains("speaker notes") {
            return false
        }

        let creationTerms = ["create", "build", "generate", "make a deck", "make me a deck", "make slides"]
        if creationTerms.contains(where: { normalized.contains($0) }) &&
            !normalized.contains("current") &&
            !normalized.contains("this slide") {
            return false
        }

        let rewriteVerbs = [
            "rewrite", "revise", "improve", "polish", "tighten", "simplify",
            "shorten", "condense", "clean up", "sharpen", "make this slide",
            "make the slide", "make my slide", "board-ready", "executive-ready",
            "more concise", "more professional"
        ]
        let explicitCurrentTargets = [
            "this slide", "current slide", "open slide", "selected slide",
            "this powerpoint", "current powerpoint", "open powerpoint",
            "this deck", "current deck", "open deck",
            "this presentation", "current presentation", "open presentation"
        ]
        let hasRewriteVerb = rewriteVerbs.contains { normalized.contains($0) }
        let mentionsCurrentTarget = explicitCurrentTargets.contains { normalized.contains($0) }
        let frontmostPowerPoint = isPowerPointFrontmost
        let openPowerPoint = isPowerPointOpen
        let mentionsCurrentThing = normalized.contains("this") ||
            normalized.contains("current") ||
            normalized.contains("open") ||
            normalized.contains("selected")
        return hasRewriteVerb &&
            (mentionsCurrentTarget || ((frontmostPowerPoint || openPowerPoint) && mentionsCurrentThing))
    }

    private static func captureCurrentSlide() async -> PowerPointSlideCaptureResult {
        do {
            let payload = try await PowerPointExecutor.runText(
                currentSlideCaptureScript,
                timeoutSeconds: automationTimeoutSeconds
            )
            guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("PowerPoint did not report an active slide. Click the slide canvas in PowerPoint, then ask again.")
            }
            guard let data = payload.data(using: .utf8) else {
                return .failure("PowerPoint returned slide data that was not valid UTF-8.")
            }
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: data)
            } catch {
                return .failure("PowerPoint returned slide data Metamorphia could not parse: \(error.localizedDescription)")
            }
            guard let object = parsed as? [String: Any] else {
                return .failure("PowerPoint returned slide data in an unexpected format.")
            }

            let presentationTitle = object["presentationTitle"] as? String ?? ""
            let filePath = normalizedOptionalString(object["filePath"] as? String)
            let slideIndex = object["slideIndex"] as? Int ?? 0
            let slideTitle = normalizedOptionalString(object["slideTitle"] as? String)
            let rawShapes = object["shapes"] as? [[String: Any]] ?? []

            let shapes = rawShapes.compactMap { raw -> PowerPointSlideShape? in
                guard let index = raw["index"] as? Int,
                      let text = raw["text"] as? String else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let name = raw["name"] as? String ?? ""
                return PowerPointSlideShape(
                    index: index,
                    name: name,
                    text: text,
                    role: inferRole(index: index, name: name, text: text),
                    left: raw["left"] as? Double ?? 0,
                    top: raw["top"] as? Double ?? 0,
                    width: raw["width"] as? Double ?? 0,
                    height: raw["height"] as? Double ?? 0,
                    fontName: normalizedOptionalString(raw["fontName"] as? String),
                    fontSize: doubleValue(raw["fontSize"]),
                    bold: boolValue(raw["bold"]),
                    italic: boolValue(raw["italic"]),
                    underline: boolValue(raw["underline"]),
                    alignment: intValue(raw["alignment"]),
                    fontColor: intArray(raw["fontColor"])
                )
            }.sorted {
                if abs($0.top - $1.top) > 8 { return $0.top < $1.top }
                return $0.left < $1.left
            }

            guard !presentationTitle.isEmpty else {
                return .failure("PowerPoint returned an empty presentation title. Make sure the deck is open and active.")
            }
            guard slideIndex > 0 else {
                return .failure("PowerPoint did not report a valid active slide. Click the slide canvas in PowerPoint, then ask again.")
            }
            return .success(
                PowerPointSlideContext(
                    presentationTitle: presentationTitle,
                    filePath: filePath,
                    slideIndex: slideIndex,
                    slideTitle: slideTitle,
                    shapes: shapes
                )
            )
        } catch where (error as NSError).code == 408 {
            return .failure("PowerPoint did not finish reading the current slide within \(Int(automationTimeoutSeconds)) seconds. I stopped waiting so the command bar will not stay stuck.")
        } catch {
            return .failure("""
            PowerPoint slide capture failed: \(error.localizedDescription)

            Check System Settings -> Privacy & Security -> Automation and allow Metamorphia to control Microsoft PowerPoint.
            """)
        }
    }

    private static func captureDeck() async -> PowerPointDeckCaptureResult {
        do {
            let payload = try await PowerPointExecutor.runText(
                deckCaptureScript,
                timeoutSeconds: max(automationTimeoutSeconds, 18)
            )
            guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("PowerPoint did not report an active deck. Click the slide canvas in PowerPoint, then ask again.")
            }
            guard let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("PowerPoint returned deck data Metamorphia could not parse.")
            }
            let presentationTitle = object["presentationTitle"] as? String ?? ""
            let filePath = normalizedOptionalString(object["filePath"] as? String)
            let activeSlideIndex = object["activeSlideIndex"] as? Int ?? 1
            let slideCount = object["slideCount"] as? Int ?? 0
            let rawSlides = object["slides"] as? [[String: Any]] ?? []
            let slides = rawSlides.compactMap { slideObject -> PowerPointSlideContext? in
                let slideIndex = slideObject["slideIndex"] as? Int ?? 0
                guard slideIndex > 0 else { return nil }
                let rawShapes = slideObject["shapes"] as? [[String: Any]] ?? []
                let shapes = rawShapes.compactMap(parseShape).sorted {
                    if abs($0.top - $1.top) > 8 { return $0.top < $1.top }
                    return $0.left < $1.left
                }
                return PowerPointSlideContext(
                    presentationTitle: presentationTitle,
                    filePath: filePath,
                    slideIndex: slideIndex,
                    slideTitle: normalizedOptionalString(slideObject["slideTitle"] as? String),
                    shapes: shapes
                )
            }
            guard !presentationTitle.isEmpty, slideCount > 0, !slides.isEmpty else {
                return .failure("PowerPoint did not return editable deck structure. Make sure the deck is open and active.")
            }
            return .success(PowerPointDeckContext(
                presentationTitle: presentationTitle,
                filePath: filePath,
                activeSlideIndex: activeSlideIndex,
                slideCount: slideCount,
                slides: slides
            ))
        } catch where (error as NSError).code == 408 {
            return .failure("PowerPoint did not finish reading the deck within 18 seconds. I stopped waiting so the command bar will not stay stuck.")
        } catch {
            return .failure("""
            PowerPoint deck capture failed: \(error.localizedDescription)

            Check System Settings -> Privacy & Security -> Automation and allow Metamorphia to control Microsoft PowerPoint.
            """)
        }
    }

    private static func parseShape(_ raw: [String: Any]) -> PowerPointSlideShape? {
        guard let index = raw["index"] as? Int,
              let text = raw["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = raw["name"] as? String ?? ""
        return PowerPointSlideShape(
            index: index,
            name: name,
            text: text,
            role: inferRole(index: index, name: name, text: text),
            left: raw["left"] as? Double ?? 0,
            top: raw["top"] as? Double ?? 0,
            width: raw["width"] as? Double ?? 0,
            height: raw["height"] as? Double ?? 0,
            fontName: normalizedOptionalString(raw["fontName"] as? String),
            fontSize: doubleValue(raw["fontSize"]),
            bold: boolValue(raw["bold"]),
            italic: boolValue(raw["italic"]),
            underline: boolValue(raw["underline"]),
            alignment: intValue(raw["alignment"]),
            fontColor: intArray(raw["fontColor"])
        )
    }

    private static func restoreDirectEdit(_ result: PowerPointDirectEditResult) async -> PowerPointDirectEditOutcome {
        guard let restoreData = result.restoreData,
              !restoreData.snapshots.isEmpty else {
            return await undoLastPowerPointEdit(onSlide: result.slideIndex)
        }

        let script = restoreDirectEditScript(restoreData)
        do {
            let scriptResult = try await PowerPointExecutor.runJSON(
                script,
                as: PowerPointExecutor.JSONEnvelope.self,
                timeoutSeconds: automationTimeoutSeconds
            )
            if scriptResult.ok == false, let scriptError = scriptResult.error {
                return PowerPointRewriteOutcome(success: false, message: scriptError)
            }
            let restored = scriptResult.applied ?? []
            guard !restored.isEmpty else {
                return PowerPointRewriteOutcome(
                    success: false,
                    message: "I couldn’t restore any PowerPoint text formatting. Use Undo as a fallback."
                )
            }
            let skipped = scriptResult.skipped ?? []
            let skippedNote = skipped.isEmpty ? "" : " \(skipped.count) text box(es) need manual review."
            return PowerPointRewriteOutcome(
                success: skipped.isEmpty,
                message: "Restored \(restored.count) PowerPoint text box(es) on slide \(restoreData.slideIndex).\(skippedNote)"
            )
        } catch where (error as NSError).code == 408 {
            return PowerPointRewriteOutcome(
                success: false,
                message: "PowerPoint did not finish restoring the edit within \(Int(automationTimeoutSeconds)) seconds."
            )
        } catch {
            return PowerPointRewriteOutcome(
                success: false,
                message: "I couldn’t restore the PowerPoint edit: \(error.localizedDescription)"
            )
        }
    }

    private static func applyDesign(_ design: PowerPointDesignResult) async -> PowerPointRewriteOutcome {
        let current: PowerPointSlideContext
        switch await captureCurrentSlide() {
        case .success(let captured):
            current = captured
        case .failure(let message):
            return PowerPointRewriteOutcome(success: false, message: message)
        }
        guard matches(current: current, design: design) else {
            return PowerPointRewriteOutcome(success: false, message: "The active PowerPoint slide no longer matches this design preview. Re-run the design pass on the current slide.")
        }

        let script = applyDesignScript(design: design, context: current)
        do {
            let result = try await PowerPointExecutor.runJSON(
                script,
                as: PowerPointExecutor.JSONEnvelope.self,
                timeoutSeconds: automationTimeoutSeconds
            )
            if result.ok == false, let scriptError = result.error {
                return PowerPointRewriteOutcome(success: false, message: scriptError)
            }
            let applied = result.applied ?? []
            guard !applied.isEmpty else {
                return PowerPointRewriteOutcome(success: false, message: "I couldn’t apply the PowerPoint design plan to any editable text boxes.")
            }
            let skipped = result.skipped ?? []
            let skippedNote = skipped.isEmpty ? "" : " \(skipped.count) text box(es) need manual review."
            return PowerPointRewriteOutcome(
                success: skipped.isEmpty,
                message: "Applied design polish to \(applied.count) text box(es) on slide \(design.slideIndex).\(skippedNote)"
            )
        } catch where (error as NSError).code == 408 {
            return PowerPointRewriteOutcome(success: false, message: "PowerPoint did not finish the design command within \(Int(automationTimeoutSeconds)) seconds.")
        } catch {
            return PowerPointRewriteOutcome(success: false, message: "I couldn’t apply the PowerPoint design plan: \(error.localizedDescription)")
        }
    }

    private static func restoreDesign(_ design: PowerPointDesignResult) async -> PowerPointRewriteOutcome {
        guard let restoreData = design.restoreData,
              !restoreData.snapshots.isEmpty else {
            return await undoLastPowerPointEdit(onSlide: design.slideIndex)
        }

        let script = restoreDirectEditScript(restoreData)
        do {
            let result = try await PowerPointExecutor.runJSON(
                script,
                as: PowerPointExecutor.JSONEnvelope.self,
                timeoutSeconds: automationTimeoutSeconds
            )
            let restored = result.applied ?? []
            guard !restored.isEmpty else {
                return PowerPointRewriteOutcome(success: false, message: "I couldn’t restore the design changes. Use Undo as a fallback.")
            }
            let skipped = result.skipped ?? []
            let skippedNote = skipped.isEmpty ? "" : " \(skipped.count) text box(es) need manual review."
            return PowerPointRewriteOutcome(
                success: skipped.isEmpty,
                message: "Restored \(restored.count) text box(es) from the design preview on slide \(design.slideIndex).\(skippedNote)"
            )
        } catch where (error as NSError).code == 408 {
            return PowerPointRewriteOutcome(success: false, message: "PowerPoint did not finish restoring the design changes within \(Int(automationTimeoutSeconds)) seconds.")
        } catch {
            return PowerPointRewriteOutcome(success: false, message: "I couldn’t restore the design changes: \(error.localizedDescription)")
        }
    }

    private static func applyDeckDesign(_ design: PowerPointDesignResult) async -> PowerPointRewriteOutcome {
        let deck: PowerPointDeckContext
        switch await captureDeck() {
        case .success(let captured):
            deck = captured
        case .failure(let message):
            return PowerPointRewriteOutcome(success: false, message: message)
        }
        guard matches(deck: deck, design: design) else {
            return PowerPointRewriteOutcome(success: false, message: "The active PowerPoint deck no longer matches this design preview. Re-run the whole-deck design pass.")
        }

        do {
            let result = try await PowerPointExecutor.runJSON(
                applyDeckDesignScript(design),
                as: PowerPointExecutor.JSONEnvelope.self,
                timeoutSeconds: max(automationTimeoutSeconds, 20)
            )
            if result.ok == false, let scriptError = result.error {
                return PowerPointRewriteOutcome(success: false, message: scriptError)
            }
            let applied = result.applied ?? []
            guard !applied.isEmpty else {
                return PowerPointRewriteOutcome(success: false, message: "I couldn’t apply the deck design plan to any editable text boxes.")
            }
            let skipped = result.skipped ?? []
            let skippedNote = skipped.isEmpty ? "" : " \(skipped.count) text box(es) need manual review."
            return PowerPointRewriteOutcome(
                success: skipped.isEmpty,
                message: "Applied design language to \(applied.count) text box(es) across \(design.slideCount ?? deck.slideCount) slide(s).\(skippedNote)"
            )
        } catch where (error as NSError).code == 408 {
            return PowerPointRewriteOutcome(success: false, message: "PowerPoint did not finish the deck design command within 20 seconds.")
        } catch {
            return PowerPointRewriteOutcome(success: false, message: "I couldn’t apply the deck design plan: \(error.localizedDescription)")
        }
    }

    private static func restoreDeckDesign(_ design: PowerPointDesignResult) async -> PowerPointRewriteOutcome {
        guard let deckRestoreData = design.deckRestoreData,
              !deckRestoreData.isEmpty else {
            return await undoLastPowerPointEdit(onSlide: design.slideIndex)
        }

        var restored = 0
        var skipped = 0
        for restoreData in deckRestoreData {
            do {
                let result = try await PowerPointExecutor.runJSON(
                    restoreDirectEditScript(restoreData),
                    as: PowerPointExecutor.JSONEnvelope.self,
                    timeoutSeconds: automationTimeoutSeconds
                )
                restored += result.applied?.count ?? 0
                skipped += result.skipped?.count ?? 0
            } catch {
                skipped += restoreData.snapshots.count
            }
        }
        guard restored > 0 else {
            return PowerPointRewriteOutcome(success: false, message: "I couldn’t restore the deck design changes. Use Undo as a fallback.")
        }
        let skippedNote = skipped == 0 ? "" : " \(skipped) text box(es) need manual review."
        return PowerPointRewriteOutcome(
            success: skipped == 0,
            message: "Restored \(restored) text box(es) across the deck.\(skippedNote)"
        )
    }

    private static func jump(to rewrite: PowerPointRewriteResult) async -> PowerPointRewriteOutcome {
        await jump(toSlide: rewrite.slideIndex, presentationTitle: rewrite.presentationTitle)
    }

    private static func jump(toSlide slideIndex: Int, presentationTitle: String) async -> PowerPointRewriteOutcome {
        let script = """
        tell application "Microsoft PowerPoint"
            activate
            try
                set slide of active window to slide \(slideIndex) of active presentation
            on error
                try
                    select slide \(slideIndex) of active presentation
                end try
            end try
        end tell
        """
        do {
            try await AppleScriptHelper.execute(script, timeoutSeconds: automationTimeoutSeconds)
            return PowerPointRewriteOutcome(success: true, message: "Jumped to slide \(slideIndex) in \(presentationTitle).")
        } catch where (error as NSError).code == 408 {
            return PowerPointRewriteOutcome(success: false, message: "PowerPoint did not finish the jump command within \(Int(automationTimeoutSeconds)) seconds.")
        } catch {
            return PowerPointRewriteOutcome(success: false, message: "I couldn’t jump to slide \(slideIndex): \(error.localizedDescription)")
        }
    }

    private static func undoLastPowerPointEdit(onSlide slideIndex: Int) async -> PowerPointRewriteOutcome {
        let script = """
        tell application "Microsoft PowerPoint"
            activate
        end tell
        delay 0.15
        tell application "System Events"
            keystroke "z" using {command down}
        end tell
        """

        do {
            try await AppleScriptHelper.execute(script, timeoutSeconds: automationTimeoutSeconds)
            return PowerPointRewriteOutcome(
                success: true,
                message: "Sent Command-Z to PowerPoint to undo the last edit."
            )
        } catch where (error as NSError).code == 408 {
            return PowerPointRewriteOutcome(
                success: false,
                message: "PowerPoint did not finish the undo command within \(Int(automationTimeoutSeconds)) seconds."
            )
        } catch {
            return PowerPointRewriteOutcome(
                success: false,
                message: "I couldn’t send Command-Z to PowerPoint: \(error.localizedDescription)"
            )
        }
    }

    private static func apply(
        rewrite: PowerPointRewriteResult,
        useOriginals: Bool
    ) async -> PowerPointRewriteOutcome {
        let current: PowerPointSlideContext
        switch await captureCurrentSlide() {
        case .success(let captured):
            current = captured
        case .failure(let message):
            return PowerPointRewriteOutcome(success: false, message: message)
        }
        guard matches(current: current, rewrite: rewrite) else {
            return PowerPointRewriteOutcome(success: false, message: "The active PowerPoint slide no longer matches this rewrite preview. Re-run the rewrite on the current slide.")
        }

        let currentByIndex = Dictionary(uniqueKeysWithValues: current.shapes.map { ($0.index, $0) })
        let mutations = rewrite.replacements.compactMap { replacement -> PowerPointTextMutation? in
            let expectedText = useOriginals ? replacement.replacementText : replacement.originalText
            let newText = useOriginals ? replacement.originalText : replacement.replacementText
            guard !replacement.shapeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !expectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PowerPointTextMutation(
                shapeIndex: replacement.shapeIndex,
                shapeName: replacement.shapeName,
                expectedText: expectedText,
                newText: newText
            )
        }
        guard !mutations.isEmpty else {
            return PowerPointRewriteOutcome(success: false, message: "There are no non-empty text replacements to apply.")
        }

        let stale = mutations.filter { mutation in
            guard let currentShape = currentByIndex[mutation.shapeIndex],
                  currentShape.name == mutation.shapeName else {
                return true
            }
            return !textsEquivalent(currentShape.text, mutation.expectedText)
        }
        guard stale.isEmpty else {
            return PowerPointRewriteOutcome(
                success: false,
                message: "The slide text changed after this preview was created. Re-run the rewrite before applying it."
            )
        }

        let script = applyScript(slideIndex: rewrite.slideIndex, mutations: mutations)
        do {
            let result = try await PowerPointExecutor.runJSON(
                script,
                as: PowerPointExecutor.JSONEnvelope.self,
                timeoutSeconds: automationTimeoutSeconds
            )
            if result.ok == false, let scriptError = result.error {
                return PowerPointRewriteOutcome(success: false, message: scriptError)
            }
            let applied = result.applied ?? []
            let skipped = result.skipped ?? []
            guard !applied.isEmpty else {
                return PowerPointRewriteOutcome(success: false, message: "I couldn’t apply any slide text changes. Re-run the rewrite after selecting the slide again.")
            }
            let action = useOriginals ? "Restored" : "Applied"
            let skippedNote = skipped.isEmpty ? "" : " \(skipped.count) text box(es) need manual review."
            return PowerPointRewriteOutcome(
                success: skipped.isEmpty,
                message: "\(action) \(applied.count) text change(s) on slide \(rewrite.slideIndex).\(skippedNote)"
            )
        } catch where (error as NSError).code == 408 {
            return PowerPointRewriteOutcome(success: false, message: "PowerPoint did not finish the rewrite command within \(Int(automationTimeoutSeconds)) seconds.")
        } catch {
            return PowerPointRewriteOutcome(success: false, message: "I couldn’t update PowerPoint: \(error.localizedDescription)")
        }
    }

    private static func matches(current: PowerPointSlideContext, rewrite: PowerPointRewriteResult) -> Bool {
        if current.slideIndex != rewrite.slideIndex { return false }
        if let expectedPath = rewrite.sourceFilePath,
           !expectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let currentPath = current.filePath {
            return URL(fileURLWithPath: currentPath).standardizedFileURL ==
                URL(fileURLWithPath: expectedPath).standardizedFileURL
        }
        return normalizedTitle(current.presentationTitle) == normalizedTitle(rewrite.presentationTitle)
    }

    private static func matches(current: PowerPointSlideContext, design: PowerPointDesignResult) -> Bool {
        if current.slideIndex != design.slideIndex { return false }
        if let expectedPath = design.sourceFilePath,
           !expectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let currentPath = current.filePath {
            return URL(fileURLWithPath: currentPath).standardizedFileURL ==
                URL(fileURLWithPath: expectedPath).standardizedFileURL
        }
        return normalizedTitle(current.presentationTitle) == normalizedTitle(design.presentationTitle)
    }

    private static func matches(deck: PowerPointDeckContext, design: PowerPointDesignResult) -> Bool {
        if let expectedCount = design.slideCount, expectedCount != deck.slideCount { return false }
        if let expectedPath = design.sourceFilePath,
           !expectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let currentPath = deck.filePath {
            return URL(fileURLWithPath: currentPath).standardizedFileURL ==
                URL(fileURLWithPath: expectedPath).standardizedFileURL
        }
        return normalizedTitle(deck.presentationTitle) == normalizedTitle(design.presentationTitle)
    }

    private static func applyScript(
        slideIndex: Int,
        mutations: [PowerPointTextMutation]
    ) -> String {
        let validationCommands = mutations.map { mutation in
            let expectedName = appleScriptTextLiteral(mutation.shapeName)
            let expectedText = appleScriptTextLiteral(mutation.expectedText)
            return """
                    try
                        set shp to shape \(mutation.shapeIndex) of slideRef
                        set actualName to name of shp
                        if actualName is \(expectedName) then
                            if (has text frame of shp) and (my normalizeLineEndings(content of text range of text frame of shp) is my normalizeLineEndings(\(expectedText))) then
                                set validCount to validCount + 1
                            else
                                set skippedItems to my appendIndex(skippedItems, \(mutation.shapeIndex))
                            end if
                        else
                            set skippedItems to my appendIndex(skippedItems, \(mutation.shapeIndex))
                        end if
                    on error
                        set skippedItems to my appendIndex(skippedItems, \(mutation.shapeIndex))
                    end try
            """
        }.joined(separator: "\n")

        let applyCommands = mutations.map { mutation in
            let newText = appleScriptTextLiteral(mutation.newText)
            return """
                    set shp to shape \(mutation.shapeIndex) of slideRef
                    set content of text range of text frame of shp to \(newText)
                    set appliedCount to appliedCount + 1
                    set appliedItems to my appendIndex(appliedItems, \(mutation.shapeIndex))
            """
        }.joined(separator: "\n")

        return """
        on replaceText(findText, replacementText, sourceText)
            set previousDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to findText
            set textItems to text items of sourceText
            set AppleScript's text item delimiters to replacementText
            set joinedText to textItems as text
            set AppleScript's text item delimiters to previousDelimiters
            return joinedText
        end replaceText

        on normalizeLineEndings(sourceText)
            set normalizedText to sourceText as text
            set normalizedText to my replaceText(return & linefeed, linefeed, normalizedText)
            set normalizedText to my replaceText(return, linefeed, normalizedText)
            return normalizedText
        end normalizeLineEndings

        on appendIndex(listText, indexValue)
            if listText is "" then return indexValue as text
            return listText & "," & indexValue
        end appendIndex

        tell application "Microsoft PowerPoint"
            set q to quote
            activate
            set presRef to active presentation
            set slideRef to slide \(slideIndex) of presRef
            set appliedCount to 0
            set appliedItems to ""
            set validCount to 0
            set skippedItems to ""
        \(validationCommands)
            if validCount is \(mutations.count) then
        \(applyCommands)
            end if
            return "{" & q & "ok" & q & ":true," & q & "applied" & q & ":[" & appliedItems & "]," & q & "skipped" & q & ":[" & skippedItems & "]}"
        end tell
        """
    }

    private static func restoreDirectEditScript(_ restoreData: PowerPointRestoreData) -> String {
        let restoreCommands = restoreData.snapshots.map { snapshot in
            let expectedName = appleScriptTextLiteral(snapshot.shapeName)
            let originalText = appleScriptTextLiteral(snapshot.text)
            let fontNameLine: String
            if let fontName = snapshot.fontName,
               !fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fontNameLine = "try\n                            set name of fontRef to \(appleScriptTextLiteral(fontName))\n                        end try"
            } else {
                fontNameLine = ""
            }
            let fontSizeLine = snapshot.fontSize.map {
                "try\n                            set font size of fontRef to \($0)\n                        end try"
            } ?? ""
            let boldLine = snapshot.bold.map {
                "try\n                            set bold of fontRef to \($0 ? "true" : "false")\n                        end try"
            } ?? ""
            let italicLine = snapshot.italic.map {
                "try\n                            set italic of fontRef to \($0 ? "true" : "false")\n                        end try"
            } ?? ""
            let underlineLine = snapshot.underline.map {
                "try\n                            set underline of fontRef to \($0 ? "true" : "false")\n                        end try"
            } ?? ""
            let alignmentLine = snapshot.alignment.map {
                "try\n                            set alignment of paragraph format of textRef to \($0)\n                        end try"
            } ?? ""
            let colorLine: String
            if let color = snapshot.fontColor, color.count >= 3 {
                colorLine = "try\n                            set font color of fontRef to {\(color[0]), \(color[1]), \(color[2])}\n                        end try"
            } else {
                colorLine = ""
            }
            let leftLine = snapshot.left.map {
                "try\n                            set left position of shp to \($0)\n                        end try"
            } ?? ""
            let topLine = snapshot.top.map {
                "try\n                            set top of shp to \($0)\n                        end try"
            } ?? ""
            let widthLine = snapshot.width.map {
                "try\n                            set width of shp to \($0)\n                        end try"
            } ?? ""
            let heightLine = snapshot.height.map {
                "try\n                            set height of shp to \($0)\n                        end try"
            } ?? ""

            return """
                    try
                        set shp to shape \(snapshot.shapeIndex) of slideRef
                        set actualName to name of shp
                        if actualName is \(expectedName) then
                            set textRef to text range of text frame of shp
                            set content of textRef to \(originalText)
                            set fontRef to font of textRef
                        \(fontNameLine)
                        \(fontSizeLine)
                        \(boldLine)
                        \(italicLine)
                        \(underlineLine)
                        \(alignmentLine)
                        \(colorLine)
                        \(leftLine)
                        \(topLine)
                        \(widthLine)
                        \(heightLine)
                            set appliedItems to my appendIndex(appliedItems, \(snapshot.shapeIndex))
                        else
                            set skippedItems to my appendIndex(skippedItems, \(snapshot.shapeIndex))
                        end if
                    on error
                        set skippedItems to my appendIndex(skippedItems, \(snapshot.shapeIndex))
                    end try
            """
        }.joined(separator: "\n")

        return """
        on appendIndex(listText, indexValue)
            if listText is "" then return indexValue as text
            return listText & "," & indexValue
        end appendIndex

        tell application "Microsoft PowerPoint"
            set q to quote
            activate
            set presRef to active presentation
            set slideRef to slide \(restoreData.slideIndex) of presRef
            set appliedItems to ""
            set skippedItems to ""
            set shapeCount to count of shapes of slideRef
            repeat with shapeIndex from \(maxDirectEditShapeSlots) to 1 by -1
                if shapeCount >= shapeIndex then
                    try
                        set shp to shape shapeIndex of slideRef
                        set shapeName to name of shp
                        if shapeName starts with "Metamorphia Design " then delete shp
                    end try
                end if
            end repeat
        \(restoreCommands)
            return "{" & q & "ok" & q & ":true," & q & "applied" & q & ":[" & appliedItems & "]," & q & "skipped" & q & ":[" & skippedItems & "]}"
        end tell
        """
    }

    private static func applyDesignScript(
        design: PowerPointDesignResult,
        context: PowerPointSlideContext
    ) -> String {
        let primaryColor = appleScriptRGB16Literal(design.palette.primary)
        let secondaryColor = appleScriptRGB16Literal(design.palette.secondary)
        let textColor = appleScriptRGB16Literal(design.palette.text)
        let mutedColor = appleScriptRGB16Literal(design.palette.mutedText)
        let accentColor = appleScriptRGB16Literal(design.palette.accent)
        let titleFont = appleScriptTextLiteral(design.typography.titleFont)
        let bodyFont = appleScriptTextLiteral(design.typography.bodyFont)
        let titleSize = Int(design.typography.titleSize.rounded())
        let bodySize = Int(design.typography.bodySize.rounded())
        let layout = designLayout(for: context)
        let replacementByShape = Dictionary(uniqueKeysWithValues: design.textBlocks.map {
            ($0.shapeIndex, appleScriptTextLiteral($0.replacementText))
        })

        let motifCommands = """
                try
                    set designPanel to make new shape at end of shapes of slideRef with properties {auto shape type:autoshape rounded rectangle, left position:\(layout.panelLeft), top:\(layout.panelTop), width:\(layout.panelWidth), height:\(layout.panelHeight)}
                    set name of designPanel to "Metamorphia Design Panel"
                    set fore color of fill format of designPanel to \(secondaryColor)
                    set transparency of fill format of designPanel to 8
                    try
                        set transparency of line format of designPanel to 100
                    end try
                    z order designPanel z order position send shape to back
                end try
                try
                    set designRail to make new shape at end of shapes of slideRef with properties {auto shape type:autoshape rectangle, left position:\(layout.accentLeft), top:\(layout.accentTop), width:\(layout.accentWidth), height:\(layout.accentHeight)}
                    set name of designRail to "Metamorphia Design Accent Rail"
                    set fore color of fill format of designRail to \(accentColor)
                    try
                        set transparency of line format of designRail to 100
                    end try
                    z order designRail z order position send shape backward
                end try
        """

        let commands = context.shapes.map { shape in
            let expectedName = appleScriptTextLiteral(shape.name)
            let roleCommands: String
            switch shape.role {
            case .title:
                roleCommands = """
                            try
                                set left position of shp to \(layout.titleLeft)
                            end try
                            try
                                set top of shp to \(layout.titleTop)
                            end try
                            try
                                set width of shp to \(layout.titleWidth)
                            end try
                            try
                                set height of shp to \(layout.titleHeight)
                            end try
                            try
                                set name of fontRef to \(titleFont)
                            end try
                            try
                                set font size of fontRef to \(titleSize)
                            end try
                            try
                                set bold of fontRef to true
                            end try
                            try
                                set font color of fontRef to \(primaryColor)
                            end try
                            try
                                set alignment of paragraph format of textRef to 2
                            end try
                            try
                                set margin left of text frame of shp to 0
                                set margin right of text frame of shp to 0
                            end try
                """
            case .footer:
                roleCommands = """
                            try
                                set name of fontRef to \(bodyFont)
                            end try
                            try
                                set font size of fontRef to 10
                            end try
                            try
                                set bold of fontRef to false
                            end try
                            try
                                set font color of fontRef to \(mutedColor)
                            end try
                """
            case .body:
                let replacementLine = replacementByShape[shape.index].map {
                    "try\n                                set content of textRef to \($0)\n                                set fontRef to font of textRef\n                            end try"
                } ?? ""
                roleCommands = """
                            \(replacementLine)
                            try
                                set left position of shp to \(layout.bodyLeft)
                            end try
                            try
                                set top of shp to \(layout.bodyTop)
                            end try
                            try
                                set width of shp to \(layout.bodyWidth)
                            end try
                            try
                                set height of shp to \(layout.bodyHeight)
                            end try
                            try
                                set name of fontRef to \(bodyFont)
                            end try
                            try
                                set font size of fontRef to \(bodySize)
                            end try
                            try
                                set bold of fontRef to false
                            end try
                            try
                                set font color of fontRef to \(textColor)
                            end try
                            try
                                set alignment of paragraph format of textRef to 1
                            end try
                            try
                                set visible of bullet format of paragraph format of textRef to false
                            end try
                            try
                                set space after of paragraph format of textRef to 8
                            end try
                            try
                                set space within of paragraph format of textRef to 1.05
                            end try
                            try
                                set margin left of text frame of shp to 6
                                set margin right of text frame of shp to 6
                                set margin top of text frame of shp to 0
                                set margin bottom of text frame of shp to 0
                            end try
                """
            case .other:
                roleCommands = """
                            try
                                set name of fontRef to \(bodyFont)
                            end try
                            try
                                set font size of fontRef to \(max(12, bodySize - 1))
                            end try
                            try
                                set font color of fontRef to \(accentColor)
                            end try
                """
            }

            return """
                    try
                        set shp to shape \(shape.index) of slideRef
                        set actualName to name of shp
                        if actualName is \(expectedName) then
                            set textRef to text range of text frame of shp
                            set fontRef to font of textRef
                \(roleCommands)
                            set appliedItems to my appendIndex(appliedItems, \(shape.index))
                        else
                            set skippedItems to my appendIndex(skippedItems, \(shape.index))
                        end if
                    on error
                        set skippedItems to my appendIndex(skippedItems, \(shape.index))
                    end try
            """
        }.joined(separator: "\n")

        return """
        on appendIndex(listText, indexValue)
            if listText is "" then return indexValue as text
            return listText & "," & indexValue
        end appendIndex

        tell application "Microsoft PowerPoint"
            set q to quote
            activate
            set presRef to active presentation
            set slideRef to slide \(design.slideIndex) of presRef
            set appliedItems to ""
            set skippedItems to ""
        \(motifCommands)
        \(commands)
            return "{" & q & "ok" & q & ":true," & q & "applied" & q & ":[" & appliedItems & "]," & q & "skipped" & q & ":[" & skippedItems & "]}"
        end tell
        """
    }

    private static func applyDeckDesignScript(_ design: PowerPointDesignResult) -> String {
        let primaryColor = appleScriptRGB16Literal(design.palette.primary)
        let textColor = appleScriptRGB16Literal(design.palette.text)
        let mutedColor = appleScriptRGB16Literal(design.palette.mutedText)
        let titleFont = appleScriptTextLiteral(design.typography.titleFont)
        let bodyFont = appleScriptTextLiteral(design.typography.bodyFont)
        let titleSize = Int(design.typography.titleSize.rounded())
        let bodySize = Int(design.typography.bodySize.rounded())

        return """
        on appendIndex(listText, indexValue)
            if listText is "" then return indexValue as text
            return listText & "," & indexValue
        end appendIndex

        tell application "Microsoft PowerPoint"
            set q to quote
            activate
            if (count of presentations) is 0 then
                return "{" & q & "ok" & q & ":false," & q & "error" & q & ":" & q & "PowerPoint has no active presentation to edit." & q & "}"
            end if
            set presRef to active presentation
            set appliedItems to ""
            set skippedItems to ""
            set slideTotal to count of slides of presRef
            repeat with slideIndex from 1 to slideTotal
                set slideRef to slide slideIndex of presRef
                set shapeTotal to count of shapes of slideRef
                repeat with shapeIndex from 1 to shapeTotal
                    try
                        set shp to shape shapeIndex of slideRef
                        if (has text frame of shp) and (has text of text frame of shp) then
                            set textRef to text range of text frame of shp
                            if (content of textRef as text) is not "" then
                                set fontRef to font of textRef
                                set shapeName to ""
                                try
                                    set shapeName to name of shp
                                end try
                                if shapeIndex is less than or equal to 2 or shapeName contains "Title" or shapeName contains "title" then
                                    try
                                        set name of fontRef to \(titleFont)
                                    end try
                                    try
                                        set font size of fontRef to \(titleSize)
                                    end try
                                    try
                                        set bold of fontRef to true
                                    end try
                                    try
                                        set font color of fontRef to \(primaryColor)
                                    end try
                                    try
                                        set alignment of paragraph format of textRef to 1
                                    end try
                                else
                                    try
                                        set name of fontRef to \(bodyFont)
                                    end try
                                    try
                                        set font size of fontRef to \(bodySize)
                                    end try
                                    try
                                        set bold of fontRef to false
                                    end try
                                    try
                                        set font color of fontRef to \(textColor)
                                    end try
                                    try
                                        set alignment of paragraph format of textRef to 1
                                    end try
                                end if
                                if shapeName contains "Footer" or shapeName contains "footer" or shapeName contains "Slide Number" then
                                    try
                                        set font size of fontRef to 10
                                    end try
                                    try
                                        set font color of fontRef to \(mutedColor)
                                    end try
                                end if
                                set appliedItems to my appendIndex(appliedItems, ((slideIndex * 1000) + shapeIndex))
                            end if
                        end if
                    on error
                        set skippedItems to my appendIndex(skippedItems, ((slideIndex * 1000) + shapeIndex))
                    end try
                end repeat
            end repeat
            return "{" & q & "ok" & q & ":true," & q & "applied" & q & ":[" & appliedItems & "]," & q & "skipped" & q & ":[" & skippedItems & "]}"
        end tell
        """
    }

    private static func directEditScript(command: PowerPointDirectEditCommand) -> String {
        let applyLine: String = {
            switch command.kind {
            case .textColor:
                return "set font color of fontRef to \(command.appleScriptValue)"
            case .fontSize:
                return "set font size of fontRef to \(command.appleScriptValue)"
            case .bold:
                return "set bold of fontRef to \(command.appleScriptValue)"
            case .italic:
                return "set italic of fontRef to \(command.appleScriptValue)"
            case .underline:
                return "set underline of fontRef to \(command.appleScriptValue)"
            case .alignment:
                return "set alignment of paragraph format of textRef to \(command.appleScriptValue)"
            case .backgroundColor:
                return ""
            }
        }()
        let shapeBlocks = (1...maxDirectEditShapeSlots).map { shapeIndex in
            """
                if shapeCount >= \(shapeIndex) then
                    try
                        set textRef to text range of text frame of shape \(shapeIndex) of slideRef
                        set shapeText to content of textRef
                        if shapeText is not "" then
                            set fontRef to font of textRef
                            set shapeName to ""
                            try
                                set shapeName to name of shape \(shapeIndex) of slideRef
                            end try
                            set fontNameValue to ""
                            set fontSizeValue to "null"
                            set boldValue to "null"
                            set italicValue to "null"
                            set underlineValue to "null"
                            set alignmentValue to "null"
                            set colorValueJSON to "null"
                            try
                                set fontNameValue to name of fontRef
                            end try
                            try
                                set fontSizeValue to font size of fontRef as text
                            end try
                            try
                                set boldValue to my jsonBool(bold of fontRef)
                            end try
                            try
                                set italicValue to my jsonBool(italic of fontRef)
                            end try
                            try
                                set underlineValue to my jsonBool(underline of fontRef)
                            end try
                            try
                                set alignmentValue to alignment of paragraph format of textRef as integer as text
                            end try
                            try
                                set fontColorValue to font color of fontRef
                                set colorValueJSON to "[" & (item 1 of fontColorValue) & "," & (item 2 of fontColorValue) & "," & (item 3 of fontColorValue) & "]"
                            end try
                            if snapshotItems is not "" then set snapshotItems to snapshotItems & ","
                            set snapshotItems to snapshotItems & "{"
                            set snapshotItems to snapshotItems & q & "shapeIndex" & q & ":" & \(shapeIndex) & ","
                            set snapshotItems to snapshotItems & q & "shapeName" & q & ":" & q & my jsonEscape(shapeName) & q & ","
                            set snapshotItems to snapshotItems & q & "text" & q & ":" & q & my jsonEscape(shapeText) & q & ","
                            set snapshotItems to snapshotItems & q & "fontName" & q & ":" & q & my jsonEscape(fontNameValue) & q & ","
                            set snapshotItems to snapshotItems & q & "fontSize" & q & ":" & fontSizeValue & ","
                            set snapshotItems to snapshotItems & q & "bold" & q & ":" & boldValue & ","
                            set snapshotItems to snapshotItems & q & "italic" & q & ":" & italicValue & ","
                            set snapshotItems to snapshotItems & q & "underline" & q & ":" & underlineValue & ","
                            set snapshotItems to snapshotItems & q & "alignment" & q & ":" & alignmentValue & ","
                            set snapshotItems to snapshotItems & q & "fontColor" & q & ":" & colorValueJSON
                            set snapshotItems to snapshotItems & "}"
                            \(applyLine)
                            set appliedItems to my appendIndex(appliedItems, \(shapeIndex))
                        else
                            set skippedItems to my appendIndex(skippedItems, \(shapeIndex))
                        end if
                    on error errMsg number errNum
                        set skippedItems to my appendIndex(skippedItems, \(shapeIndex))
                        if errorCount < 5 then
                            if errorItems is not "" then set errorItems to errorItems & ","
                            set errorItems to errorItems & q & "#" & \(shapeIndex) & " " & errNum & ": " & my jsonEscape(errMsg) & q
                            set errorCount to errorCount + 1
                        end if
                    end try
                end if
            """
        }.joined(separator: "\n")

        return """
        on replaceText(findText, replacementText, sourceText)
            set previousDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to findText
            set textItems to text items of sourceText
            set AppleScript's text item delimiters to replacementText
            set joinedText to textItems as text
            set AppleScript's text item delimiters to previousDelimiters
            return joinedText
        end replaceText

        on jsonEscape(sourceText)
            set slash to ASCII character 92
            set escapedText to sourceText as text
            set escapedText to my replaceText(slash, slash & slash, escapedText)
            set escapedText to my replaceText(quote, slash & quote, escapedText)
            set escapedText to my replaceText(return, slash & "n", escapedText)
            set escapedText to my replaceText(linefeed, slash & "n", escapedText)
            set escapedText to my replaceText(tab, slash & "t", escapedText)
            return escapedText
        end jsonEscape

        on jsonBool(value)
            if value is true then return "true"
            if value is false then return "false"
            return "null"
        end jsonBool

        on appendIndex(listText, indexValue)
            if listText is "" then return indexValue as text
            return listText & "," & indexValue
        end appendIndex

        tell application "Microsoft PowerPoint"
            set q to quote
            if (count of presentations) is 0 then
                return "{" & q & "ok" & q & ":false," & q & "error" & q & ":" & q & "PowerPoint is open, but it has no active presentation to edit." & q & "}"
            end if
            set winRef to active window
            set presRef to presentation of winRef
            set slideRef to slide of view of winRef
            set slideIndex to slide index of slideRef
            set presentationTitle to name of presRef
            set filePath to ""
            try
                set filePath to POSIX path of (full name of presRef as alias)
            end try
            set slideTitle to ""
            try
                set slideTitle to name of slideRef
            end try
            set shapeCount to count of shapes of slideRef
            set appliedItems to ""
            set skippedItems to ""
            set errorItems to ""
            set snapshotItems to ""
            set errorCount to 0
        \(shapeBlocks)
            return "{" & q & "ok" & q & ":true," & q & "presentationTitle" & q & ":" & q & my jsonEscape(presentationTitle) & q & "," & q & "filePath" & q & ":" & q & my jsonEscape(filePath) & q & "," & q & "slideIndex" & q & ":" & slideIndex & "," & q & "slideTitle" & q & ":" & q & my jsonEscape(slideTitle) & q & "," & q & "shapeCount" & q & ":" & shapeCount & "," & q & "applied" & q & ":[" & appliedItems & "]," & q & "skipped" & q & ":[" & skippedItems & "]," & q & "warnings" & q & ":[" & errorItems & "]," & q & "snapshots" & q & ":[" & snapshotItems & "]}"
        end tell
        """
    }

    private static func parseAppliedCount(from result: String) -> Int {
        result.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("applied=") })
            .flatMap { Int($0.dropFirst("applied=".count)) } ?? 0
    }

    private static func parseSkipped(from result: String) -> [String] {
        guard let line = result.components(separatedBy: .newlines).first(where: { $0.hasPrefix("skipped=") }) else {
            return []
        }
        return line
            .dropFirst("skipped=".count)
            .split(separator: ",")
            .map(String.init)
    }

    private static func parseIndexList(from result: String, key: String) -> [Int] {
        guard let line = result.components(separatedBy: .newlines).first(where: { $0.hasPrefix("\(key)=") }) else {
            return []
        }
        return line
            .dropFirst(key.count + 1)
            .split(separator: ",")
            .compactMap { Int($0) }
    }

    private static func parseInteger(from result: String, key: String) -> Int {
        guard let line = result.components(separatedBy: .newlines).first(where: { $0.hasPrefix("\(key)=") }) else {
            return 0
        }
        return Int(line.dropFirst(key.count + 1)) ?? 0
    }

    private static func parseStringValue(from result: String, key: String) -> String {
        guard let line = result.components(separatedBy: .newlines).first(where: { $0.hasPrefix("\(key)=") }) else {
            return ""
        }
        return String(line.dropFirst(key.count + 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optionalParsedStringValue(from result: String, key: String) -> String? {
        let value = parseStringValue(from: result, key: key)
        return value.isEmpty ? nil : value
    }

    private static func inferRole(index: Int, name: String, text: String) -> PowerPointShapeRole {
        let loweredName = name.lowercased()
        if loweredName.contains("title") { return .title }
        if loweredName.contains("footer") || loweredName.contains("date") || loweredName.contains("slide number") {
            return .footer
        }
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if index <= 2 && collapsed.count <= 90 { return .title }
        return .body
    }

    private static func cappedPromptShapes(_ shapes: [PowerPointSlideShape]) -> [PowerPointSlideShape] {
        var selected: [PowerPointSlideShape] = []
        var totalCharacters = 0
        for shape in shapes.prefix(maxPromptShapes) {
            let cost = min(shape.text.count, maxPromptCharactersPerShape)
            guard totalCharacters + cost <= maxPromptCharacters || selected.isEmpty else { break }
            selected.append(shape)
            totalCharacters += cost
        }
        return selected
    }

    private static func deckReviewText(for deck: PowerPointDeckContext) -> String {
        var lines: [String] = [
            "Presentation: \(deck.presentationTitle)",
            "Slide count: \(deck.slideCount)",
            "Active slide: \(deck.activeSlideIndex)"
        ]
        var totalCharacters = lines.joined(separator: "\n").count

        for slide in deck.slides {
            let slideTitle = slide.slideTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleSuffix: String
            if let slideTitle, !slideTitle.isEmpty {
                titleSuffix = ": \(slideTitle)"
            } else {
                titleSuffix = ""
            }
            let header = "\nSlide \(slide.slideIndex)\(titleSuffix)"
            guard totalCharacters + header.count <= maxPromptCharacters || lines.count <= 3 else {
                lines.append("\n[Additional slides omitted for prompt size.]")
                break
            }

            lines.append(header)
            totalCharacters += header.count

            for shape in slide.shapes {
                let text = shape.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let normalized = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let capped = promptText(normalized)
                let shapeLine = "- \(shape.role.rawValue) #\(shape.index): \(capped)"
                guard totalCharacters + shapeLine.count <= maxPromptCharacters || lines.count <= 4 else {
                    lines.append("[Remaining slide text omitted for prompt size.]")
                    return lines.joined(separator: "\n")
                }
                lines.append(shapeLine)
                totalCharacters += shapeLine.count
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func promptText(_ text: String) -> String {
        guard text.count > maxPromptCharactersPerShape else { return text }
        return String(text.prefix(maxPromptCharactersPerShape)) +
            "\n[... text truncated for prompt size; keep any rewrite concise ...]"
    }

    private static func textsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        normalizeLineEndings(lhs) == normalizeLineEndings(rhs)
    }

    private static func resolvedDesignRecipe(_ recipe: String) -> String {
        let allowed = ["Editorial feature", "Insight cards", "Contrast panel", "Definition spotlight"]
        let trimmed = recipe.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowed.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? "Editorial feature"
    }

    private static func resolvedDesignTextBlocks(
        _ proposedBlocks: [PowerPointDesignTextBlock],
        route: PowerPointDesignRoute
    ) -> [PowerPointDesignTextBlock] {
        var seen = Set<Int>()
        let validated = proposedBlocks.compactMap { block -> PowerPointDesignTextBlock? in
            guard !seen.contains(block.shapeIndex),
                  let snapshot = route.shapeSnapshots[block.shapeIndex],
                  snapshot.name == block.shapeName || block.shapeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let replacement = normalizedDesignReplacement(block.replacementText)
            guard !replacement.isEmpty,
                  !textsEquivalent(snapshot.text, replacement) else {
                return nil
            }
            seen.insert(block.shapeIndex)
            return PowerPointDesignTextBlock(
                shapeIndex: block.shapeIndex,
                shapeName: snapshot.name,
                role: snapshot.role,
                originalText: snapshot.text,
                replacementText: replacement,
                rationale: block.rationale
            )
        }
        if !validated.isEmpty { return validated }

        return route.shapeSnapshots
            .sorted { $0.key < $1.key }
            .compactMap { shapeIndex, snapshot -> PowerPointDesignTextBlock? in
                guard snapshot.role == .body,
                      let replacement = fallbackStructuredBodyText(snapshot.text),
                      !textsEquivalent(snapshot.text, replacement) else {
                    return nil
                }
                return PowerPointDesignTextBlock(
                    shapeIndex: shapeIndex,
                    shapeName: snapshot.name,
                    role: snapshot.role,
                    originalText: snapshot.text,
                    replacementText: replacement,
                    rationale: "Breaks dense prose into scanable content blocks."
                )
            }
    }

    private static func normalizedDesignReplacement(_ text: String) -> String {
        normalizeLineEndings(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackStructuredBodyText(_ text: String) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count >= 180 else { return nil }

        let sentences = splitSentences(collapsed)
        guard sentences.count >= 2 else { return nil }
        let first = sentences.first ?? ""
        let last = sentences.last ?? ""
        let middle = sentences.dropFirst().dropLast().joined(separator: " ")
        let middleText = middle.isEmpty ? last : middle
        let lastText = middle.isEmpty ? "" : last

        let blocks = [
            ("Core idea", first),
            ("Context", middleText),
            ("Reader impact", lastText.isEmpty ? nil : lastText)
        ].compactMap { heading, body -> String? in
            guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "\(heading)\n\(body)"
        }
        guard blocks.count >= 2 else { return nil }
        return blocks.joined(separator: "\n\n")
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            sentences.append(trailing)
        }
        return sentences
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func normalizedOptionalString(_ string: String?) -> String? {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func intArray(_ value: Any?) -> [Int]? {
        if let ints = value as? [Int] { return ints }
        if let array = value as? [Any] {
            let values = array.compactMap(intValue)
            return values.isEmpty ? nil : values
        }
        return nil
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".pptx", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".ppt", with: "", options: .caseInsensitive)
            .lowercased()
    }

    private static func presentationTastePromptBlock() async -> String {
        guard Defaults[.presentationTastePowerPointEnabled] else { return "" }
        let store = await MainActor.run { MetamorphiaBootstrap.presentationTasteStore }
        guard let store,
              let profile = await store.activeProfileSnapshot() else {
            return ""
        }
        return "\n\(profile.promptSummary)"
    }

    private static func deckPreviews(for deck: PowerPointDeckContext) -> [PowerPointDeckSlidePreview] {
        deck.slides.map { slide in
            PowerPointDeckSlidePreview(
                slideIndex: slide.slideIndex,
                title: slide.slideTitle ?? slide.shapes.first(where: { $0.role == .title })?.text,
                shapeCount: slide.shapes.count,
                titleShapeCount: slide.shapes.filter { $0.role == .title }.count,
                bodyShapeCount: slide.shapes.filter { $0.role == .body }.count
            )
        }
    }

    private static func restoreData(for context: PowerPointSlideContext) -> PowerPointRestoreData {
        PowerPointRestoreData(
            presentationTitle: context.presentationTitle,
            sourceFilePath: context.filePath,
            slideIndex: context.slideIndex,
            slideTitle: context.slideTitle,
            snapshots: context.shapes.map { shape in
                PowerPointShapeRestoreSnapshot(
                    shapeIndex: shape.index,
                    shapeName: shape.name,
                    text: shape.text,
                    fontName: shape.fontName,
                    fontSize: shape.fontSize,
                    bold: shape.bold,
                    italic: shape.italic,
                    underline: shape.underline,
                    alignment: shape.alignment,
                    fontColor: shape.fontColor,
                    left: shape.left,
                    top: shape.top,
                    width: shape.width,
                    height: shape.height
                )
            }
        )
    }

    private static func normalizedHexColor(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .uppercased()
        guard trimmed.count == 6,
              trimmed.allSatisfy({ $0.isHexDigit }) else {
            return fallback
        }
        return trimmed
    }

    private static func allowedDesignFont(_ value: String, fallback: String) -> String {
        let allowed = [
            "Aptos Display", "Aptos", "Georgia", "Calibri", "Trebuchet MS",
            "Palatino", "Garamond", "Arial Black", "Arial", "Cambria",
            "Calibri Light"
        ]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowed.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? fallback
    }

    private static func appleScriptRGB16Literal(_ hex: String) -> String {
        let rgb = rgb8(hex: hex) ?? (17, 24, 39)
        return "{\(rgb.0 * 257), \(rgb.1 * 257), \(rgb.2 * 257)}"
    }

    private static func designLayout(for context: PowerPointSlideContext) -> PowerPointDesignLayout {
        let maxRight = context.shapes.map { $0.left + $0.width }.max() ?? 1280
        let maxBottom = context.shapes.map { $0.top + $0.height }.max() ?? 720
        let slideWidth = max(960, maxRight + 60)
        let slideHeight = max(540, maxBottom + 220)
        let margin = max(64, slideWidth * 0.095)
        let titleShape = context.shapes.first(where: { $0.role == .title })
        let titleIsHeaderCentered = (titleShape?.left ?? 0) > slideWidth * 0.22 && (titleShape?.top ?? 999) < 110
        let titleWidth = titleIsHeaderCentered ? min(620, slideWidth * 0.58) : slideWidth - (margin * 2)
        let titleLeft = titleIsHeaderCentered ? (slideWidth - titleWidth) / 2 : margin
        let titleTop = max(36, min(titleShape?.top ?? 48, 86))
        let titleHeight = max(titleShape?.height ?? 58, 56)
        let headerSafeTop = max(142, titleTop + titleHeight + 44)
        let bodyLeft = margin + 40
        let bodyTop = headerSafeTop + 24
        let bodyWidth = slideWidth - (margin * 2) - 80
        let bodyHeight = max(250, min(390, slideHeight - bodyTop - 100))
        let panelLeft = margin
        let panelTop = headerSafeTop
        let panelWidth = slideWidth - (margin * 2)
        let panelHeight = bodyHeight + 70
        return PowerPointDesignLayout(
            slideWidth: slideWidth,
            slideHeight: slideHeight,
            titleLeft: titleLeft,
            titleTop: titleTop,
            titleWidth: titleWidth,
            titleHeight: titleHeight,
            bodyLeft: bodyLeft,
            bodyTop: bodyTop,
            bodyWidth: bodyWidth,
            bodyHeight: bodyHeight,
            panelLeft: panelLeft,
            panelTop: panelTop,
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            accentLeft: panelLeft,
            accentTop: panelTop,
            accentWidth: 10,
            accentHeight: panelHeight
        )
    }

    private static func rgb8(hex: String) -> (Int, Int, Int)? {
        let normalized = normalizedHexColor(hex, fallback: "111827")
        guard let raw = Int(normalized, radix: 16) else { return nil }
        return ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
    }

    private static func escapeJSONString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func appleScriptTextLiteral(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        if lines.isEmpty { return "\"\"" }
        return lines
            .map { "\"\(LocalCommandHelpers.escapeAppleScript($0))\"" }
            .joined(separator: " & linefeed & ")
    }

    private static var deckCaptureScript: String {
        let shapeBlocks = (1...maxDirectEditShapeSlots).map { shapeIndex in
            """
                    if shapeCount >= \(shapeIndex) then
                        try
                            set shp to shape \(shapeIndex) of slideRef
                            set textRef to text range of text frame of shp
                            set shapeText to content of textRef
                            if shapeText is not "" then
                                set shapeName to ""
                                set fontNameValue to ""
                                set fontSizeValue to "null"
                                set boldValue to "null"
                                set italicValue to "null"
                                set underlineValue to "null"
                                set alignmentValue to "null"
                                set colorValueJSON to "null"
                                try
                                    set shapeName to name of shp
                                end try
                                try
                                    set fontRef to font of textRef
                                    set fontNameValue to name of fontRef
                                    set fontSizeValue to font size of fontRef as text
                                    set boldValue to my jsonBool(bold of fontRef)
                                    set italicValue to my jsonBool(italic of fontRef)
                                    set underlineValue to my jsonBool(underline of fontRef)
                                    set alignmentValue to alignment of paragraph format of textRef as integer as text
                                    set fontColorValue to font color of fontRef
                                    set colorValueJSON to "[" & (item 1 of fontColorValue) & "," & (item 2 of fontColorValue) & "," & (item 3 of fontColorValue) & "]"
                                end try
                                if shapeJSON is not "" then set shapeJSON to shapeJSON & ","
                                set shapeJSON to shapeJSON & "{"
                                set shapeJSON to shapeJSON & q & "index" & q & ":" & \(shapeIndex) & ","
                                set shapeJSON to shapeJSON & q & "name" & q & ":" & q & my jsonEscape(shapeName) & q & ","
                                set shapeJSON to shapeJSON & q & "text" & q & ":" & q & my jsonEscape(shapeText) & q & ","
                                set shapeJSON to shapeJSON & q & "left" & q & ":" & («property plft» of shp) & ","
                                set shapeJSON to shapeJSON & q & "top" & q & ":" & («property ptop» of shp) & ","
                                set shapeJSON to shapeJSON & q & "width" & q & ":" & («property pwid» of shp) & ","
                                set shapeJSON to shapeJSON & q & "height" & q & ":" & («property hght» of shp) & ","
                                set shapeJSON to shapeJSON & q & "fontName" & q & ":" & q & my jsonEscape(fontNameValue) & q & ","
                                set shapeJSON to shapeJSON & q & "fontSize" & q & ":" & fontSizeValue & ","
                                set shapeJSON to shapeJSON & q & "bold" & q & ":" & boldValue & ","
                                set shapeJSON to shapeJSON & q & "italic" & q & ":" & italicValue & ","
                                set shapeJSON to shapeJSON & q & "underline" & q & ":" & underlineValue & ","
                                set shapeJSON to shapeJSON & q & "alignment" & q & ":" & alignmentValue & ","
                                set shapeJSON to shapeJSON & q & "fontColor" & q & ":" & colorValueJSON
                                set shapeJSON to shapeJSON & "}"
                            end if
                        end try
                    end if
            """
        }.joined(separator: "\n")

        return """
        on replaceText(findText, replacementText, sourceText)
            set previousDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to findText
            set textItems to text items of sourceText
            set AppleScript's text item delimiters to replacementText
            set joinedText to textItems as text
            set AppleScript's text item delimiters to previousDelimiters
            return joinedText
        end replaceText

        on jsonEscape(sourceText)
            set slash to ASCII character 92
            set escapedText to sourceText as text
            set escapedText to my replaceText(slash, slash & slash, escapedText)
            set escapedText to my replaceText(quote, slash & quote, escapedText)
            set escapedText to my replaceText(return, slash & "n", escapedText)
            set escapedText to my replaceText(linefeed, slash & "n", escapedText)
            set escapedText to my replaceText(tab, slash & "t", escapedText)
            return escapedText
        end jsonEscape

        on jsonBool(value)
            if value is true then return "true"
            if value is false then return "false"
            return "null"
        end jsonBool

        tell application "Microsoft PowerPoint"
            set q to quote
            if (count of presentations) is 0 then return ""
            try
                set presRef to active presentation
            on error
                set presRef to presentation 1
            end try
            set winRef to missing value
            try
                set winRef to active window
            on error
                set winRef to missing value
            end try
            set presName to name of presRef
            set presPath to ""
            try
                set presPath to POSIX path of (full name of presRef as alias)
            end try
            set activeSlideIndex to 1
            try
                if winRef is not missing value then set activeSlideIndex to slide index of slide of view of winRef
            on error
                try
                    set activeSlideIndex to slide index of slide of active window
                end try
            end try
            set slideTotal to count of slides of presRef
            set slideItems to ""
            repeat with slideIndex from 1 to slideTotal
                set slideRef to slide slideIndex of presRef
                set slideName to ""
                try
                    set slideName to name of slideRef
                end try
                set shapeCount to count of shapes of slideRef
                set shapeJSON to ""
        \(shapeBlocks)
                if slideItems is not "" then set slideItems to slideItems & ","
                set slideItems to slideItems & "{"
                set slideItems to slideItems & q & "slideIndex" & q & ":" & slideIndex & ","
                set slideItems to slideItems & q & "slideTitle" & q & ":" & q & my jsonEscape(slideName) & q & ","
                set slideItems to slideItems & q & "shapes" & q & ":[" & shapeJSON & "]"
                set slideItems to slideItems & "}"
            end repeat

            return "{" & q & "presentationTitle" & q & ":" & q & my jsonEscape(presName) & q & "," & q & "filePath" & q & ":" & q & my jsonEscape(presPath) & q & "," & q & "activeSlideIndex" & q & ":" & activeSlideIndex & "," & q & "slideCount" & q & ":" & slideTotal & "," & q & "slides" & q & ":[" & slideItems & "]}"
        end tell
        """
    }

    private static var currentSlideCaptureScript: String {
        let shapeBlocks = (1...maxDirectEditShapeSlots).map { shapeIndex in
            """
                if shapeCount >= \(shapeIndex) then
                    try
                        set shp to shape \(shapeIndex) of slideRef
                        set textRef to text range of text frame of shp
                        set shapeText to content of textRef
                        if shapeText is not "" then
                            set shapeName to ""
                            set fontNameValue to ""
                            set fontSizeValue to "null"
                            set boldValue to "null"
                            set italicValue to "null"
                            set underlineValue to "null"
                            set alignmentValue to "null"
                            set colorValueJSON to "null"
                            try
                                set shapeName to name of shp
                            end try
                            try
                                set fontRef to font of textRef
                                set fontNameValue to name of fontRef
                                set fontSizeValue to font size of fontRef as text
                                set boldValue to my jsonBool(bold of fontRef)
                                set italicValue to my jsonBool(italic of fontRef)
                                set underlineValue to my jsonBool(underline of fontRef)
                                set alignmentValue to alignment of paragraph format of textRef as integer as text
                                set fontColorValue to font color of fontRef
                                set colorValueJSON to "[" & (item 1 of fontColorValue) & "," & (item 2 of fontColorValue) & "," & (item 3 of fontColorValue) & "]"
                            end try
                            if shapeJSON is not "" then set shapeJSON to shapeJSON & ","
                            set shapeJSON to shapeJSON & "{"
                            set shapeJSON to shapeJSON & q & "index" & q & ":" & \(shapeIndex) & ","
                            set shapeJSON to shapeJSON & q & "name" & q & ":" & q & my jsonEscape(shapeName) & q & ","
                            set shapeJSON to shapeJSON & q & "text" & q & ":" & q & my jsonEscape(shapeText) & q & ","
                            set shapeJSON to shapeJSON & q & "left" & q & ":" & («property plft» of shp) & ","
                            set shapeJSON to shapeJSON & q & "top" & q & ":" & («property ptop» of shp) & ","
                            set shapeJSON to shapeJSON & q & "width" & q & ":" & («property pwid» of shp) & ","
                            set shapeJSON to shapeJSON & q & "height" & q & ":" & («property hght» of shp) & ","
                            set shapeJSON to shapeJSON & q & "fontName" & q & ":" & q & my jsonEscape(fontNameValue) & q & ","
                            set shapeJSON to shapeJSON & q & "fontSize" & q & ":" & fontSizeValue & ","
                            set shapeJSON to shapeJSON & q & "bold" & q & ":" & boldValue & ","
                            set shapeJSON to shapeJSON & q & "italic" & q & ":" & italicValue & ","
                            set shapeJSON to shapeJSON & q & "underline" & q & ":" & underlineValue & ","
                            set shapeJSON to shapeJSON & q & "alignment" & q & ":" & alignmentValue & ","
                            set shapeJSON to shapeJSON & q & "fontColor" & q & ":" & colorValueJSON
                            set shapeJSON to shapeJSON & "}"
                        end if
                    end try
                end if
            """
        }.joined(separator: "\n")

        return """
        on replaceText(findText, replacementText, sourceText)
            set previousDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to findText
            set textItems to text items of sourceText
            set AppleScript's text item delimiters to replacementText
            set joinedText to textItems as text
            set AppleScript's text item delimiters to previousDelimiters
            return joinedText
        end replaceText

        on jsonEscape(sourceText)
            set slash to ASCII character 92
            set escapedText to sourceText as text
            set escapedText to my replaceText(slash, slash & slash, escapedText)
            set escapedText to my replaceText(quote, slash & quote, escapedText)
            set escapedText to my replaceText(return, slash & "n", escapedText)
            set escapedText to my replaceText(linefeed, slash & "n", escapedText)
            set escapedText to my replaceText(tab, slash & "t", escapedText)
            return escapedText
        end jsonEscape

        on jsonBool(value)
            if value is true then return "true"
            if value is false then return "false"
            return "null"
        end jsonBool

        tell application "Microsoft PowerPoint"
            set q to quote
            if (count of presentations) is 0 then return ""
            try
                set presRef to active presentation
            on error
                set presRef to presentation 1
            end try
            set winRef to missing value
            try
                set winRef to active window
            on error
                set winRef to missing value
            end try
            set presName to name of presRef
            set presPath to ""
            try
                set presPath to POSIX path of (full name of presRef as alias)
            end try

            set slideIdx to 0
            set slideRef to missing value
            try
                if winRef is not missing value then
                    set slideRef to slide of view of winRef
                    set slideIdx to slide index of slideRef
                end if
            end try
            if slideIdx is 0 then
                try
                    if winRef is not missing value then
                        set slideRef to slide 1 of slide range of selection of winRef
                        set slideIdx to slide index of slideRef
                    end if
                end try
            end if
            if slideIdx is 0 then
                try
                    set slideRef to slide of view of active window
                    set slideIdx to slide index of slideRef
                end try
            end if
            if slideIdx is 0 then
                try
                    set slideRef to slide 1 of presRef
                    set slideIdx to 1
                end try
            end try
            if slideIdx is 0 then return ""

            set slideName to ""
            try
                set slideName to name of slideRef
            end try

            set shapeCount to count of shapes of slideRef
            set shapeJSON to ""
        \(shapeBlocks)

            return "{" & q & "presentationTitle" & q & ":" & q & my jsonEscape(presName) & q & "," & q & "filePath" & q & ":" & q & my jsonEscape(presPath) & q & "," & q & "slideIndex" & q & ":" & slideIdx & "," & q & "slideTitle" & q & ":" & q & my jsonEscape(slideName) & q & "," & q & "shapes" & q & ":[" & shapeJSON & "]}"
        end tell
        """
    }
}
