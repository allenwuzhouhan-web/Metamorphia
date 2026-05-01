import Foundation

/// Immutable, identity-bearing snapshot for diffing across captures.
public struct Snapshot: Sendable {
    public let id: UInt64
    public let map: ScreenMap

    public init(id: UInt64, map: ScreenMap) {
        self.id = id
        self.map = map
    }

    /// Content hash for fast change detection. Based on element refs + labels + states.
    public static func contentHash(of elements: [ScreenElement]) -> UInt64 {
        var hash: UInt64 = 5381
        for el in elements {
            for byte in el.role.rawValue.utf8 {
                hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
            }
            for byte in el.label.utf8 {
                hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
            }
            hash = ((hash &<< 5) &+ hash) &+ UInt64(el.state.rawValue)
        }
        return hash
    }
}
