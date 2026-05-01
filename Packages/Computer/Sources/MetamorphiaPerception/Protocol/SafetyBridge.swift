import Foundation

// MARK: - Safety Bridge

/// Shared safety context that flows between Computer's perception-level safety
/// and the agent's tool-level safety (e.g., Executer's SecurityGateway).
public enum SafetyBridge {

    // MARK: - Extended Safety Report

    /// Richer safety report that includes actionable context for agent-level decisions.
    public struct ExtendedSafetyReport: Sendable {
        /// The base perception-level report.
        public let base: SafetyReport

        /// Detailed danger results with reasons (not just refs).
        public let dangerDetails: [DangerDetector.DangerResult]

        /// Sensitive field details with types (password, credit card, etc.)
        public let sensitiveDetails: [SensitiveFieldDetector.SensitiveResult]

        /// Whether the current context is elevated (settings, admin panels).
        public let isElevatedContext: Bool

        /// Current app bundle ID for cross-referencing.
        public let appBundleID: String?

        /// Current window title for cross-referencing.
        public let windowTitle: String

        public init(
            base: SafetyReport, dangerDetails: [DangerDetector.DangerResult],
            sensitiveDetails: [SensitiveFieldDetector.SensitiveResult],
            isElevatedContext: Bool, appBundleID: String?, windowTitle: String
        ) {
            self.base = base
            self.dangerDetails = dangerDetails
            self.sensitiveDetails = sensitiveDetails
            self.isElevatedContext = isElevatedContext
            self.appBundleID = appBundleID
            self.windowTitle = windowTitle
        }
    }

    // MARK: - Agent Safety Feedback

    /// Feedback from the agent's security system back to Computer.
    public struct AgentSafetyFeedback: Sendable {
        public let toolName: String
        public let elementRef: ElementRef?
        public let blocked: Bool
        public let reason: String
        public let agentTier: Int       // 0=safe, 1=normal, 2=elevated, 3=critical

        public init(toolName: String, elementRef: ElementRef?, blocked: Bool, reason: String, agentTier: Int) {
            self.toolName = toolName
            self.elementRef = elementRef
            self.blocked = blocked
            self.reason = reason
            self.agentTier = agentTier
        }
    }

    // MARK: - Building Extended Reports

    /// Build an extended safety report from a ScreenMap.
    /// This is what agents should use instead of the basic SafetyReport.
    public static func buildExtendedReport(
        elements: [ScreenElement],
        appBundleID: String?,
        windowTitle: String
    ) -> ExtendedSafetyReport {
        let context = DangerDetector.ScanContext(appBundleID: appBundleID, windowTitle: windowTitle)
        let dangerResults = DangerDetector.scan(elements: elements, context: context)
        let sensitiveResults = SensitiveFieldDetector.scan(elements: elements)

        let dangerRefs = dangerResults.filter { $0.level >= .dangerous }.map { $0.ref }
        let sensitiveRefs = sensitiveResults.map { $0.ref }

        let base = SafetyReport(
            dangers: dangerRefs,
            sensitive: sensitiveRefs,
            driftDetected: false
        )

        return ExtendedSafetyReport(
            base: base,
            dangerDetails: dangerResults,
            sensitiveDetails: sensitiveResults,
            isElevatedContext: context.isElevated,
            appBundleID: appBundleID,
            windowTitle: windowTitle
        )
    }

    // MARK: - Processing Agent Feedback

    /// Process feedback from the agent's security gateway.
    /// Updates Computer's learning DB with safety-relevant signals.
    public static func processAgentFeedback(_ feedback: AgentSafetyFeedback, db: ElementDatabase) {
        guard let ref = feedback.elementRef else { return }

        // If the agent blocked an action on an element, lower its confidence
        if feedback.blocked {
            // Find the element hash — we can't look it up here without the map,
            // so we store the feedback as a correction-like record
            db.insertCorrection(
                elementHash: nil,
                expectedLabel: "safe_action",
                actualLabel: feedback.reason,
                appBundleID: nil,
                windowContext: nil,
                intendedAction: feedback.toolName,
                selectedSignature: ref.description,
                correctSignature: nil
            )
        }
    }

    // MARK: - Safety-Aware Tool Tier Recommendation

    /// Given Computer's danger assessment of an element, recommend a minimum safety tier
    /// for the agent's tool execution. Agents can use this to escalate their SecurityGateway tier.
    public static func recommendTier(for dangerResult: DangerDetector.DangerResult) -> Int {
        switch dangerResult.level {
        case .safe:      return 0
        case .caution:   return 2  // Elevated — log + LLM risk assessment
        case .dangerous: return 3  // Critical — require user confirmation
        }
    }
}

// MARK: - ScreenElement / ScreenMap Redaction

public extension ScreenElement {
    /// Returns a copy of this element with its `value` field replaced. Used by
    /// `ScreenMap.redactedForLLM()` to mask sensitive field contents while
    /// preserving structural metadata (role, label, bounds, refs) so the agent
    /// can still reason about form layout.
    func withValue(_ newValue: String) -> ScreenElement {
        ScreenElement(
            ref: ref,
            role: role,
            subrole: subrole,
            label: label,
            value: newValue,
            bounds: bounds,
            clickPoint: clickPoint,
            state: state,
            actions: actions,
            parentRef: parentRef,
            depth: depth,
            source: source,
            confidence: confidence,
            appBundleID: appBundleID,
            windowIndex: windowIndex,
            displayIndex: displayIndex
        )
    }
}

public extension ScreenMap {
    /// Return a copy of this map with every sensitive field's `value` replaced
    /// by a type-tagged placeholder (`••••••••` for passwords, masked digits
    /// for credit cards, etc.). Tool results that reach the LLM must pass
    /// through this first so credentials never round-trip to a remote model.
    ///
    /// Runs `SensitiveFieldDetector.scan` once over the whole element list,
    /// then constructs a new element array with the sensitive entries masked
    /// via `SensitiveFieldDetector.redact(_:type:)`. All other structural
    /// metadata is preserved so the agent can still describe or click the
    /// redacted field.
    func redactedForLLM() -> ScreenMap {
        let sensitive = SensitiveFieldDetector.scan(elements: elements)
        guard !sensitive.isEmpty else { return self }

        var typeByRef: [ElementRef: SensitiveFieldDetector.SensitivityType] = [:]
        typeByRef.reserveCapacity(sensitive.count)
        for result in sensitive {
            typeByRef[result.ref] = result.type
        }

        let redactedElements = elements.map { element -> ScreenElement in
            guard let type = typeByRef[element.ref], !element.value.isEmpty else {
                return element
            }
            let masked = SensitiveFieldDetector.redact(element.value, type: type)
            return element.withValue(masked)
        }

        return ScreenMap(
            timestamp: timestamp,
            captureMs: captureMs,
            displays: displays,
            focusedApp: focusedApp,
            windows: windows,
            elements: redactedElements,
            navigation: navigation,
            safety: safety,
            metadata: metadata,
            browserDOM: browserDOM,
            menus: menus
        )
    }
}
