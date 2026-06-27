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

/// A hue/saturation color wheel that plots a set of extracted colors as dots.
///
/// Angle = hue (red at the top, sweeping clockwise), distance from center =
/// saturation. Near-neutral colors don't have a meaningful hue, so they sit on
/// the central value axis instead — dark low, light high — which keeps black and
/// white from piling up on the exact center.
struct ColorWheelView: View {
    let swatches: [LogoPaletteSwatch]
    let selectedID: UUID?
    var diameter: CGFloat = 240
    let onSelect: (LogoPaletteSwatch) -> Void

    @State private var hoveredID: UUID?

    private var radius: CGFloat { diameter / 2 }
    private var usableRadius: CGFloat { radius - 22 }

    private var hueColors: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map {
            Color(hue: $0, saturation: 1, brightness: 1)
        }
    }

    var body: some View {
        ZStack {
            wheel

            ForEach(swatches) { swatch in
                dot(for: swatch)
            }
        }
        .frame(width: diameter, height: diameter)
    }

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
                // Wash the center toward white so radius reads as saturation.
                RadialGradient(
                    gradient: Gradient(colors: [.white, .white.opacity(0)]),
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .overlay(
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 4, height: 4)
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private func dot(for swatch: LogoPaletteSwatch) -> some View {
        let isSelected = swatch.id == selectedID
        let isHovered = swatch.id == hoveredID
        let size = dotSize(for: swatch)

        return Circle()
            .fill(swatch.color.color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 3 : 2))
            .overlay(Circle().stroke(.black.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: (isHovered || isSelected) ? 5 : 2, y: 1)
            .scaleEffect(isHovered ? 1.18 : (isSelected ? 1.08 : 1.0))
            .position(position(for: swatch))
            .animation(.easeInOut(duration: 0.18), value: isSelected)
            .animation(.easeInOut(duration: 0.18), value: isHovered)
            .onHover { hovering in
                if hovering { hoveredID = swatch.id }
                else if hoveredID == swatch.id { hoveredID = nil }
            }
            .onTapGesture { onSelect(swatch) }
    }

    private func position(for swatch: LogoPaletteSwatch) -> CGPoint {
        let hsv = swatch.color.hsv
        let center = CGPoint(x: radius, y: radius)

        if hsv.saturation < 0.08 {
            // Neutral — place on the vertical value axis (light up, dark down).
            let offset = CGFloat((hsv.value - 0.5) * 2.0) * usableRadius * 0.7
            return CGPoint(x: center.x, y: center.y - offset)
        }

        let angle = (hsv.hue - 90.0) * .pi / 180.0
        let r = CGFloat(hsv.saturation) * usableRadius
        return CGPoint(x: center.x + r * CGFloat(cos(angle)),
                       y: center.y + r * CGFloat(sin(angle)))
    }

    private func dotSize(for swatch: LogoPaletteSwatch) -> CGFloat {
        18 + min(CGFloat(swatch.weight), 0.45) * 30
    }
}

#Preview {
    let samples = PickedColor.sampleColors.map { LogoPaletteSwatch(color: $0, weight: 0.2) }
    return ColorWheelView(swatches: samples, selectedID: samples.first?.id) { _ in }
        .padding(40)
        .background(Color.black)
}
