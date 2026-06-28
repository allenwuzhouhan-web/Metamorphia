import SwiftUI

// MARK: - Palette Scratchpad
//
// The Palette scratchpad reuses the full color-palette experience from the color
// picker: drop a logo/image and it pulls the major colors out (robust OKLab
// extraction that never collapses a colorful image to one swatch), plots them on
// a color wheel, and lets you pick a color to fan out 5 variants. Hosting
// `ColorPaletteView` keeps a single source of truth for the whole feature.

@MainActor public struct PaletteScratchpadView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            ColorPaletteView(wheelDiameter: 220)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
    }
}
