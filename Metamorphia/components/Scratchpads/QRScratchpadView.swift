/*
 * Metamorphia
 * QR scratchpad — generate and decode, in one tile.
 *
 * Generate: a text field (seeded from the clipboard string if any) renders a QR
 * code live via CoreImage's CIQRCodeGenerator. Copy the rendered image to the
 * pasteboard with one tap.
 *
 * Decode: drop an image onto the well, or pull the current clipboard image, and
 * a Vision VNDetectBarcodesRequest reads back the payload. No screen capture —
 * the only inputs are an explicit drop or an explicit clipboard read.
 *
 * All state is local (@State). No app singletons, no network, no force-unwraps.
 * Invalid input, a missing image, or a barcode-free image each show a calm
 * inline status rather than crashing. Sized for a ~360x440 floating panel; the
 * body scrolls when both halves are open.
 */

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import UniformTypeIdentifiers

/// A two-in-one QR tile: live generation on top, drop-to-decode below.
/// Hostable in the notch or a floating panel.
@MainActor
public struct QRScratchpadView: View {
    /// The text encoded into the generated QR.
    @State private var payload: String

    /// The most recent decode result (or a reason none is shown).
    @State private var decoded: String?
    /// Transient status for the decode half.
    @State private var decodeStatus: QRStatusKind = .idle
    /// Highlight ring while a drag hovers the well.
    @State private var isTargeted = false
    /// Flashes "Copied" on the generate half after a successful image copy.
    @State private var copiedFlash = false

    /// Shared CoreImage context, reused across renders.
    private let ciContext = CIContext()

    public init() {
        // Seed from the clipboard string so the field isn't empty on first open,
        // falling back to a friendly default.
        let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = (clip?.isEmpty == false) ? clip : nil
        _payload = State(initialValue: seed ?? "https://metamorphia.app")
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                generateSection
                divider
                decodeSection
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(minWidth: 300)
    }

    // MARK: - Generate

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Generate")

            QRPreviewBox(image: generatedImage)

            TextField("Text or URL to encode", text: $payload, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )

            HStack(spacing: 8) {
                QRGlassButton(
                    title: copiedFlash ? "Copied" : "Copy Image",
                    systemImage: copiedFlash ? "checkmark" : "doc.on.doc",
                    tint: copiedFlash ? .green : .white,
                    enabled: generatedImage != nil,
                    action: copyGeneratedImage
                )
                QRGlassButton(
                    title: "Use Result",
                    systemImage: "arrow.up.circle",
                    tint: .white,
                    enabled: (decoded?.isEmpty == false),
                    action: { if let decoded { payload = decoded } }
                )
                Spacer(minLength: 0)
            }
        }
    }

    /// The live QR image for the current payload, or nil when the payload is
    /// empty or CoreImage declines to render it.
    private var generatedImage: NSImage? {
        QRGenerator.image(for: payload, context: ciContext, sidePoints: 150)
    }

    private func copyGeneratedImage() {
        guard let image = generatedImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.writeObjects([image])
        guard ok else { return }
        copiedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            copiedFlash = false
        }
    }

    // MARK: - Decode

    private var decodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Decode")

            dropWell

            HStack(spacing: 8) {
                QRGlassButton(
                    title: "Read Clipboard Image",
                    systemImage: "clipboard",
                    tint: .white,
                    enabled: true,
                    action: decodeFromClipboard
                )
                Spacer(minLength: 0)
            }

            QRResultPanel(status: decodeStatus, decoded: decoded)
        }
    }

    private var dropWell: some View {
        let stroke = isTargeted ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.12)
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(isTargeted ? 0.30 : 0.22))
            .frame(height: 84)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1.3, dash: [5, 4]))
            )
            .overlay(
                VStack(spacing: 5) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.4))
                    Text("Drop a QR image here")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            )
            .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
            .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    // MARK: - Decode actions

    /// Pull an image off the dragged providers and decode it. Tries an inline
    /// image first, then a file URL. Returns true if a provider was accepted.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        decodeStatus = .working

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                let image = object as? NSImage
                Task { @MainActor in self.decode(image) }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let image = url.flatMap { NSImage(contentsOf: $0) }
                Task { @MainActor in self.decode(image) }
            }
            return true
        }

        decodeStatus = .noImage
        return false
    }

    private func decodeFromClipboard() {
        decodeStatus = .working
        guard let image = QRClipboardImage.read() else {
            decoded = nil
            decodeStatus = .noImage
            return
        }
        decode(image)
    }

    /// Run Vision over the image and surface the first decoded payload. All the
    /// failure modes resolve to a calm status, never a crash.
    private func decode(_ image: NSImage?) {
        guard let image else {
            decoded = nil
            decodeStatus = .noImage
            return
        }
        guard let cgImage = QRDecoder.cgImage(from: image) else {
            decoded = nil
            decodeStatus = .noImage
            return
        }
        QRDecoder.read(cgImage) { result in
            Task { @MainActor in
                switch result {
                case let .some(text):
                    self.decoded = text
                    self.decodeStatus = .decoded
                case .none:
                    self.decoded = nil
                    self.decodeStatus = .notFound
                }
            }
        }
    }

    // MARK: - Subviews

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.40))
            .tracking(0.5)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}

// MARK: - Status

/// The state of the decode half, used to pick the right inline message.
private enum QRStatusKind: Equatable {
    case idle
    case working
    case decoded
    case notFound
    case noImage
}

// MARK: - Preview box

/// Renders the generated QR on a light card so it stays scannable against the
/// dark tile, or a placeholder when there's nothing to show.
private struct QRPreviewBox: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.92))
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 24))
                        .foregroundStyle(.black.opacity(0.30))
                    Text("Enter text to encode")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.black.opacity(0.35))
                }
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Result panel

private struct QRResultPanel: View {
    let status: QRStatusKind
    let decoded: String?

    var body: some View {
        Group {
            switch status {
            case .idle:
                message(icon: "qrcode.viewfinder",
                        text: "Drop or paste an image to read its QR.",
                        tint: .white.opacity(0.40))
            case .working:
                message(icon: "hourglass",
                        text: "Reading…",
                        tint: .white.opacity(0.55))
            case .noImage:
                message(icon: "photo.badge.exclamationmark",
                        text: "No image found there.",
                        tint: .orange.opacity(0.85))
            case .notFound:
                message(icon: "questionmark.circle",
                        text: "No QR or barcode detected in that image.",
                        tint: .orange.opacity(0.85))
            case .decoded:
                decodedView
            }
        }
    }

    @ViewBuilder
    private var decodedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Decoded")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(0.4)
                Spacer(minLength: 0)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(decoded ?? "", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Copy decoded text")
            }
            ScrollView(.vertical, showsIndicators: false) {
                Text(decoded ?? "")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 88)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func message(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
            Text(text)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

// MARK: - Glass button

private struct QRGlassButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(enabled ? tint.opacity(0.9) : Color.white.opacity(0.30))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(enabled ? 0.08 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
            .animation(.spring(response: 0.25), value: tint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
    }
}

// MARK: - Generation

/// Encodes a string into a QR image using CoreImage. Pure and crash-free:
/// empty input or a render failure returns nil.
private enum QRGenerator {

    /// A QR `NSImage` for `text`, scaled up to roughly `sidePoints` on a side.
    /// Returns nil for empty input or if CoreImage produces nothing.
    static func image(for text: String, context: CIContext, sidePoints: CGFloat) -> NSImage? {
        let trimmed = text
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) ?? trimmed.data(using: .isoLatin1)
        else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        // Scale the tiny native output up to a crisp, nearest-neighbour bitmap.
        let scale = max(1, sidePoints / max(output.extent.width, 1))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        let side = CGFloat(cgImage.width)
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}

// MARK: - Decoding

/// Reads barcodes/QR codes out of an image via Vision. The work runs off the
/// main actor; `read` calls its completion with the first payload or nil.
private enum QRDecoder {

    /// Best-effort conversion of an `NSImage` to a `CGImage` for Vision.
    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Detect barcodes and return the first non-empty payload string, or nil.
    /// The completion is always called exactly once, on a background thread.
    static func read(_ cgImage: CGImage, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNDetectBarcodesRequest()
            // Restrict to symbologies that make sense for this tile when the
            // API is available; otherwise let Vision scan everything.
            if #available(macOS 11.0, *) {
                request.symbologies = [.qr, .aztec, .dataMatrix, .pdf417, .code128]
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                completion(nil)
                return
            }

            let payloads = (request.results ?? [])
                .compactMap { $0.payloadStringValue }
                .filter { !$0.isEmpty }

            completion(payloads.first)
        }
    }
}

// MARK: - Clipboard image

/// Pulls a bitmap image off the general pasteboard, if one is present.
private enum QRClipboardImage {

    static func read() -> NSImage? {
        let pb = NSPasteboard.general

        // Prefer a real image object, then fall back to raw bitmap data.
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            return first
        }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }
}

// MARK: - Preview

#Preview("QR Scratchpad") {
    QRScratchpadView()
        .frame(width: 360, height: 440)
        .padding(20)
        .background(Color.black)
}
