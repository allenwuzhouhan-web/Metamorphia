/*
 * Metamorphia
 * Native LaTeX math rendering — raster / PDF export.
 *
 * Renders a `MathView` off-screen into an `NSImage` or a PDF `Data` blob for
 * the clipboard, the shelf, or file export. Uses SwiftUI's `ImageRenderer`, so
 * no AppKit drawing is duplicated. Returns nil on failure instead of crashing.
 */

import SwiftUI
import AppKit

/// Off-screen export of rendered LaTeX math.
public enum MathImageExporter {

    /// A point size that reads well in exported artwork (export tends to be
    /// viewed larger than inline math).
    private static let exportFontSize: CGFloat = 28

    /// Upper bound on the source length we'll rasterize. `ImageRenderer`
    /// rasterizes the recursive `MathView` layout synchronously on the main
    /// actor, so a pathologically large expression would freeze the UI for the
    /// duration of the copy. We fail fast past this cap instead — callers
    /// surface the existing "Failed" feedback. Generous enough that any normal
    /// expression a person actually types passes through untouched.
    private static let maxExportSourceLength = 4000

    /// Render LaTeX to a raster `NSImage`. `scale` multiplies the backing
    /// resolution (use 2–3 for crisp output). Returns nil if rendering fails or
    /// the source is too large to rasterize safely.
    @MainActor
    public static func image(latex: String, display: Bool, scale: CGFloat, color: NSColor) -> NSImage? {
        guard latex.count <= maxExportSourceLength else { return nil }
        let view = exportView(latex: latex, display: display, color: Color(nsColor: color))
        let renderer = ImageRenderer(content: view)
        renderer.scale = max(1, scale)
        renderer.isOpaque = false
        return renderer.nsImage
    }

    /// Render LaTeX to a single-page PDF document. Returns nil if rendering
    /// fails or the source is too large to rasterize safely.
    @MainActor
    public static func pdf(latex: String, display: Bool, color: NSColor) -> Data? {
        guard latex.count <= maxExportSourceLength else { return nil }
        let view = exportView(latex: latex, display: display, color: Color(nsColor: color))
        let renderer = ImageRenderer(content: view)

        let data = NSMutableData()
        var succeeded = false

        renderer.render { size, renderInContext in
            let mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return }
            var box = mediaBox
            guard let pdfContext = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            pdfContext.beginPDFPage(nil)
            renderInContext(pdfContext)
            pdfContext.endPDFPage()
            pdfContext.closePDF()
            succeeded = true
        }

        return succeeded && data.length > 0 ? data as Data : nil
    }

    /// The padded, sized view used for both raster and PDF export.
    @MainActor
    private static func exportView(latex: String, display: Bool, color: Color) -> some View {
        MathView(latex, display: display, fontSize: exportFontSize, color: color)
            .padding(display ? 18 : 10)
            .fixedSize()
    }
}
