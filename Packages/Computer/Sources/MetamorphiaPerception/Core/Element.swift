import Foundation
import CoreGraphics

// MARK: - Screen Element

/// A single discoverable element on screen — button, text field, label, etc.
public struct ScreenElement: Sendable {
    public let ref: ElementRef
    public let role: ElementRole
    public let subrole: String
    public let label: String
    public let value: String
    public let bounds: CGRect?
    public let clickPoint: CGPoint?
    public let state: ElementState
    public let actions: [ElementAction]
    public let parentRef: ElementRef?
    public let depth: Int
    public let source: ElementSource
    public let confidence: Float
    public let appBundleID: String?
    public let windowIndex: Int
    /// Index of the display (into `ScreenMap.displays`) the element lives on.
    /// Resolved from the element's click point / bounds center at capture time.
    /// Defaults to `0` — the main display — for elements without spatial info
    /// or for single-display captures.
    public let displayIndex: Int
    /// CSS selector built by `BrowserDOMJoiner` when the element is inside a
    /// browser window and a matching DOM node was found. Enables the CDP
    /// execution path in `SemanticExecutor` — `press(ref)` on a DOM-joined
    /// element runs `document.querySelector(sel).click()` instead of synthesising
    /// a cursor click. Nil for native-AX-only elements.
    public let domSelector: String?
    /// Chrome DevTools Protocol node id for the matched DOM element, when
    /// available. Stable within a CDP session, useful for subsequent
    /// per-node CDP queries without re-running the selector.
    public let domNodeId: Int?

    public init(
        ref: ElementRef,
        role: ElementRole,
        subrole: String,
        label: String,
        value: String,
        bounds: CGRect?,
        clickPoint: CGPoint?,
        state: ElementState,
        actions: [ElementAction],
        parentRef: ElementRef?,
        depth: Int,
        source: ElementSource,
        confidence: Float,
        appBundleID: String?,
        windowIndex: Int,
        displayIndex: Int = 0,
        domSelector: String? = nil,
        domNodeId: Int? = nil
    ) {
        self.ref = ref
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.bounds = bounds
        self.clickPoint = clickPoint
        self.state = state
        self.actions = actions
        self.parentRef = parentRef
        self.depth = depth
        self.source = source
        self.confidence = confidence
        self.appBundleID = appBundleID
        self.windowIndex = windowIndex
        self.displayIndex = displayIndex
        self.domSelector = domSelector
        self.domNodeId = domNodeId
    }

    /// Produce a copy with the DOM annotations filled in. Used by
    /// `BrowserDOMJoiner` after matching this element's bounds+role to a
    /// DOM interactive node. Returns a new value (ScreenElement is immutable).
    public func annotatingDOM(selector: String, nodeId: Int?) -> ScreenElement {
        ScreenElement(
            ref: ref, role: role, subrole: subrole, label: label, value: value,
            bounds: bounds, clickPoint: clickPoint, state: state, actions: actions,
            parentRef: parentRef, depth: depth, source: source, confidence: confidence,
            appBundleID: appBundleID, windowIndex: windowIndex, displayIndex: displayIndex,
            domSelector: selector, domNodeId: nodeId
        )
    }
}

// MARK: - Element Role

/// Normalized element type — maps raw AX roles to a clean enum.
public enum ElementRole: String, Sendable {
    // Interactive
    case button
    case textField
    case textArea
    case checkbox
    case radioButton
    case popUpButton
    case comboBox
    case slider
    case stepper
    case toggle
    case link
    case tab
    case menuItem
    case menuBarItem
    case toolbarItem
    case colorWell

    // Containers
    case window
    case group
    case scrollArea
    case table
    case outline
    case list
    case tabGroup
    case toolbar
    case menuBar
    case splitGroup
    case sheet
    case dialog

    // Content
    case staticText
    case image
    case webArea
    case progressIndicator

    // OCR-derived
    case ocrText
    case ocrButton

    // Unknown
    case unknown

    /// Map raw AX role string to our typed enum.
    public static func from(axRole: String) -> ElementRole {
        switch axRole {
        case "AXButton": return .button
        case "AXTextField": return .textField
        case "AXTextArea": return .textArea
        case "AXCheckBox": return .checkbox
        case "AXRadioButton": return .radioButton
        case "AXPopUpButton": return .popUpButton
        case "AXComboBox": return .comboBox
        case "AXSlider": return .slider
        case "AXIncrementor": return .stepper
        case "AXLink": return .link
        case "AXTab": return .tab
        case "AXMenuItem": return .menuItem
        case "AXMenuBarItem": return .menuBarItem
        case "AXColorWell": return .colorWell
        case "AXWindow": return .window
        case "AXGroup": return .group
        case "AXScrollArea": return .scrollArea
        case "AXTable": return .table
        case "AXOutline": return .outline
        case "AXList": return .list
        case "AXTabGroup": return .tabGroup
        case "AXToolbar": return .toolbar
        case "AXMenuBar": return .menuBar
        case "AXSplitGroup": return .splitGroup
        case "AXSheet": return .sheet
        case "AXStaticText": return .staticText
        case "AXImage": return .image
        case "AXWebArea": return .webArea
        case "AXProgressIndicator": return .progressIndicator
        default: return .unknown
        }
    }

    public var isInteractive: Bool {
        switch self {
        case .button, .textField, .textArea, .checkbox, .radioButton,
             .popUpButton, .comboBox, .slider, .stepper, .toggle,
             .link, .tab, .menuItem, .menuBarItem, .toolbarItem,
             .colorWell, .ocrButton:
            return true
        default:
            return false
        }
    }

    public var isContainer: Bool {
        switch self {
        case .window, .group, .scrollArea, .table, .outline,
             .list, .tabGroup, .toolbar, .menuBar, .splitGroup,
             .sheet, .dialog:
            return true
        default:
            return false
        }
    }
}

// MARK: - Element State

/// Bitfield of element states — can combine multiple (e.g., enabled + focused).
public struct ElementState: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let enabled   = ElementState(rawValue: 1 << 0)
    public static let disabled  = ElementState(rawValue: 1 << 1)
    public static let focused   = ElementState(rawValue: 1 << 2)
    public static let selected  = ElementState(rawValue: 1 << 3)
    public static let expanded  = ElementState(rawValue: 1 << 4)
    public static let checked   = ElementState(rawValue: 1 << 5)
    public static let loading   = ElementState(rawValue: 1 << 6)
    public static let offScreen = ElementState(rawValue: 1 << 7)
    public static let password  = ElementState(rawValue: 1 << 8)
    public static let required  = ElementState(rawValue: 1 << 9)

    /// Human-readable state names for JSON output.
    public var names: [String] {
        var result: [String] = []
        if contains(.enabled)   { result.append("enabled") }
        if contains(.disabled)  { result.append("disabled") }
        if contains(.focused)   { result.append("focused") }
        if contains(.selected)  { result.append("selected") }
        if contains(.expanded)  { result.append("expanded") }
        if contains(.checked)   { result.append("checked") }
        if contains(.loading)   { result.append("loading") }
        if contains(.offScreen) { result.append("offscreen") }
        if contains(.password)  { result.append("password") }
        if contains(.required)  { result.append("required") }
        return result
    }
}

// MARK: - Element Action

/// Actions that can be performed on an element.
public enum ElementAction: String, Sendable {
    case press
    case increment
    case decrement
    case confirm
    case cancel
    case showMenu
    case pick        // color well, date picker
    case scroll
    case delete
    case raise       // bring window to front

    /// Map raw AX action names to typed enum.
    public static func from(axAction: String) -> ElementAction? {
        switch axAction {
        case "AXPress": return .press
        case "AXIncrement": return .increment
        case "AXDecrement": return .decrement
        case "AXConfirm": return .confirm
        case "AXCancel": return .cancel
        case "AXShowMenu": return .showMenu
        case "AXPick": return .pick
        case "AXScrollToVisible": return .scroll
        case "AXDelete": return .delete
        case "AXRaise": return .raise
        default: return nil
        }
    }
}

// MARK: - Element Source

/// How this element was discovered.
public enum ElementSource: String, Sendable {
    case accessibility = "ax"
    case ocr = "ocr"
    case fused = "fused"
}
