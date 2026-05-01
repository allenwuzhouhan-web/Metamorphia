import CoreGraphics
import Foundation

public enum TriggerReason: Hashable, Sendable {
    // Workspace
    case appActivated(pid: pid_t, bundleID: String?)
    case appTerminated(pid: pid_t)
    case systemWake
    case systemSleep
    case displayConfigurationChanged

    // AX (per-pid push)
    case axFocusedElementChanged(pid: pid_t)
    case axValueChanged(pid: pid_t, roleHint: String?)
    case axSelectedTextChanged(pid: pid_t)
    case axWindowCreated(pid: pid_t)
    case axWindowMoved(pid: pid_t)
    case axTitleChanged(pid: pid_t)

    // Non-AX push
    case pasteboardChanged(changeCount: Int)
    case fsEvent(path: String)

    // Reconciliation
    case heartbeat(sinceLast: TimeInterval)
    case forcedRefresh(origin: String)

    public var urgency: UInt8 {
        switch self {
        case .appActivated:                return 250
        case .appTerminated:               return 240
        case .axFocusedElementChanged:     return 200
        case .axSelectedTextChanged:       return 180
        case .systemWake:                  return 170
        case .forcedRefresh:               return 160
        case .axWindowCreated:             return 140
        case .axValueChanged:              return 120
        case .axWindowMoved:               return 100
        case .displayConfigurationChanged: return 90
        case .axTitleChanged:              return 80
        case .pasteboardChanged:           return 60
        case .fsEvent:                     return 50
        case .systemSleep:                 return 30
        case .heartbeat:                   return 10
        }
    }

    public var affectedLanes: LaneSet {
        switch self {
        case .appActivated:
            return [.focus, .windows, .axTree, .menus, .dHash]
        case .appTerminated:
            return [.focus, .windows]
        case .axFocusedElementChanged:
            return [.axTree, .selection]
        case .axValueChanged:
            return [.axTree]
        case .axSelectedTextChanged:
            return [.selection]
        case .axWindowCreated:
            return [.windows, .axTree]
        case .axWindowMoved:
            return [.windows]
        case .axTitleChanged:
            return [.axTree, .windows]
        case .systemWake:
            return .all
        case .systemSleep:
            return []
        case .displayConfigurationChanged:
            return [.displays, .windows]
        case .pasteboardChanged:
            return [.pasteboard]
        case .fsEvent:
            return [.documents]
        case .heartbeat:
            return .all
        case .forcedRefresh:
            return .all
        }
    }
}

public struct LaneSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let focus      = LaneSet(rawValue: 1 << 0)
    public static let windows    = LaneSet(rawValue: 1 << 1)
    public static let displays   = LaneSet(rawValue: 1 << 2)
    public static let axTree     = LaneSet(rawValue: 1 << 3)
    public static let menus      = LaneSet(rawValue: 1 << 4)
    public static let dHash      = LaneSet(rawValue: 1 << 5)
    public static let ocr        = LaneSet(rawValue: 1 << 6)
    public static let browserDOM = LaneSet(rawValue: 1 << 7)
    public static let pasteboard = LaneSet(rawValue: 1 << 8)
    public static let documents  = LaneSet(rawValue: 1 << 9)
    public static let selection  = LaneSet(rawValue: 1 << 10)

    public static let all: LaneSet = [.focus, .windows, .displays, .axTree, .menus, .dHash, .ocr, .browserDOM, .pasteboard, .documents, .selection]
}
