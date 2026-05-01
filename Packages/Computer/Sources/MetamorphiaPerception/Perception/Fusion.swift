import Foundation
import CoreGraphics

/// Merges AX tree elements with OCR results. AX is authoritative — OCR fills gaps.
public enum Fusion {

    /// Merge AX elements with OCR-discovered text. Removes OCR results that overlap AX elements.
    /// `imageWidth`/`imageHeight` are the raw CGImage pixel dimensions.
    /// `displayScaleFactor` is the display's backing scale factor (2 on Retina, 1 on non-Retina).
    /// OCR normalized coords are converted from pixel space to point space for AX/CGEvent compatibility.
    ///
    /// `displays` is the display layout snapshot for the frame; each synthesized
    /// OCR element is tagged with the display whose bounds contain its rect
    /// center. `sourceDisplayIndex` biases the OCR's coordinate origin when
    /// the capture came from a non-main display — callers that captured only
    /// one display pass its index so the rect is offset into the global
    /// coordinate space rather than the per-display local space.
    public static func merge(
        ax: [ScreenElement],
        ocr: [OCRReader.OCRResult],
        imageWidth: Int,
        imageHeight: Int,
        refStabilizer: RefStabilizer,
        appBundleID: String?,
        windowIndex: Int,
        displayScaleFactor: Int = 2,
        displays: [DisplayInfo] = [],
        sourceDisplayIndex: Int = 0,
        screenshotForDHash: CGImage? = nil
    ) -> [ScreenElement] {
        var merged = ax

        // CGWindowListCreateImage with .bestResolution returns pixel dimensions (2x on Retina),
        // but AX and CGEvent coordinates use point space. Divide by scale factor to convert.
        let pointWidth = imageWidth / displayScaleFactor
        let pointHeight = imageHeight / displayScaleFactor

        // If the OCR input came from a non-main display, OCR coordinates are
        // relative to that display's top-left corner. Offset them back into
        // the global CG/top-left space so AX-derived bounds remain comparable.
        let originOffset: CGPoint
        if !displays.isEmpty,
           sourceDisplayIndex >= 0,
           sourceDisplayIndex < displays.count {
            originOffset = displays[sourceDisplayIndex].topLeftOrigin
        } else {
            originOffset = .zero
        }

        for ocrResult in ocr {
            var screenRect = OCRReader.toScreenCoordinates(
                ocrResult.boundingBox, imageWidth: pointWidth, imageHeight: pointHeight
            )
            if originOffset != .zero {
                screenRect = screenRect.offsetBy(dx: originOffset.x, dy: originOffset.y)
            }
            let center = CGPoint(x: screenRect.midX, y: screenRect.midY)

            // Skip if this OCR text overlaps with an existing AX element
            let overlaps = ax.contains { el in
                guard let elBounds = el.bounds else { return false }
                return significantOverlap(elBounds, screenRect)
            }

            guard !overlaps && ocrResult.confidence > 0.5 else { continue }

            // Classify: if text looks like a button label (short, near edges), mark as ocrButton
            let role: ElementRole = looksClickable(ocrResult.text, rect: screenRect) ? .ocrButton : .ocrText

            // Tier-6 visual fingerprint. Crop the OCR element's pixel region
            // from the retained screenshot, run the existing 8×8 dHash. The
            // combination of (text, grid bucket, dhash) is what makes
            // canvas-drawn buttons (Figma toolbar icons, game UI) teachable:
            // reflows preserve two of the three and we still recognize.
            // Callers that didn't hand in a screenshot (e.g. the OCR-off
            // skip path) pass `nil` and we store nil here — Tier-6 won't
            // engage for those elements, they use Tier-4 label identity.
            let (dHashValue, gridBucket) = computeVisualFingerprint(
                for: screenRect,
                originOffset: originOffset,
                scale: displayScaleFactor,
                screenshot: screenshotForDHash
            )

            // OCR elements have no AX identifier, no ancestry, and no parent container
            // (they're synthesized screen-space boxes). Label-tier identity with an empty
            // ancestry hash gives them stable refs across snapshots as long as the text
            // content survives. When the visual fingerprint is present the stabilizer
            // prefers Tier-6 (visual) over the empty-ancestry label tier — more stable
            // across text-animation ticks where the label momentarily changes.
            let assignment = RefAssignment(
                bundleID: appBundleID,
                role: role,
                label: ocrResult.text,
                identifier: "",
                bounds: screenRect,
                parentBounds: nil,
                ancestryHash: AncestryHash.empty,
                depth: 0,
                siblingIndex: 0,
                visualDHash: dHashValue,
                visualText: ocrResult.text,
                visualGridBucket: gridBucket
            )
            let ref = refStabilizer.assign(assignment)

            // Resolve display from the global rect center; fall back to the
            // source display when the rect center lands outside every known
            // display bounds (rare — only at display edges).
            let displayIndex: Int = displays.isEmpty
                ? sourceDisplayIndex
                : WindowEnumerator.displayIndexForTopLeftPoint(center, displays: displays)

            merged.append(ScreenElement(
                ref: ref,
                role: role,
                subrole: "",
                label: ocrResult.text,
                value: "",
                bounds: screenRect,
                clickPoint: center,
                state: .enabled,
                actions: role == .ocrButton ? [.press] : [],
                parentRef: nil,
                depth: 0,
                source: .ocr,
                confidence: ocrResult.confidence,
                appBundleID: appBundleID,
                windowIndex: windowIndex,
                displayIndex: displayIndex
            ))
        }

        return merged
    }

    // MARK: - Helpers

    /// Two rects overlap significantly (>50% of the smaller rect's area).
    private static func significantOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return false }
        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(a.width * a.height, b.width * b.height)
        guard smallerArea > 0 else { return false }
        return intersectionArea / smallerArea > 0.5
    }

    /// Heuristic: short text (1-3 words, <30 chars) in a small rect looks like a button.
    private static func looksClickable(_ text: String, rect: CGRect) -> Bool {
        let wordCount = text.split(separator: " ").count
        return text.count < 30 && wordCount <= 3 && rect.height < 60
    }

    /// Compute the Tier-6 visual fingerprint for an element: an 8×8 dHash of
    /// its cropped pixel region plus a coarse 50-point screen-grid bucket.
    /// Returns `(nil, nil)` when cropping fails (rect outside screenshot,
    /// zero area, no screenshot handed in) — callers simply skip Tier-6
    /// identity for those elements.
    ///
    /// The crop translates screen-points to pixel space via `scale`. The
    /// `originOffset` is subtracted first so a non-main-display capture
    /// (where global rects sit at e.g. x=2560+) maps back to the local
    /// 0-origin pixel coordinates of the CGImage we actually hold.
    private static func computeVisualFingerprint(
        for screenRect: CGRect,
        originOffset: CGPoint,
        scale: Int,
        screenshot: CGImage?
    ) -> (UInt64?, RefAssignment.VisualGridBucket?) {
        guard let screenshot,
              screenRect.width >= 4, screenRect.height >= 4,
              scale > 0 else { return (nil, nil) }

        let local = screenRect.offsetBy(dx: -originOffset.x, dy: -originOffset.y)
        let pixelRect = CGRect(
            x: local.origin.x * CGFloat(scale),
            y: local.origin.y * CGFloat(scale),
            width: local.size.width * CGFloat(scale),
            height: local.size.height * CGFloat(scale)
        )
        let imageBounds = CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height)
        let clipped = pixelRect.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 4, clipped.height >= 4 else {
            return (nil, nil)
        }
        guard let crop = screenshot.cropping(to: clipped) else { return (nil, nil) }

        let dhash = ScreenCapture.dHash(crop)
        let bucket = RefAssignment.VisualGridBucket(
            x: Int((screenRect.midX / 50).rounded(.down)),
            y: Int((screenRect.midY / 50).rounded(.down))
        )
        return (dhash, bucket)
    }
}
