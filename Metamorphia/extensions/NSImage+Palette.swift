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
import AppKit
import Foundation
import CoreGraphics

// MARK: - Palette Swatch

/// One major color pulled from an image, paired with how much of the
/// (opaque) image it covers. `weight` is a 0...1 share of sampled pixels.
struct LogoPaletteSwatch: Identifiable, Hashable {
    let id = UUID()
    let color: PickedColor
    let weight: Double

    var percentText: String {
        let pct = weight * 100
        return pct >= 9.5 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
    }
}

// MARK: - Image → Palette

extension NSImage {

    /// Pull the major colors out of the image (e.g. a logo).
    ///
    /// The image is shrunk to a tiny thumbnail, its opaque pixels are binned,
    /// then grouped by perceptual similarity (k-means in CIE-Lab). Groups that
    /// land on near-identical colors are merged, so the result is the handful of
    /// colors a person would actually name — not every anti-aliased in-between.
    /// Results are deterministic for a given image.
    func extractPalette(maxColors: Int = 6, completion: @escaping ([LogoPaletteSwatch]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let swatches = paletteColors(from: self, maxColors: max(1, maxColors))
            DispatchQueue.main.async { completion(swatches) }
        }
    }
}

// MARK: - Lab color helpers

private struct Lab: Hashable {
    var l: Double
    var a: Double
    var b: Double
}

private func srgbToLab(r: Double, g: Double, b: Double) -> Lab {
    func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let rl = linear(r), gl = linear(g), bl = linear(b)

    // sRGB → XYZ (D65), normalized by the reference white.
    let x = (rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375) / 0.95047
    let y = (rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750)
    let z = (rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041) / 1.08883

    func f(_ t: Double) -> Double {
        t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0)
    }
    let fx = f(x), fy = f(y), fz = f(z)
    return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
}

/// CIE76 color difference. Roughly: < 2.3 is imperceptible, ~10 is "clearly
/// related but distinct", which is where we draw the "awfully similar" line.
private func deltaE(_ x: Lab, _ y: Lab) -> Double {
    let dl = x.l - y.l, da = x.a - y.a, db = x.b - y.b
    return (dl * dl + da * da + db * db).squareRoot()
}

// MARK: - Core extraction

/// A bucket of near-identical pixels: their averaged color plus how many landed here.
private struct ColorBin {
    var r: Double
    var g: Double
    var b: Double
    var count: Double
    var lab: Lab
}

private func paletteColors(from image: NSImage, maxColors: Int) -> [LogoPaletteSwatch] {
    guard let bins = sampleBins(from: image), !bins.isEmpty else { return [] }

    let totalCount = bins.reduce(0.0) { $0 + $1.count }
    guard totalCount > 0 else { return [] }

    // Over-cluster a little, then merge look-alikes back down. This recovers
    // small-but-real accent colors that a tight k would swallow.
    let targetClusters = min(bins.count, maxColors + 3)
    var clusters = kMeans(bins: bins, k: targetClusters)
    clusters = mergeSimilar(clusters, threshold: 11.0)

    // Most prominent first.
    clusters.sort { $0.count > $1.count }

    // Drop confetti — anti-aliased edge blends that are perceptually distinct
    // (so merging won't catch them) yet too small to be a "major" color. Never
    // strip the image down to nothing — always keep at least the top couple.
    let floor = 0.02
    var kept = clusters.filter { $0.count / totalCount >= floor }
    if kept.count < min(2, clusters.count) {
        kept = Array(clusters.prefix(min(2, clusters.count)))
    }
    kept = Array(kept.prefix(maxColors))

    return kept.map { cluster in
        let nsColor = NSColor(srgbRed: clamp(cluster.r), green: clamp(cluster.g), blue: clamp(cluster.b), alpha: 1.0)
        let picked = PickedColor(nsColor: nsColor, point: .zero)
        return LogoPaletteSwatch(color: picked, weight: cluster.count / totalCount)
    }
}

/// Shrink to a thumbnail and bucket opaque pixels into a coarse 5-bit-per-channel
/// histogram. Tiny image = fast; bucketing collapses dithering noise up front.
private func sampleBins(from image: NSImage) -> [ColorBin]? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let maxEdge = 64
    let srcW = cgImage.width, srcH = cgImage.height
    guard srcW > 0, srcH > 0 else { return nil }

    let scale = min(1.0, Double(maxEdge) / Double(max(srcW, srcH)))
    let w = max(1, Int((Double(srcW) * scale).rounded()))
    let h = max(1, Int((Double(srcH) * scale).rounded()))

    // Let CGContext own the pixel buffer (data: nil) and read it back from
    // context.data — passing a Swift array's pointer here would dangle.
    guard let context = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    guard let data = context.data else { return nil }
    let total = w * h * 4
    let pixels = data.bindMemory(to: UInt8.self, capacity: total)

    // key = quantized RGB (5 bits each) → accumulated true color + count
    var table: [Int: (r: Double, g: Double, b: Double, count: Double)] = [:]
    table.reserveCapacity(w * h)

    var i = 0
    while i < total {
        let alpha = pixels[i + 3]
        // Skip transparent pixels — a logo's empty canvas is not one of its colors.
        if alpha >= 128 {
            let af = Double(alpha) / 255.0
            // Un-premultiply so partially transparent edges report their true color.
            let r = min(255.0, Double(pixels[i]) / af)
            let g = min(255.0, Double(pixels[i + 1]) / af)
            let b = min(255.0, Double(pixels[i + 2]) / af)

            let key = ((Int(r) >> 3) << 10) | ((Int(g) >> 3) << 5) | (Int(b) >> 3)
            if var entry = table[key] {
                entry.r += r; entry.g += g; entry.b += b; entry.count += 1
                table[key] = entry
            } else {
                table[key] = (r, g, b, 1)
            }
        }
        i += 4
    }

    guard !table.isEmpty else { return nil }

    // Sort for deterministic downstream clustering (Dictionary order isn't stable).
    let bins = table.map { key, v -> ColorBin in
        let r = v.r / v.count / 255.0
        let g = v.g / v.count / 255.0
        let b = v.b / v.count / 255.0
        return ColorBin(r: r, g: g, b: b, count: v.count, lab: srgbToLab(r: r, g: g, b: b))
    }
    .sorted { lhs, rhs in
        // Total order over distinct colors → fully deterministic regardless of
        // Dictionary iteration order (which is randomized per process run).
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        if lhs.lab.l != rhs.lab.l { return lhs.lab.l > rhs.lab.l }
        if lhs.lab.a != rhs.lab.a { return lhs.lab.a > rhs.lab.a }
        return lhs.lab.b > rhs.lab.b
    }

    return bins
}

/// Weighted k-means in Lab with deterministic, spread-out seeding
/// (greedy farthest-point, biased toward populous colors).
private func kMeans(bins: [ColorBin], k: Int) -> [ColorBin] {
    let n = bins.count
    let k = min(k, n)
    guard k > 0 else { return [] }
    if k == n { return bins }

    // Seed: start from the most common color, then repeatedly take the color
    // that is both far from everything chosen and itself sizable.
    var centroids: [Lab] = [bins[0].lab]
    while centroids.count < k {
        var bestIndex = -1
        var bestScore = -1.0
        for (idx, bin) in bins.enumerated() {
            let nearest = centroids.map { deltaE($0, bin.lab) }.min() ?? 0
            let score = nearest * nearest * bin.count
            if score > bestScore {
                bestScore = score
                bestIndex = idx
            }
        }
        if bestIndex < 0 { break }
        centroids.append(bins[bestIndex].lab)
    }

    var assignment = [Int](repeating: 0, count: n)
    for _ in 0..<16 {
        var changed = false
        for idx in 0..<n {
            var best = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (c, centroid) in centroids.enumerated() {
                let d = deltaE(centroid, bins[idx].lab)
                if d < bestDist { bestDist = d; best = c }
            }
            if assignment[idx] != best { assignment[idx] = best; changed = true }
        }

        var sums = [Lab](repeating: Lab(l: 0, a: 0, b: 0), count: centroids.count)
        var weights = [Double](repeating: 0, count: centroids.count)
        for idx in 0..<n {
            let c = assignment[idx]
            let wgt = bins[idx].count
            sums[c].l += bins[idx].lab.l * wgt
            sums[c].a += bins[idx].lab.a * wgt
            sums[c].b += bins[idx].lab.b * wgt
            weights[c] += wgt
        }
        for c in 0..<centroids.count where weights[c] > 0 {
            centroids[c] = Lab(l: sums[c].l / weights[c], a: sums[c].a / weights[c], b: sums[c].b / weights[c])
        }
        if !changed { break }
    }

    // Collapse each cluster to one swatch: its total weight, colored by the
    // single most-common bin inside it (a real image color, not a muddy mean).
    var result: [ColorBin] = []
    for c in 0..<centroids.count {
        var totalCount = 0.0
        var dominant: ColorBin?
        for idx in 0..<n where assignment[idx] == c {
            totalCount += bins[idx].count
            if dominant == nil || bins[idx].count > dominant!.count {
                dominant = bins[idx]
            }
        }
        guard var rep = dominant, totalCount > 0 else { continue }
        rep.count = totalCount
        result.append(rep)
    }
    return result
}

/// Fold together any clusters that ended up perceptually indistinguishable.
private func mergeSimilar(_ clusters: [ColorBin], threshold: Double) -> [ColorBin] {
    var clusters = clusters
    var merged = true
    while merged {
        merged = false
        outer: for i in 0..<clusters.count {
            for j in (i + 1)..<clusters.count {
                if deltaE(clusters[i].lab, clusters[j].lab) < threshold {
                    // Keep the more prominent one's color, absorb the other's weight.
                    if clusters[j].count > clusters[i].count {
                        clusters[i].r = clusters[j].r
                        clusters[i].g = clusters[j].g
                        clusters[i].b = clusters[j].b
                        clusters[i].lab = clusters[j].lab
                    }
                    clusters[i].count += clusters[j].count
                    clusters.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
    }
    return clusters
}

private func clamp(_ v: Double) -> Double { min(1.0, max(0.0, v)) }
