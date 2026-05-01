import Foundation
import CoreGraphics
import AppKit

/// Fast in-memory screenshot capture via CGWindowListCreateImage.
public enum ScreenCapture {

    /// Capture the entire main display.
    public static func captureMainDisplay() -> CGImage? {
        let mainIndex = WindowEnumerator.mainDisplay().index
        return captureDisplay(index: mainIndex)
    }

    /// Capture a specific display by its `DisplayInfo.index` (the `NSScreen.screens`
    /// ordinal). Returns `nil` if the index is out of range or the capture fails.
    ///
    /// `CGWindowListCreateImage` expects a rect in **top-left, Y-down** space;
    /// we convert from `NSScreen` Cartesian (Y-up) via `DisplayInfo.topLeftBounds`.
    public static func captureDisplay(index: Int) -> CGImage? {
        let displays = WindowEnumerator.allDisplays()
        guard index >= 0, index < displays.count else { return nil }
        let display = displays[index]
        let rect = display.topLeftBounds
        return CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }

    /// Capture every attached display. The returned tuples preserve the
    /// `NSScreen.screens` order; `image` is `nil` for displays that failed
    /// to capture (e.g., hot-unplugged during the call).
    public static func captureAllDisplays() -> [(display: DisplayInfo, image: CGImage?)] {
        let displays = WindowEnumerator.allDisplays()
        return displays.map { display in
            (display: display, image: captureDisplay(index: display.index))
        }
    }

    /// Capture the frontmost window only.
    public static func captureFrontWindow() -> CGImage? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            return CGWindowListCreateImage(
                CGRect.null,
                .optionIncludingWindow,
                windowID,
                [.bestResolution, .boundsIgnoreFraming]
            )
        }

        return nil
    }

    /// Capture a specific screen region.
    public static func captureRegion(_ rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }

    /// Convert CGImage to PNG data.
    public static func toPNGData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Convert CGImage to base64-encoded PNG, scaled to maxWidth.
    public static func toBase64(_ image: CGImage, maxWidth: Int = 1024) -> String? {
        let originalWidth = image.width
        let originalHeight = image.height

        let scaledImage: CGImage
        if originalWidth > maxWidth {
            let scale = CGFloat(maxWidth) / CGFloat(originalWidth)
            let newWidth = Int(CGFloat(originalWidth) * scale)
            let newHeight = Int(CGFloat(originalHeight) * scale)

            guard let context = CGContext(
                data: nil, width: newWidth, height: newHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            guard let scaled = context.makeImage() else { return nil }
            scaledImage = scaled
        } else {
            scaledImage = image
        }

        guard let pngData = toPNGData(scaledImage) else { return nil }
        return pngData.base64EncodedString()
    }

    // MARK: - Perceptual Hashing (dHash)

    /// Difference hash for fast screen change detection. Cost: <0.5ms on Apple Silicon.
    public static func dHash(_ image: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let idx = row * width + col
                if pixels[idx] > pixels[idx + 1] {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }

        return hash
    }

    /// Hamming distance between two dHash values.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
