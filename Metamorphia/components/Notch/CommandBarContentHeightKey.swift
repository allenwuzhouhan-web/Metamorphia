import SwiftUI

/// Propagates the measured intrinsic height of the command bar's content up
/// to its parent so the notch window can resize to fit. Chosen over a
/// `GeometryReader`-driven `.frame` because reading geometry at the root
/// introduces implicit infinite frames that defeat `.fixedSize`; chosen over
/// `.onGeometryChange` because it's macOS 14+ only.
struct CommandBarContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
