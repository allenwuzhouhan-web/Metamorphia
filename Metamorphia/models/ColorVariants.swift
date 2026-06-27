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

import Foundation
import Defaults

/// How to derive a family of colors from a chosen one. Monochromatic = tints
/// and shades of the same color (the default); the rest are classic harmonies
/// (relatives that sit at fixed hue offsets around the wheel).
enum VariantScheme: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    case monochromatic
    case analogous
    case complementary
    case triadic
    case splitComplementary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .monochromatic: return String(localized: "Shades")
        case .analogous: return String(localized: "Analogous")
        case .complementary: return String(localized: "Complement")
        case .triadic: return String(localized: "Triadic")
        case .splitComplementary: return String(localized: "Split")
        }
    }

    /// Short label for tight spaces (the notch picker).
    var shortLabel: String {
        switch self {
        case .monochromatic: return String(localized: "Shades")
        case .analogous: return String(localized: "Analog")
        case .complementary: return String(localized: "Comp")
        case .triadic: return String(localized: "Triad")
        case .splitComplementary: return String(localized: "Split")
        }
    }

    var symbol: String {
        switch self {
        case .monochromatic: return "circle.lefthalf.filled"
        case .analogous: return "circle.grid.2x1"
        case .complementary: return "circle.righthalf.filled"
        case .triadic: return "triangle"
        case .splitComplementary: return "arrow.triangle.branch"
        }
    }
}

/// One generated variant. Identity is the **slot** (0…4), which is stable across
/// recomputes and scheme switches — so `matchedGeometryEffect` glides each dot to
/// its new place instead of cross-fading. (`PickedColor.id` is random per init and
/// must NOT be used for identity here.)
struct ColorVariant: Identifiable, Hashable {
    let slot: Int
    let color: PickedColor
    var id: Int { slot }
}

/// Generate `count` (=5) colors related to `base` under `scheme`. These are the
/// *new* variants that emerge around the selected color — the base itself is not
/// included (the caller shows it separately as the parent).
///
/// Works in OKLCh (perceptually-uniform lightness + even hue rotation) so a
/// tint/shade ramp reads as even steps and a ±30° rotation looks like an even
/// turn — both of which HSV gets visibly wrong.
func variants(of base: PickedColor, scheme: VariantScheme, count: Int = 5) -> [PickedColor] {
    let c = base.oklch
    let h = c.h, chroma = c.C, L = c.L

    func mk(_ hue: Double, _ chr: Double, _ lit: Double) -> PickedColor {
        PickedColor(oklch: OKLCh(L: clampL(lit), C: max(0, chr), h: wrap(hue)))
    }

    switch scheme {
    case .monochromatic:
        // A clean 5-step tonal ladder of the same hue: two shades darker, three
        // tints lighter. Even in OKLab L; chroma eased down toward the light end
        // so tints don't look chalky. On the wheel these fan along the hue spoke.
        let deltas: [Double] = [-0.26, -0.13, 0.13, 0.26, 0.39]
        return deltas.map { d in mk(h, chroma * (1 - 0.22 * max(0, d / 0.39)), L + d) }

    case .analogous:
        return [
            mk(h - 60, chroma, L),
            mk(h - 30, chroma, L),
            mk(h + 30, chroma, L),
            mk(h + 60, chroma, L),
            mk(h - 30, chroma, L + 0.16)   // a lighter neighbor to round out 5
        ]

    case .complementary:
        let hc = h + 180
        return [
            mk(hc, chroma, L),             // pure complement
            mk(hc, chroma * 0.8, L + 0.16),// light complement
            mk(hc, chroma, L - 0.16),      // dark complement
            mk(h, chroma * 0.8, L + 0.16), // light base — ties the pair together
            mk(h, chroma, L - 0.16)        // dark base
        ]

    case .triadic:
        return [
            mk(h + 120, chroma, L),
            mk(h - 120, chroma, L),
            mk(h + 120, chroma, L + 0.15),
            mk(h - 120, chroma, L - 0.15),
            mk(h, chroma * 0.85, L + 0.15)  // light base accent
        ]

    case .splitComplementary:
        return [
            mk(h + 150, chroma, L),
            mk(h + 210, chroma, L),
            mk(h + 150, chroma, L + 0.15),
            mk(h + 210, chroma, L - 0.15),
            mk(h + 180, chroma * 0.7, L + 0.12)  // faint true complement as a hint
        ]
    }
}

// MARK: - helpers

private func wrap(_ deg: Double) -> Double {
    let m = deg.truncatingRemainder(dividingBy: 360)
    return m < 0 ? m + 360 : m
}

private func clampL(_ v: Double) -> Double { min(0.97, max(0.13, v)) }
