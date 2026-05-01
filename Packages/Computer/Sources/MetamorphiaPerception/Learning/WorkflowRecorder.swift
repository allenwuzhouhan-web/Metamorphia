import Foundation

/// Records user actions as replayable workflow sequences.
/// Element selectors use structural signatures (not coordinates) for robustness.
public class WorkflowRecorder: @unchecked Sendable {

    // MARK: - Step Model

    /// A single step in a recorded workflow.
    public struct WorkflowStep: Codable, Sendable {
        public let elementSelector: ElementSelector
        public let action: RecordedAction
        public let preState: UIStateSnapshot
        public let postState: UIStateSnapshot?
        public let timestamp: Date

        public init(elementSelector: ElementSelector, action: RecordedAction, preState: UIStateSnapshot, postState: UIStateSnapshot?, timestamp: Date) {
            self.elementSelector = elementSelector
            self.action = action
            self.preState = preState
            self.postState = postState
            self.timestamp = timestamp
        }
    }

    /// Structural selector for finding an element across sessions.
    public struct ElementSelector: Codable, Sendable {
        public let structuralSignature: String
        public let role: String
        public let label: String
        public let appBundleID: String?
        public let parentLabel: String?

        public init(structuralSignature: String, role: String, label: String, appBundleID: String?, parentLabel: String?) {
            self.structuralSignature = structuralSignature
            self.role = role
            self.label = label
            self.appBundleID = appBundleID
            self.parentLabel = parentLabel
        }

        /// Build a selector from a ScreenElement.
        public static func from(element: ScreenElement, parentElement: ScreenElement?) -> ElementSelector {
            ElementSelector(
                structuralSignature: UnknownElementHandler.structuralSignature(element: element),
                role: element.role.rawValue,
                label: element.label,
                appBundleID: element.appBundleID,
                parentLabel: parentElement?.label
            )
        }
    }

    /// An action performed on an element.
    public struct RecordedAction: Codable, Sendable {
        public let type: ActionType
        public let parameters: [String: String]

        public init(type: ActionType, parameters: [String: String] = [:]) {
            self.type = type
            self.parameters = parameters
        }

        public enum ActionType: String, Codable, Sendable {
            case click, doubleClick, rightClick
            case type, paste
            case keyPress
            case scroll
            case drag
        }
    }

    /// A snapshot of UI state for verification during replay.
    public struct UIStateSnapshot: Codable, Sendable {
        public let appName: String
        public let windowTitle: String
        public let interactiveElementCount: Int
        public let contentHash: String

        public init(appName: String, windowTitle: String, interactiveElementCount: Int, contentHash: String) {
            self.appName = appName
            self.windowTitle = windowTitle
            self.interactiveElementCount = interactiveElementCount
            self.contentHash = contentHash
        }

        /// Build from a ScreenMap.
        public static func from(map: ScreenMap) -> UIStateSnapshot {
            UIStateSnapshot(
                appName: map.focusedApp.name,
                windowTitle: map.windows.first(where: { $0.isFocused })?.title ?? "",
                interactiveElementCount: map.metadata.interactiveCount,
                contentHash: String(Snapshot.contentHash(of: map.elements), radix: 16)
            )
        }
    }

    // MARK: - Recording

    private let lock = NSLock()
    private var _isRecording = false
    private var _steps: [WorkflowStep] = []
    private var _name: String = ""
    private var _appBundleID: String?

    public init() {}

    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRecording
    }

    /// Start recording a new workflow.
    public func startRecording(name: String, appBundleID: String?) {
        lock.lock()
        _isRecording = true
        _steps = []
        _name = name
        _appBundleID = appBundleID
        lock.unlock()
    }

    /// Record a step.
    public func recordStep(
        element: ScreenElement,
        parentElement: ScreenElement?,
        action: RecordedAction,
        preMap: ScreenMap,
        postMap: ScreenMap?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard _isRecording else { return }

        let selector = ElementSelector.from(element: element, parentElement: parentElement)
        let preState = UIStateSnapshot.from(map: preMap)
        let postState = postMap.map { UIStateSnapshot.from(map: $0) }

        _steps.append(WorkflowStep(
            elementSelector: selector,
            action: action,
            preState: preState,
            postState: postState,
            timestamp: Date()
        ))
    }

    /// Stop recording and save to database.
    public func stopRecording(db: ElementDatabase) -> String? {
        lock.lock()
        let steps = _steps
        let name = _name
        let appBundleID = _appBundleID
        _isRecording = false
        _steps = []
        lock.unlock()

        guard !steps.isEmpty else { return nil }

        let id = UUID().uuidString
        guard let stepsJSON = encodeSteps(steps) else { return nil }

        db.saveWorkflow(id: id, name: name, appBundleID: appBundleID, stepsJSON: stepsJSON)
        return id
    }

    /// Discard the current recording.
    public func discardRecording() {
        lock.lock()
        _isRecording = false
        _steps = []
        lock.unlock()
    }

    // MARK: - Replay

    /// Resolve an element selector against a current ScreenMap.
    /// Match priority: structural signature → role+label → parent context.
    public static func resolveSelector(_ selector: ElementSelector, in map: ScreenMap) -> ScreenElement? {
        // Priority 1: Exact structural signature match
        for el in map.elements {
            let sig = UnknownElementHandler.structuralSignature(element: el)
            if sig == selector.structuralSignature {
                return el
            }
        }

        // Priority 2: Role + label match
        for el in map.elements {
            if el.role.rawValue == selector.role && el.label == selector.label {
                return el
            }
        }

        // Priority 3: Fuzzy label match (case-insensitive, prefix)
        let selectorLower = selector.label.lowercased()
        for el in map.elements {
            if el.role.rawValue == selector.role && el.label.lowercased().hasPrefix(selectorLower) {
                return el
            }
        }

        return nil
    }

    /// Verify that the current UI state matches expected pre-state.
    public static func verifyPreState(_ expected: UIStateSnapshot, current: ScreenMap) -> Float {
        var score: Float = 0
        if current.focusedApp.name == expected.appName { score += 0.4 }
        let windowTitle = current.windows.first(where: { $0.isFocused })?.title ?? ""
        if windowTitle == expected.windowTitle { score += 0.3 }
        let countDiff = abs(current.metadata.interactiveCount - expected.interactiveElementCount)
        score += 0.3 * max(0, 1.0 - Float(countDiff) / 20.0)
        return score
    }

    // MARK: - Serialization

    private func encodeSteps(_ steps: [WorkflowStep]) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(steps) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode steps from JSON.
    public static func decodeSteps(_ json: String) -> [WorkflowStep]? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode([WorkflowStep].self, from: data)
    }
}
