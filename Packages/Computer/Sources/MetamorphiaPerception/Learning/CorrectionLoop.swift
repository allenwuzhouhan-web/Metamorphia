import Foundation

/// User correction loop: when the agent clicks the wrong element, the user corrects it.
/// Records corrections, adjusts confidence, extracts confusion patterns.
public enum CorrectionLoop {

    /// A correction submitted by the user.
    public struct Correction: Sendable {
        public let intendedAction: String       // "click the Settings button"
        public let selectedRef: ElementRef      // what the agent actually clicked
        public let correctRef: ElementRef       // what the user said was right
        public let appBundleID: String?
        public let windowTitle: String?

        public init(intendedAction: String, selectedRef: ElementRef, correctRef: ElementRef, appBundleID: String?, windowTitle: String?) {
            self.intendedAction = intendedAction
            self.selectedRef = selectedRef
            self.correctRef = correctRef
            self.appBundleID = appBundleID
            self.windowTitle = windowTitle
        }
    }

    /// Process a user correction: update confidence, store in DB, check for confusion patterns.
    public static func process(
        correction: Correction,
        currentMap: ScreenMap,
        db: ElementDatabase
    ) {
        let selectedElement = currentMap.elements.first(where: { $0.ref == correction.selectedRef })
        let correctElement = currentMap.elements.first(where: { $0.ref == correction.correctRef })

        // 1. Penalize the wrongly-selected element
        if let selected = selectedElement {
            let hash = UnknownElementHandler.elementHash(element: selected, appBundleID: correction.appBundleID)
            db.recordWrongMatch(hash: hash)
        }

        // 2. Reward the correct element
        if let correct = correctElement {
            let hash = UnknownElementHandler.elementHash(element: correct, appBundleID: correction.appBundleID)
            db.recordCorrectMatch(hash: hash)
        }

        // 3. Store the correction record
        let selectedSig = selectedElement.map { UnknownElementHandler.structuralSignature(element: $0) }
        let correctSig = correctElement.map { UnknownElementHandler.structuralSignature(element: $0) }

        db.insertCorrection(
            elementHash: selectedElement.map { UnknownElementHandler.elementHash(element: $0, appBundleID: correction.appBundleID) },
            expectedLabel: correctElement?.label,
            actualLabel: selectedElement?.label ?? "",
            appBundleID: correction.appBundleID,
            windowContext: correction.windowTitle,
            intendedAction: correction.intendedAction,
            selectedSignature: selectedSig,
            correctSignature: correctSig
        )
    }

    /// Submit a correction via the server API.
    /// Simplified version: correct just the label of an element.
    public static func correctLabel(
        ref: ElementRef,
        correctLabel: String,
        currentMap: ScreenMap,
        db: ElementDatabase
    ) {
        guard let element = currentMap.elements.first(where: { $0.ref == ref }) else { return }

        let hash = UnknownElementHandler.elementHash(element: element, appBundleID: currentMap.focusedApp.bundleID)

        // Update the element's custom label in the database
        db.upsertElement(
            hash: hash,
            appBundleID: currentMap.focusedApp.bundleID,
            role: element.role.rawValue,
            label: element.label,
            customLabel: correctLabel,
            structuralSignature: UnknownElementHandler.structuralSignature(element: element),
            confidence: 0.7
        )
    }

    /// Get a summary of confusion patterns for a given app, suitable for LLM context injection.
    public static func confusionSummary(appBundleID: String?, db: ElementDatabase) -> String? {
        let patterns = PatternRecognizer.extractConfusionPatterns(appBundleID: appBundleID, db: db)
        guard !patterns.isEmpty else { return nil }

        var lines: [String] = ["## Known Confusions:"]
        for pattern in patterns.prefix(5) {
            lines.append("- Agent often selects [\(pattern.wrongSignature)] when it should select [\(pattern.correctSignature)] (\(pattern.frequency)x)")
        }
        return lines.joined(separator: "\n")
    }
}
