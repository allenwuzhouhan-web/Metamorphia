/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI

/// A hue/saturation color wheel that plots extracted colors as dots, and — when
/// one is selected — lets a family of 5 variants *emerge* from it.
///
/// Angle = hue (red at the top, sweeping clockwise), distance from center =
/// saturation. Near-neutral colors have no meaningful hue, so they sit on the
/// central value axis (dark low, light high).
struct ColorWheelView: View {
    let swatches: [LogoPaletteSwatch]
    let selectedID: UUID?
    var variants: [ColorVariant] = []
    var variantsActive: Bool = false
    var diameter: CGFloat = 240
    var growth: CGFloat = 1.10
    /// A variant slot the strip is hovering — the matching wheel dot lifts.
    var highlightedVariantSlot: Int? = nil
    let onSelect: (LogoPaletteSwatch) -> Void
    var onTapVariant: (ColorVariant) -> Void = { _ in }
    var onTapEmpty: () -> Void = {}

    @State private var hoveredID: UUID?
    @State private var hoveredVariantSlot: Int?

    // Springs tuned to match the app's notch idiom.
    private let emerge = Animation.spring(response: 0.42, dampingFraction: 0.82)
    private let settle = Animation.smooth(duration: 0.25)

    private var radius: CGFloat { diameter / 2 }
    private var usableRadius: CGFloat { radius - 22 }

    private var hueColors: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map {
            Color(hue: $0, saturation: 1, brightness: 1)
        }
    }

    /// Where the selected base dot sits — variants emerge from (and retract to) here.
    private var parentPosition: CGPoint {
        if let sel = swatches.first(where: { $0.id == selectedID }) {
            return position(forHSV: sel.color.hsv)
        }
        return CGPoint(x: radius, y: radius)
    }

    var body: some View {
        ZStack {
            wheel

            connectors

            ForEach(swatches) { swatch in
                baseDot(for: swatch)
            }

            ForEach(variants) { variant in
                variantDot(variant)
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(variantsActive ? growth : 1.0, anchor: .center)
        .animation(emerge, value: variantsActive)
        // Reserve the grown footprint so emergence doesn't reflow the panel.
        .frame(width: diameter * growth, height: diameter * growth)
    }

    // MARK: Wheel face

    private var wheel: some View {
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(colors: hueColors),
                    center: .center,
                    angle: .degrees(-90)
                )
            )
            .overlay(
                RadialGradient(
                    gradient: Gradient(colors: [.white, .white.opacity(0)]),
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(variantsActive ? 0.10 : 0.18), lineWidth: 1))
            .overlay(
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 4, height: 4)
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .contentShape(Circle())
            .onTapGesture { onTapEmpty() }
            .animation(settle, value: variantsActive)
    }

    // MARK: Connectors (subtle lines from the parent dot to each variant)

    private var connectors: some View {
        Canvas { ctx, _ in
            guard variantsActive else { return }
            let parent = parentPosition
            for variant in variants {
                var path = Path()
                path.move(to: parent)
                path.addLine(to: position(forHSV: variant.color.hsv))
                ctx.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 1)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(variantsActive ? 1 : 0)
        .animation(settle.delay(variantsActive ? 0.22 : 0), value: variantsActive)
        .allowsHitTesting(false)
    }

    // MARK: Base dots

    private func baseDot(for swatch: LogoPaletteSwatch) -> some View {
        let isSelected = swatch.id == selectedID
        let isHovered = swatch.id == hoveredID
        let recede = variantsActive && !isSelected
        let size = dotSize(for: swatch)

        let scale: CGFloat = {
            if isSelected { return variantsActive ? 1.22 : (isHovered ? 1.18 : 1.0) }
            if recede { return 0.82 }
            return isHovered ? 1.18 : 1.0
        }()

        return Circle()
            .fill(swatch.color.color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 3 : 2))
            .overlay(Circle().stroke(.black.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: (isHovered || isSelected) ? 5 : 2, y: 1)
            .scaleEffect(scale)
            .opacity(recede ? 0.28 : 1.0)
            .position(position(forHSV: swatch.color.hsv, radiusScale: recede ? 0.94 : 1.0))
            .animation(emerge, value: variantsActive)
            .animation(.easeInOut(duration: 0.18), value: isHovered)
            .animation(.easeInOut(duration: 0.18), value: isSelected)
            .onHover { hovering in
                if hovering { hoveredID = swatch.id }
                else if hoveredID == swatch.id { hoveredID = nil }
            }
            .onTapGesture { onSelect(swatch) }
            .zIndex(isSelected ? 2 : 1)
    }

    // MARK: Variant dots

    private func variantDot(_ variant: ColorVariant) -> some View {
        let lifted = hoveredVariantSlot == variant.slot || highlightedVariantSlot == variant.slot
        let target = position(forHSV: variant.color.hsv)
        let pos = variantsActive ? target : parentPosition

        return Circle()
            .fill(variant.color.color)
            .frame(width: 15, height: 15)
            .overlay(Circle().stroke(.white, lineWidth: lifted ? 2.5 : 1.8))
            .overlay(Circle().stroke(.black.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: lifted ? 4 : 2, y: 1)
            .scaleEffect(variantsActive ? (lifted ? 1.35 : 1.0) : 0.01)
            .opacity(variantsActive ? 1 : 0)
            .position(pos)
            .zIndex(3)
            .animation(emerge.delay(Double(variant.slot) * 0.045), value: variantsActive)
            .animation(emerge, value: target)
            .animation(.easeInOut(duration: 0.15), value: lifted)
            .onHover { hovering in
                if hovering { hoveredVariantSlot = variant.slot }
                else if hoveredVariantSlot == variant.slot { hoveredVariantSlot = nil }
            }
            .onTapGesture { onTapVariant(variant) }
    }

    // MARK: Geometry

    private func position(forHSV hsv: (hue: Double, saturation: Double, value: Double),
                          radiusScale: CGFloat = 1.0) -> CGPoint {
        let center = CGPoint(x: radius, y: radius)

        if hsv.saturation < 0.08 {
            // Neutral — vertical value axis (light up, dark down).
            let offset = CGFloat((hsv.value - 0.5) * 2.0) * usableRadius * 0.7 * radiusScale
            return CGPoint(x: center.x, y: center.y - offset)
        }

        let angle = (hsv.hue - 90.0) * .pi / 180.0
        let r = CGFloat(hsv.saturation) * usableRadius * radiusScale
        return CGPoint(x: center.x + r * CGFloat(cos(angle)),
                       y: center.y + r * CGFloat(sin(angle)))
    }

    private func dotSize(for swatch: LogoPaletteSwatch) -> CGFloat {
        18 + min(CGFloat(swatch.weight), 0.45) * 30
    }
}

#Preview {
    let samples = PickedColor.sampleColors.map { LogoPaletteSwatch(color: $0, weight: 0.2) }
    let vars = variants(of: samples[0].color, scheme: .monochromatic)
        .enumerated().map { ColorVariant(slot: $0.offset, color: $0.element) }
    return ColorWheelView(
        swatches: samples,
        selectedID: samples.first?.id,
        variants: vars,
        variantsActive: true,
        onSelect: { _ in }
    )
    .padding(60)
    .background(Color.black)
}
