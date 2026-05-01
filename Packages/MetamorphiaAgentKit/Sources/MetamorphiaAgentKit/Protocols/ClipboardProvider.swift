import Foundation

/// Inspects the system clipboard without importing AppKit into the package.
///
/// App target supplies a concrete implementation that reads `NSPasteboard.general`;
/// the package sees only this protocol. Returned metadata describes the *kind*
/// of content on the clipboard (text length, file name, etc.) — the middleware
/// does NOT read actual clipboard content, only what kind of thing is there.
public protocol ClipboardProvider: Sendable {
    /// Returns a snapshot of what's on the clipboard right now, or `nil` if empty.
    func inspect() -> ClipboardInspection?
}

/// Kind + metadata for a clipboard snapshot.
public struct ClipboardInspection: Sendable {
    public enum Kind: Sendable, Equatable {
        case text(characterCount: Int)
        case url
        case image
        case file(name: String)
    }

    public let kind: Kind
    /// NSPasteboard change counter (monotonically increasing). Lets callers
    /// detect whether the clipboard changed since a prior inspection.
    public let changeCount: Int

    public init(kind: Kind, changeCount: Int) {
        self.kind = kind
        self.changeCount = changeCount
    }
}

/// A clipboard provider that always returns `nil`. Used in tests and when
/// the user has opted out of clipboard-aware context gathering.
public struct NullClipboardProvider: ClipboardProvider {
    public init() {}
    public func inspect() -> ClipboardInspection? { nil }
}
