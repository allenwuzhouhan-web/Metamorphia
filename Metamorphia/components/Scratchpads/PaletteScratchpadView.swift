import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Palette Scratchpad
//
// Drop an image (or pull one from the clipboard), downsample it, and cluster
// the pixels into ~6 dominant colors. Each swatch shows its hex code; tapping
// a swatch copies the hex to the clipboard. With no image it shows a calm
// prompt rather than an empty void.
//
// Everything is bounded: the bitmap is downscaled to a small fixed grid before
// any clustering runs, so extraction stays fast regardless of source size.

/// One extracted color plus its share of the sampled pixels.
struct PaletteSwatch: Identifiable {
    let id = UUID()
    let color: Color
    let hex: String
    /// Fraction of sampled pixels assigned to this cluster (0...1).
    let weight: Double
}

/// Failure surfaced inline when an image can't be read or yields no usable pixels.
enum PaletteExtractError: LocalizedError {
    case unreadable
    case noPixels

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That image couldn't be read."
        case .noPixels: return "No colors could be sampled from that image."
        }
    }
}

@MainActor public struct PaletteScratchpadView: View {
    @State private var swatches: [PaletteSwatch] = []
    @State private var preview: NSImage?
    @State private var errorText: String?
    @State private var isExtracting = false
    @State private var isTargeted = false
    @State private var copiedHex: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            dropArea

            if let errorText {
                inlineError(errorText)
            }

            if swatches.isEmpty {
                Spacer(minLength: 0)
                emptyHint
                Spacer(minLength: 0)
            } else {
                swatchList
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Palette")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            Button(action: useClipboardImage) {
                Label("Clipboard", systemImage: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Extract a palette from an image on the clipboard")
        }
    }

    // MARK: Drop area

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(isTargeted ? 0.12 : 0.05))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: preview == nil ? [5, 4] : [])
                )
                .foregroundStyle(.white.opacity(isTargeted ? 0.4 : 0.18))

            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if isExtracting {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Drop an image")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(height: 96)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted.animation(.easeOut(duration: 0.15))) { providers in
            handleDrop(providers)
        }
    }

    // MARK: Swatch list

    private var swatchList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 7) {
                ForEach(swatches) { swatch in
                    swatchRow(swatch)
                }
            }
            .padding(.bottom, 2)
        }
    }

    private func swatchRow(_ swatch: PaletteSwatch) -> some View {
        Button {
            copy(swatch.hex)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(swatch.color)
                    .frame(width: 38, height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(swatch.hex)
                        // Hex is literally data, so a monospaced face is allowed here.
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("\(Int((swatch.weight * 100).rounded()))%")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer()

                Image(systemName: copiedHex == swatch.hex ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copiedHex == swatch.hex ? .green : .white.opacity(0.4))
                    .animation(.spring(response: 0.25), value: copiedHex)
            }
            .padding(8)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Copy \(swatch.hex)")
    }

    // MARK: Empty + error

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "eyedropper.halffull")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Drop an image to pull its colors.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func inlineError(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: Actions

    private func copy(_ hex: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        copiedHex = hex
        let target = hex
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            if copiedHex == target { copiedHex = nil }
        }
    }

    private func useClipboardImage() {
        guard let image = NSImage(pasteboard: .general) else {
            present(.unreadable)
            return
        }
        extract(from: image)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                let image = object as? NSImage
                Task { @MainActor in
                    if let image { extract(from: image) } else { present(.unreadable) }
                }
            }
            return true
        }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let image = url.flatMap { NSImage(contentsOf: $0) }
                Task { @MainActor in
                    if let image { extract(from: image) } else { present(.unreadable) }
                }
            }
            return true
        }

        return false
    }

    private func present(_ error: PaletteExtractError) {
        errorText = error.errorDescription
        isExtracting = false
    }

    private func extract(from image: NSImage) {
        errorText = nil
        preview = image
        isExtracting = true

        // Snapshot pixels on the main actor (NSImage is not Sendable), then
        // cluster off the main thread to keep the UI responsive.
        guard let pixels = PaletteScratchpadView.samplePixels(from: image) else {
            present(.unreadable)
            return
        }

        Task.detached(priority: .userInitiated) {
            let result = PaletteScratchpadView.dominantColors(from: pixels, count: 6)
            await MainActor.run {
                isExtracting = false
                if result.isEmpty {
                    present(.noPixels)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { swatches = result }
                }
            }
        }
    }

    // MARK: - Pixel sampling (main-actor; touches AppKit)

    /// A flat RGB sample drawn from a downscaled copy of the image. Sendable so
    /// it can cross into a detached task for clustering.
    private struct SampledPixels: Sendable {
        let rgb: [(Double, Double, Double)]
    }

    private static func samplePixels(from image: NSImage) -> SampledPixels? {
        // Downscale to a small fixed grid: bounded work, plenty of color signal.
        let side = 48
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        ) else { return nil }

        let context = NSGraphicsContext(bitmapImageRep: rep)
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.current = saved

        guard let data = rep.bitmapData else { return nil }

        var rgb: [(Double, Double, Double)] = []
        rgb.reserveCapacity(side * side)
        let bytesPerPixel = rep.bitsPerPixel / 8
        let rowBytes = rep.bytesPerRow

        for y in 0..<side {
            for x in 0..<side {
                let offset = y * rowBytes + x * bytesPerPixel
                let r = Double(data[offset])
                let g = Double(data[offset + 1])
                let b = Double(data[offset + 2])
                let a = bytesPerPixel >= 4 ? Double(data[offset + 3]) : 255.0
                // Skip near-transparent pixels — they aren't part of the palette.
                if a < 24 { continue }
                rgb.append((r, g, b))
            }
        }

        guard !rgb.isEmpty else { return nil }
        return SampledPixels(rgb: rgb)
    }

    // MARK: - Clustering (pure; runs off the main actor)

    /// k-means over the sampled RGB pixels. Bounded iterations keep it fast.
    /// Returns swatches sorted by descending share of pixels.
    nonisolated private static func dominantColors(from pixels: SampledPixels, count: Int) -> [PaletteSwatch] {
        let samples = pixels.rgb
        guard !samples.isEmpty else { return [] }

        let k = min(count, samples.count)
        guard k > 0 else { return [] }

        // Seed centroids by striding across the samples — deterministic and
        // spread-out enough without needing randomness.
        var centroids: [(Double, Double, Double)] = []
        let stride = max(1, samples.count / k)
        for i in 0..<k {
            centroids.append(samples[min(i * stride, samples.count - 1)])
        }

        var assignment = [Int](repeating: 0, count: samples.count)

        for _ in 0..<12 {
            // Assign each sample to its nearest centroid.
            var changed = false
            for (idx, px) in samples.enumerated() {
                var best = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (c, ctr) in centroids.enumerated() {
                    let dr = px.0 - ctr.0
                    let dg = px.1 - ctr.1
                    let db = px.2 - ctr.2
                    let d = dr * dr + dg * dg + db * db
                    if d < bestDist { bestDist = d; best = c }
                }
                if assignment[idx] != best { assignment[idx] = best; changed = true }
            }

            // Recompute centroids as the mean of their assigned samples.
            var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (idx, px) in samples.enumerated() {
                let c = assignment[idx]
                sums[c].0 += px.0; sums[c].1 += px.1; sums[c].2 += px.2
                counts[c] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                let n = Double(counts[c])
                centroids[c] = (sums[c].0 / n, sums[c].1 / n, sums[c].2 / n)
            }

            if !changed { break }
        }

        // Tally final membership for weights.
        var counts = [Int](repeating: 0, count: k)
        for a in assignment { counts[a] += 1 }
        let total = Double(samples.count)

        var result: [(centroid: (Double, Double, Double), weight: Double)] = []
        for c in 0..<k where counts[c] > 0 {
            result.append((centroids[c], Double(counts[c]) / total))
        }
        result.sort { $0.weight > $1.weight }

        return result.map { entry in
            let r = clampByte(entry.centroid.0)
            let g = clampByte(entry.centroid.1)
            let b = clampByte(entry.centroid.2)
            let hex = String(format: "#%02X%02X%02X", r, g, b)
            let color = Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
            return PaletteSwatch(color: color, hex: hex, weight: entry.weight)
        }
    }

    nonisolated private static func clampByte(_ value: Double) -> Int {
        Int(min(255, max(0, value.rounded())))
    }
}
