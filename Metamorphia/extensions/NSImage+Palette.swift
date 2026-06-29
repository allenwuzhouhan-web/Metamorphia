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

    /// Pull the major colors out of the image (e.g. a logo or artwork).
    ///
    /// The image is decoded at full resolution, point-sampled to a small
    /// thumbnail (no blending, so vivid pixels stay vivid), binned, and grouped
    /// by perceptual similarity in OKLab. Selection balances prominence with
    /// perceptual diversity — so a vivid minority color isn't lost behind a huge
    /// neutral background — and a multi-color image never collapses to a single
    /// swatch. Results are deterministic for a given image.
    func extractPalette(maxColors: Int = 6, completion: @escaping ([LogoPaletteSwatch]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let swatches = paletteColors(from: self, maxColors: max(1, maxColors))
            DispatchQueue.main.async { completion(swatches) }
        }
    }
}

// MARK: - Tunables

private let kChroma = 3.0           // saliency lift: effective weight = count·(1 + kChroma·chroma)
private let diversityLambda = 0.65  // selection: 0.65·spread + 0.35·saliency
private let mergeThreshold = 0.045  // ΔOKLab below which two clusters are "the same color"
private let varianceThreshold = 0.04

// MARK: - Core extraction

/// A bucket of near-identical pixels: their averaged true color + how many landed here.
private struct ColorBin {
    var r: Double
    var g: Double
    var b: Double
    var count: Double
    var ok: OKLab
}

/// A merged group of bins → one swatch. `count` is raw pixel population;
/// `salient` is the chroma-lifted weight used only to *steer selection*.
private struct Cluster {
    var r: Double
    var g: Double
    var b: Double
    var ok: OKLab
    var count: Double
    var salient: Double
}

private func paletteColors(from image: NSImage, maxColors: Int) -> [LogoPaletteSwatch] {
    guard let (bins, totalCount) = sampleBins(from: image), totalCount > 0, !bins.isEmpty else {
        return []
    }

    let k = min(bins.count, maxColors + 4)
    var clusters = kMeans(bins: bins, k: k)
    clusters = mergeSimilar(clusters, threshold: mergeThreshold)

    // ---- Never-one-color guard ----
    // Population-weighted OKLab stddev over the original bins. If the image has real
    // color variance (or ≥2 well-separated clusters survived the merge), guarantee ≥3 colors.
    let meanL = bins.reduce(0.0) { $0 + $1.ok.L * $1.count } / totalCount
    let meanA = bins.reduce(0.0) { $0 + $1.ok.a * $1.count } / totalCount
    let meanB = bins.reduce(0.0) { $0 + $1.ok.b * $1.count } / totalCount
    let varSum = bins.reduce(0.0) { acc, b in
        let dl = b.ok.L - meanL, da = b.ok.a - meanA, db = b.ok.b - meanB
        return acc + (dl * dl + da * da + db * db) * b.count
    }
    let stddev = (varSum / totalCount).squareRoot()
    let hasVariance = stddev > varianceThreshold || clusters.count >= 2

    var floorColors = 1
    if hasVariance { floorColors = min(3, clusters.count, max(1, maxColors)) }

    var picked = selectFinal(clusters, maxColors: maxColors, totalPop: totalCount)
    if picked.count < floorColors {
        // Top up from the most salient remaining clusters.
        let have = Set(picked.map { $0.ok })
        let extra = clusters
            .filter { !have.contains($0.ok) }
            .sorted { $0.salient > $1.salient }
        picked += extra.prefix(floorColors - picked.count)
    }

    return picked.map { c in
        let ns = NSColor(srgbRed: clamp(c.r), green: clamp(c.g), blue: clamp(c.b), alpha: 1.0)
        // weight is the TRUE pixel share — saliency only steered selection, never this.
        return LogoPaletteSwatch(color: PickedColor(nsColor: ns, point: .zero),
                                 weight: c.count / totalCount)
    }
}

// MARK: - Full-resolution decode

/// Rasterize the NSImage at its TRUE pixel resolution, bypassing any cached
/// low-res representation. Prefer the largest pixel-backed rep's CGImage; if
/// there's none (vector/PDF), draw the image explicitly at a sane resolution.
private func fullResolutionCGImage(from image: NSImage) -> CGImage? {
    var best: NSBitmapImageRep?
    for rep in image.representations {
        if let bm = rep as? NSBitmapImageRep {
            if best == nil || bm.pixelsWide * bm.pixelsHigh > best!.pixelsWide * best!.pixelsHigh {
                best = bm
            }
        }
    }
    if let bm = best, let cg = bm.cgImage, bm.pixelsWide > 1, bm.pixelsHigh > 1 {
        return cg
    }

    // No usable bitmap rep (e.g. PDF/vector). Draw explicitly, scaled up so we
    // don't sample a blurry proxy.
    let size = image.size
    guard size.width > 0, size.height > 0 else {
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    let targetMax: CGFloat = 1024
    let scale = min(4.0, max(1.0, targetMax / max(size.width, size.height)))
    let pw = Int((size.width * scale).rounded())
    let ph = Int((size.height * scale).rounded())
    guard pw > 0, ph > 0, let ctx = CGContext(
        data: nil, width: pw, height: ph,
        bitsPerComponent: 8, bytesPerRow: pw * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    ctx.interpolationQuality = .high   // OK here: upscaling vector art, not blending photo detail

    // Vector/PDF reps consult NSGraphicsContext/screen state and aren't documented
    // thread-safe (PDFImageRep/EPS have historically been fragile off-main). Rasterize
    // this fallback on the main thread; the fast NSBitmapImageRep.cgImage path above
    // never reaches here, so normal images stay fully off-main.
    let rasterize = {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        image.draw(in: CGRect(x: 0, y: 0, width: pw, height: ph),
                   from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    }
    if Thread.isMainThread {
        rasterize()
    } else {
        DispatchQueue.main.sync(execute: rasterize)
    }
    return ctx.makeImage()
}

// MARK: - Sampling (nearest-neighbour → keep vivid pixels vivid)

private func sampleBins(from image: NSImage) -> (bins: [ColorBin], total: Double)? {
    guard let cg = fullResolutionCGImage(from: image) else { return nil }
    let srcW = cg.width, srcH = cg.height
    guard srcW > 0, srcH > 0 else { return nil }

    let maxEdge = 144
    let scale = min(1.0, Double(maxEdge) / Double(max(srcW, srcH)))
    let w = max(1, Int((Double(srcW) * scale).rounded()))
    let h = max(1, Int((Double(srcH) * scale).rounded()))

    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .none   // point-sample: a vivid pixel stays vivid
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    guard let data = ctx.data else { return nil }
    let total = w * h * 4
    let px = data.bindMemory(to: UInt8.self, capacity: total)

    // 6-bit/channel histogram key → accumulate true color + count.
    var table: [Int: (r: Double, g: Double, b: Double, c: Double)] = [:]
    table.reserveCapacity(w * h)

    var i = 0
    while i < total {
        let a = px[i + 3]
        if a >= 8 {   // skip only the (near-)fully-transparent canvas
            let af = Double(a) / 255.0
            // Un-premultiply to recover the pixel's TRUE color, then weight its
            // contribution by alpha — so a uniformly semi-transparent image still
            // reads its real colors, while anti-aliased edges don't dominate.
            let r = min(255.0, Double(px[i])     / af)
            let g = min(255.0, Double(px[i + 1]) / af)
            let b = min(255.0, Double(px[i + 2]) / af)
            let key = ((Int(r) >> 2) << 12) | ((Int(g) >> 2) << 6) | (Int(b) >> 2)
            if var e = table[key] {
                e.r += r * af; e.g += g * af; e.b += b * af; e.c += af; table[key] = e
            } else {
                table[key] = (r * af, g * af, b * af, af)
            }
        }
        i += 4
    }
    guard !table.isEmpty else { return nil }

    let bins = table.map { _, v -> ColorBin in
        let r = v.r / v.c / 255.0, g = v.g / v.c / 255.0, b = v.b / v.c / 255.0
        return ColorBin(r: r, g: g, b: b, count: v.c, ok: srgbToOKLab(r: r, g: g, b: b))
    }
    .sorted { l, r in   // total order → deterministic regardless of Dictionary order
        if l.count != r.count { return l.count > r.count }
        if l.ok.L != r.ok.L { return l.ok.L > r.ok.L }
        if l.ok.a != r.ok.a { return l.ok.a > r.ok.a }
        return l.ok.b > r.ok.b
    }
    let totalCount = bins.reduce(0.0) { $0 + $1.count }
    return (bins, totalCount)
}

// MARK: - Weighted k-means in OKLab (saliency-aware seeding)

private func salientWeight(_ b: ColorBin) -> Double {
    b.count * (1 + kChroma * chromaOK(b.ok))
}

private func kMeans(bins: [ColorBin], k rawK: Int) -> [Cluster] {
    let n = bins.count
    let k = min(rawK, n)
    guard k > 0 else { return [] }

    // Seed: most populous bin, then greedy farthest-point biased by SALIENT weight,
    // so a vivid-but-minority swirl earns a seed instead of being swallowed.
    var seeds: [OKLab] = [bins[0].ok]
    while seeds.count < k {
        var bi = -1, bs = -1.0
        for (idx, b) in bins.enumerated() {
            let nearest = seeds.map { deltaOK($0, b.ok) }.min() ?? 0
            let score = nearest * nearest * salientWeight(b)
            if score > bs { bs = score; bi = idx }
        }
        if bi < 0 { break }
        seeds.append(bins[bi].ok)
    }

    var assign = [Int](repeating: 0, count: n)
    var centroids = seeds
    for _ in 0..<12 {
        var changed = false
        for idx in 0..<n {
            var best = 0, bestD = Double.greatestFiniteMagnitude
            for (c, cen) in centroids.enumerated() {
                let d = deltaOK(cen, bins[idx].ok)
                if d < bestD { bestD = d; best = c }
            }
            if assign[idx] != best { assign[idx] = best; changed = true }
        }
        var sums = [OKLab](repeating: OKLab(L: 0, a: 0, b: 0), count: centroids.count)
        var wts = [Double](repeating: 0, count: centroids.count)
        for idx in 0..<n {
            let c = assign[idx], w = bins[idx].count
            sums[c].L += bins[idx].ok.L * w
            sums[c].a += bins[idx].ok.a * w
            sums[c].b += bins[idx].ok.b * w
            wts[c] += w
        }
        for c in 0..<centroids.count where wts[c] > 0 {
            centroids[c] = OKLab(L: sums[c].L / wts[c], a: sums[c].a / wts[c], b: sums[c].b / wts[c])
        }
        if !changed { break }
    }

    // Collapse each cluster to ONE real swatch: total population, colored by its
    // single most-common bin (a true image color, not a muddy mean).
    var out: [Cluster] = []
    for c in 0..<centroids.count {
        var pop = 0.0, sal = 0.0
        var dom: ColorBin?
        for idx in 0..<n where assign[idx] == c {
            pop += bins[idx].count
            sal += salientWeight(bins[idx])
            if dom == nil || bins[idx].count > dom!.count { dom = bins[idx] }
        }
        guard let d = dom, pop > 0 else { continue }
        out.append(Cluster(r: d.r, g: d.g, b: d.b, ok: d.ok, count: pop, salient: sal))
    }
    return out
}

// MARK: - Merge perceptually-identical clusters

private func mergeSimilar(_ input: [Cluster], threshold: Double) -> [Cluster] {
    var cs = input
    var merged = true
    while merged {
        merged = false
        outer: for i in 0..<cs.count {
            for j in (i + 1)..<cs.count {
                if deltaOK(cs[i].ok, cs[j].ok) < threshold {
                    if cs[j].count > cs[i].count {   // keep the more prominent one's color
                        cs[i].r = cs[j].r; cs[i].g = cs[j].g; cs[i].b = cs[j].b; cs[i].ok = cs[j].ok
                    }
                    cs[i].count += cs[j].count
                    cs[i].salient += cs[j].salient
                    cs.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
    }
    return cs
}

// MARK: - Diversity + saliency selection (replaces the old prominence floor)

private func selectFinal(_ clusters: [Cluster], maxColors: Int, totalPop: Double) -> [Cluster] {
    guard !clusters.isEmpty else { return [] }
    if clusters.count <= maxColors {
        return clusters.sorted { $0.count > $1.count }
    }

    let maxSal = clusters.map { $0.salient }.max() ?? 1
    func normSal(_ c: Cluster) -> Double { maxSal > 0 ? c.salient / maxSal : 0 }

    // 1) Anchor on the most populous cluster so result.first stays the dominant color.
    var chosen: [Cluster] = []
    var pool = clusters
    let anchorIdx = pool.indices.max { pool[$0].count < pool[$1].count }!
    chosen.append(pool.remove(at: anchorIdx))

    // 2) Greedily add the cluster maximizing  λ·spread + (1-λ)·saliency, where
    //    spread = min OKLab distance to anything already chosen (farthest-point).
    while chosen.count < maxColors && !pool.isEmpty {
        let spreads = pool.map { p in chosen.map { deltaOK($0.ok, p.ok) }.min() ?? 0 }
        let maxSpread = spreads.max() ?? 1
        var bi = 0, bestScore = -1.0
        for (k, p) in pool.enumerated() {
            let s = maxSpread > 0 ? spreads[k] / maxSpread : 0
            let score = diversityLambda * s + (1 - diversityLambda) * normSal(p)
            if score > bestScore { bestScore = score; bi = k }
        }
        chosen.append(pool.remove(at: bi))
    }

    // Present most-prominent first (anchor leads; the rest by population).
    let head = chosen.first!
    let tail = chosen.dropFirst().sorted { $0.count > $1.count }
    return [head] + tail
}

private func clamp(_ v: Double) -> Double { min(1.0, max(0.0, v)) }
