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
import AppKit

// MARK: - OKLab / OKLCh
//
// OKLab (Björn Ottosson, 2020) is a perceptually-uniform color space: equal
// numeric steps look like equal visual steps. We use it for two things — pulling
// the *major* colors out of an image (clustering + distance), and generating
// even tints/shades and harmony rotations of a selected color. OKLCh is the
// cylindrical form (Lightness, Chroma, hue°), which is the natural space for
// "same color, lighter/darker" and "rotate the hue by N degrees".

/// L ≈ lightness (0…1), a/b ≈ green–red / blue–yellow opponent axes (~ -0.4…0.4).
struct OKLab: Hashable {
    var L: Double
    var a: Double
    var b: Double
}

/// Cylindrical OKLab: L lightness, C chroma (≥0), h hue in degrees (0…360).
struct OKLCh: Hashable {
    var L: Double
    var C: Double
    var h: Double
}

@inline(__always) private func clamp01(_ v: Double) -> Double { min(1.0, max(0.0, v)) }

@inline(__always) func srgbToLinear(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

@inline(__always) func linearToSRGB(_ c: Double) -> Double {
    let x = max(0.0, c)
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
}

/// sRGB (0…1) → linear → LMS → OKLab. Ottosson's exact matrices.
func srgbToOKLab(r: Double, g: Double, b: Double) -> OKLab {
    let rl = srgbToLinear(r), gl = srgbToLinear(g), bl = srgbToLinear(b)

    let l = 0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl
    let m = 0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl
    let s = 0.0883024619 * rl + 0.2817188376 * gl + 0.6299787005 * bl

    let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)

    return OKLab(
        L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    )
}

/// OKLab → sRGB (0…1), clamped into gamut.
func oklabToSRGB(_ c: OKLab) -> (r: Double, g: Double, b: Double) {
    let l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b
    let m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b
    let s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b

    let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_

    let rl =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let gl = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

    return (clamp01(linearToSRGB(rl)), clamp01(linearToSRGB(gl)), clamp01(linearToSRGB(bl)))
}

/// Perceptual distance in OKLab (Euclidean ≈ ΔE_OK). ~0.02 imperceptible, ~0.1 obvious.
@inline(__always) func deltaOK(_ x: OKLab, _ y: OKLab) -> Double {
    let dL = x.L - y.L, da = x.a - y.a, db = x.b - y.b
    return (dL * dL + da * da + db * db).squareRoot()
}

/// Chroma = √(a² + b²): 0 for neutrals, grows with saturation. Drives saliency.
@inline(__always) func chromaOK(_ c: OKLab) -> Double {
    (c.a * c.a + c.b * c.b).squareRoot()
}

extension OKLab {
    var lch: OKLCh {
        let C = chromaOK(self)
        var h = atan2(b, a) * 180.0 / .pi
        if h < 0 { h += 360 }
        return OKLCh(L: L, C: C, h: h)
    }
}

extension OKLCh {
    var lab: OKLab {
        let rad = h * .pi / 180.0
        return OKLab(L: L, a: C * cos(rad), b: C * sin(rad))
    }
}

// MARK: - PickedColor bridge

extension PickedColor {
    var oklab: OKLab { srgbToOKLab(r: red, g: green, b: blue) }
    var oklch: OKLCh { oklab.lch }

    /// Build a color from OKLab, clamped into the sRGB gamut. `point` is irrelevant
    /// for generated colors, so it defaults to `.zero`.
    init(oklab: OKLab, alpha: Double = 1.0) {
        let rgb = oklabToSRGB(oklab)
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha, point: .zero)
    }

    init(oklch: OKLCh, alpha: Double = 1.0) {
        self.init(oklab: oklch.lab, alpha: alpha)
    }
}
