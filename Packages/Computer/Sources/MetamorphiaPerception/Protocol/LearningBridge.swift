import Foundation

// MARK: - Learning Bridge

/// Bidirectional learning signals between Computer and its consumers (e.g., Executer).
/// Computer learns from agent outcomes; agents learn from Computer's observations.
public enum LearningBridge {

    // MARK: - Signals FROM Agent → Computer

    /// An agent reports that a UI action succeeded or failed.
    public struct ActionOutcome: Sendable {
        public let elementRef: ElementRef
        public let action: String           // "click", "type", "hotkey", etc.
        public let succeeded: Bool
        public let appBundleID: String?
        public let errorContext: String?     // nil on success
        public let preSnapshotHash: UInt64?  // optional for richer analysis
        public let postSnapshotHash: UInt64?

        public init(
            elementRef: ElementRef, action: String, succeeded: Bool,
            appBundleID: String?, errorContext: String? = nil,
            preSnapshotHash: UInt64? = nil, postSnapshotHash: UInt64? = nil
        ) {
            self.elementRef = elementRef
            self.action = action
            self.succeeded = succeeded
            self.appBundleID = appBundleID
            self.errorContext = errorContext
            self.preSnapshotHash = preSnapshotHash
            self.postSnapshotHash = postSnapshotHash
        }
    }

    /// An agent reports a user preference that affects UI interaction.
    public struct UserPreferenceSignal: Sendable {
        public let key: String              // e.g., "prefer_shortcuts", "double_click_speed"
        public let value: String
        public let appBundleID: String?     // nil = global preference

        public init(key: String, value: String, appBundleID: String? = nil) {
            self.key = key
            self.value = value
            self.appBundleID = appBundleID
        }
    }

    /// An agent reports a completed workflow sequence.
    public struct WorkflowOutcome: Sendable {
        public let name: String
        public let appBundleID: String?
        public let steps: [(elementRef: String, action: String)]
        public let succeeded: Bool
        public let totalDurationMs: Int

        public init(name: String, appBundleID: String?, steps: [(elementRef: String, action: String)], succeeded: Bool, totalDurationMs: Int) {
            self.name = name
            self.appBundleID = appBundleID
            self.steps = steps
            self.succeeded = succeeded
            self.totalDurationMs = totalDurationMs
        }
    }

    // MARK: - Signals FROM Computer → Agent

    /// Computer's learned knowledge about an app, ready for agent consumption.
    public struct AppKnowledge: Sendable {
        public let bundleID: String
        public let appName: String
        public let needsOCR: Bool
        public let axCoveragePercent: Float
        public let confusionPatterns: [String]   // pre-formatted for LLM injection
        public let knownShortcuts: [String]      // "⌘S — File > Save"
        public let elementReliability: Float     // 0-1, how reliable AX elements are

        public init(bundleID: String, appName: String, needsOCR: Bool,
                    axCoveragePercent: Float, confusionPatterns: [String],
                    knownShortcuts: [String], elementReliability: Float) {
            self.bundleID = bundleID
            self.appName = appName
            self.needsOCR = needsOCR
            self.axCoveragePercent = axCoveragePercent
            self.confusionPatterns = confusionPatterns
            self.knownShortcuts = knownShortcuts
            self.elementReliability = elementReliability
        }
    }

    // MARK: - Processing

    /// Process an action outcome from an agent and update Computer's learning DB.
    public static func processActionOutcome(_ outcome: ActionOutcome, map: ScreenMap, db: ElementDatabase) {
        guard let element = map.elements.first(where: { $0.ref == outcome.elementRef }) else { return }
        let hash = UnknownElementHandler.elementHash(element: element, appBundleID: outcome.appBundleID)

        if outcome.succeeded {
            db.recordCorrectMatch(hash: hash)
        } else {
            db.recordWrongMatch(hash: hash)
            // Log the failure for pattern extraction
            db.logFailure(
                workflowID: nil,
                stepIndex: 0,
                expectedStateJSON: nil,
                actualStateJSON: nil,
                elementRef: outcome.elementRef.description,
                actionAttempted: outcome.action,
                errorDescription: outcome.errorContext,
                appBundleID: outcome.appBundleID
            )
        }
    }

    /// Process a workflow outcome and store/update it in Computer's workflow DB.
    public static func processWorkflowOutcome(_ outcome: WorkflowOutcome, db: ElementDatabase) {
        let stepsJSON: String
        if let data = try? JSONSerialization.data(withJSONObject:
            outcome.steps.map { ["ref": $0.elementRef, "action": $0.action] }
        ), let str = String(data: data, encoding: .utf8) {
            stepsJSON = str
        } else {
            stepsJSON = "[]"
        }

        let workflowID = UUID().uuidString
        db.saveWorkflow(
            id: workflowID,
            name: outcome.name,
            appBundleID: outcome.appBundleID,
            stepsJSON: stepsJSON
        )

        if outcome.succeeded {
            db.recordReplay(workflowID: workflowID, success: true)
        }
    }

    /// Get Computer's learned knowledge about an app, ready for agent injection.
    public static func getAppKnowledge(bundleID: String, db: ElementDatabase) -> AppKnowledge? {
        guard let profile = db.getAppProfile(bundleID: bundleID) else { return nil }

        let confusions: [String]
        if let summary = CorrectionLoop.confusionSummary(appBundleID: bundleID, db: db) {
            confusions = summary.split(separator: "\n").map(String.init)
        } else {
            confusions = []
        }

        let axCoverage = profile.axCoveragePct ?? 0

        return AppKnowledge(
            bundleID: bundleID,
            appName: profile.appName,
            needsOCR: profile.needsOCR,
            axCoveragePercent: axCoverage,
            confusionPatterns: confusions,
            knownShortcuts: [],  // Shortcuts are discovered live, not stored
            elementReliability: axCoverage
        )
    }
}
