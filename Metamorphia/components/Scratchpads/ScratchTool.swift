import SwiftUI

/// The six scratchpad tools that live in the notch tray and can be torn out
/// into floating panels. Each case maps 1:1 to a real tile view.
public enum ScratchTool: String, CaseIterable, Identifiable, Sendable {
    case regex
    case notes
    case diff
    case qr
    case palette
    case translate

    public var id: String { rawValue }

    /// Short, capitalized label shown under the tray icon and in the panel title bar.
    public var title: String {
        switch self {
        case .regex: return "Regex"
        case .notes: return "Notes"
        case .diff: return "Diff"
        case .qr: return "QR"
        case .palette: return "Palette"
        case .translate: return "Translate"
        }
    }

    /// A distinct SF Symbol per tool. All ship with macOS 14.
    public var systemImage: String {
        switch self {
        case .regex: return "asterisk.circle"
        case .notes: return "note.text"
        case .diff: return "plusminus"
        case .qr: return "qrcode"
        case .palette: return "eyedropper.halffull"
        case .translate: return "character.bubble"
        }
    }
}
