import XCTest
import CoreGraphics
import AppKit
@testable import MetamorphiaPerception

/// Rank 8 — Cropped vision diffs.
///
/// Covers:
/// - No-change → nil (skip vision call entirely)
/// - Single-element crop
/// - Multi-element bounding-box union
/// - Fullscreen fallback when union area exceeds threshold
/// - Minimum-area suppression
/// - Margin expansion
/// - Out-of-bounds clamping
/// - Fallback-tier force-inclusion
/// - Policy variants (default / aggressive / conservative)
/// - Base64 size cap with downsampling
/// - Confidence heuristic
/// - Multi-display partitioning
final class VisionDifferTests: XCTestCase {

    // MARK: - 1. No changes → nil

    func testDiff_noChanges_returnsNil() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let map = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "Save", bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label
        ]
        // Force fallback tier off so no noise is injected — without it the
        // label-tier diff already has zero contributors.
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        let diff = VisionDiffer.diff(
            previous: map, current: map,
            currentImage: image,
            tiers: tiers, policy: policy
        )
        XCTAssertNil(diff, "no changes → differ returns nil")
    }

    // MARK: - 2. Single changed element → correct crop

    func testDiff_singleChangedElement_CroppedCorrectly() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let bounds = CGRect(x: 200, y: 200, width: 100, height: 50)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "Save", bounds: bounds)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "Save Changes", bounds: bounds)
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label
        ]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.marginPx = 16
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        // Crop = bounds inflated by 16 on each side, clamped to image.
        XCTAssertEqual(unwrapped.changeRegion.origin.x, bounds.origin.x - 16, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.origin.y, bounds.origin.y - 16, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.width, bounds.width + 32, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.height, bounds.height + 32, accuracy: 1)
        XCTAssertFalse(unwrapped.fullScreenFallback)
        XCTAssertEqual(unwrapped.changedRefs, [ElementRef(index: 1)])
        XCTAssertFalse(unwrapped.croppedBase64.isEmpty)
    }

    // MARK: - 3. Multiple changed elements → bounding union

    func testDiff_multipleChangedElements_BoundingUnion() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let b1 = CGRect(x: 100, y: 100, width: 80, height: 30)
        let b2 = CGRect(x: 400, y: 500, width: 60, height: 40)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: b1),
            makeElement(ref: 2, label: "B", bounds: b2)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: b1),
            makeElement(ref: 2, label: "B*", bounds: b2)
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .label
        ]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.marginPx = 0
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        // Union covers both boxes: x=100..460, y=100..540.
        let union = b1.union(b2)
        XCTAssertEqual(unwrapped.changeRegion.origin.x, union.origin.x, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.origin.y, union.origin.y, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.width, union.width, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.height, union.height, accuracy: 1)
    }

    // MARK: - 4. Spans > 70% of display → fullscreen fallback

    func testDiff_changeSpansFullScreen_FallbackEmitted() {
        // 1000x1000 display, single changed element covering 900x900 (81% area)
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let big = CGRect(x: 50, y: 50, width: 900, height: 900)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: big)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: big)
        ])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.fullScreenThreshold = 0.7
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        XCTAssertTrue(unwrapped.fullScreenFallback)
        XCTAssertEqual(unwrapped.changeRegion.width, 1000, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.height, 1000, accuracy: 1)
    }

    // MARK: - 5. Tiny change below min area → nil

    func testDiff_changeBelowMinArea_ReturnsNil() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        // 2x2 area = 4 px² — below minDiffArea = 100.
        let tiny = CGRect(x: 50, y: 50, width: 2, height: 2)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: tiny)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: tiny)
        ])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.minDiffArea = 100
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        XCTAssertNil(diff)
    }

    // MARK: - 6. Margin expansion

    func testDiff_withMargin_ExpandedRegion() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let bounds = CGRect(x: 200, y: 200, width: 100, height: 100)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: bounds)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: bounds)
        ])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.marginPx = 50

        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        XCTAssertEqual(unwrapped.changeRegion.width, bounds.width + 100, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.height, bounds.height + 100, accuracy: 1)
    }

    // MARK: - 7. Out-of-bounds → clamped to image

    func testDiff_croppedToImageBounds_NoOverflow() {
        let image = makeSyntheticCGImage(width: 500, height: 500, color: .gray)
        // Element at corner — margin would push off image.
        let bounds = CGRect(x: 10, y: 10, width: 60, height: 60)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: bounds)
        ], displayWidth: 500, displayHeight: 500)
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: bounds)
        ], displayWidth: 500, displayHeight: 500)
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.marginPx = 100 // would extend to x=-90, which must clamp to 0
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        XCTAssertGreaterThanOrEqual(unwrapped.changeRegion.origin.x, 0)
        XCTAssertGreaterThanOrEqual(unwrapped.changeRegion.origin.y, 0)
        XCTAssertLessThanOrEqual(unwrapped.changeRegion.maxX, 500)
        XCTAssertLessThanOrEqual(unwrapped.changeRegion.maxY, 500)
    }

    // MARK: - 8. Fallback tier force-included

    func testDiff_forceVisionFallbackTier_IncludesLowScore() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let changedBounds = CGRect(x: 100, y: 100, width: 50, height: 50)
        let fallbackBounds = CGRect(x: 700, y: 700, width: 80, height: 40)
        // Both maps share ref@1 (changed label) and ref@2 (unchanged, but
        // fallback tier). With forceVisionForFallbackTier, ref@2 is folded in.
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: changedBounds),
            makeElement(ref: 2, label: "Legacy", bounds: fallbackBounds)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: changedBounds),
            makeElement(ref: 2, label: "Legacy", bounds: fallbackBounds)
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .fallback
        ]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = true
        policy.marginPx = 0
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        // Union should cover both regions — so the region extends out to
        // cover the fallback element.
        let expected = changedBounds.union(fallbackBounds)
        XCTAssertEqual(unwrapped.changeRegion.origin.x, expected.origin.x, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.origin.y, expected.origin.y, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.width, expected.width, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.height, expected.height, accuracy: 1)
    }

    // MARK: - 9. Fallback ignored when policy off

    func testDiff_tiersIgnoredWhenPolicyOff() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let changedBounds = CGRect(x: 100, y: 100, width: 50, height: 50)
        let fallbackBounds = CGRect(x: 700, y: 700, width: 80, height: 40)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: changedBounds),
            makeElement(ref: 2, label: "Legacy", bounds: fallbackBounds)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: changedBounds),
            makeElement(ref: 2, label: "Legacy", bounds: fallbackBounds)
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .fallback
        ]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.marginPx = 0
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        // Only the changed element's bounds — the fallback element is ignored.
        XCTAssertEqual(unwrapped.changeRegion.origin.x, changedBounds.origin.x, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.origin.y, changedBounds.origin.y, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.width, changedBounds.width, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.height, changedBounds.height, accuracy: 1)
    }

    // MARK: - 10. Base64 cap → downsample

    func testDiff_maxBase64Bytes_DownsamplesWhenOverLimit() {
        // Large image → full frame crop (via fallback) yields big base64.
        // Set a tiny maxBytes so downsampling kicks in.
        let image = makeSyntheticCGImage(width: 2000, height: 2000, color: .gray)
        let big = CGRect(x: 100, y: 100, width: 1800, height: 1800)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: big)
        ], displayWidth: 2000, displayHeight: 2000)
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: big)
        ], displayWidth: 2000, displayHeight: 2000)
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.marginPx = 0
        policy.fullScreenThreshold = 0.99 // don't trigger fallback
        policy.maxBase64Bytes = 16 * 1024 // tiny cap
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        XCTAssertLessThanOrEqual(unwrapped.croppedBase64.utf8.count, 16 * 1024,
                                 "base64 must be <= maxBase64Bytes after downsampling")
        // Final image dimensions reflect downsampling.
        XCTAssertLessThan(unwrapped.imageWidth, 2000,
                          "downsampled image must be smaller than original")
    }

    // MARK: - 11. Confidence computation

    func testDiff_confidenceComputation() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let changedBounds = CGRect(x: 100, y: 100, width: 50, height: 50)
        let noiseBounds = CGRect(x: 500, y: 500, width: 60, height: 60)

        // Case A: 1 changed + 1 fallback-noise → confidence = 1/2 = 0.5
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: changedBounds),
            makeElement(ref: 2, label: "Legacy", bounds: noiseBounds)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: changedBounds),
            makeElement(ref: 2, label: "Legacy", bounds: noiseBounds)
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .fallback
        ]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = true
        policy.marginPx = 0
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(diff)
        XCTAssertEqual(unwrapped.confidence, 0.5, accuracy: 0.01,
                       "1 signal + 1 noise → 0.5 confidence")

        // Case B: pure signal, no fallback → confidence = 1.0
        var policyB = policy
        policyB.forceVisionForFallbackTier = false
        let diffB = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers, policy: policyB
        )
        let unwrappedB = try! XCTUnwrap(diffB)
        XCTAssertEqual(unwrappedB.confidence, 1.0, accuracy: 0.01,
                       "no fallback sweep → 1.0 confidence")
    }

    // MARK: - 12. Multi-display → two regions

    func testDiffMultiDisplay_twoDisplays_TwoRegions() {
        let image0 = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let image1 = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)

        let d0 = DisplayInfo(id: 1, index: 0, name: "D0", origin: .zero,
                             width: 1000, height: 1000, scale: 1, isMain: true)
        let d1 = DisplayInfo(id: 2, index: 1, name: "D1",
                             origin: CGPoint(x: 1000, y: 0),
                             width: 1000, height: 1000, scale: 1, isMain: false)

        let e0Bounds = CGRect(x: 100, y: 100, width: 80, height: 40)
        let e1Bounds = CGRect(x: 1200, y: 200, width: 120, height: 60)

        let prev = makeMapWithDisplays(displays: [d0, d1], elements: [
            makeElement(ref: 1, label: "A", bounds: e0Bounds, displayIndex: 0),
            makeElement(ref: 2, label: "B", bounds: e1Bounds, displayIndex: 1)
        ])
        let curr = makeMapWithDisplays(displays: [d0, d1], elements: [
            makeElement(ref: 1, label: "A*", bounds: e0Bounds, displayIndex: 0),
            makeElement(ref: 2, label: "B*", bounds: e1Bounds, displayIndex: 1)
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .label
        ]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        policy.marginPx = 0

        let multi = VisionDiffer.diffMultiDisplay(
            previous: prev, current: curr,
            currentImagesByDisplay: [0: image0, 1: image1],
            tiers: tiers, policy: policy
        )
        let unwrapped = try! XCTUnwrap(multi)
        XCTAssertEqual(unwrapped.secondary.count, 1, "one secondary display expected")
        // Primary picks the display with the larger change area — display 1
        // (120x60 = 7200) vs display 0 (80x40 = 3200).
        XCTAssertEqual(unwrapped.primary.changeRegionDisplayIndex, 1)
        XCTAssertEqual(unwrapped.secondary.first?.changeRegionDisplayIndex, 0)
    }

    // MARK: - 13. Crop helper — exact size

    func testCrop_smallRegion_ReturnsCorrectSize() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let region = CGRect(x: 100, y: 100, width: 200, height: 150)
        let cropped = try! XCTUnwrap(VisionDiffer.crop(image, to: region, margin: 0))
        XCTAssertEqual(cropped.width, 200)
        XCTAssertEqual(cropped.height, 150)
    }

    // MARK: - 14. Crop helper — clamps out-of-bounds

    func testCrop_outOfBounds_Clamps() {
        let image = makeSyntheticCGImage(width: 500, height: 500, color: .gray)
        // Region extends off the bottom-right corner
        let region = CGRect(x: 400, y: 400, width: 300, height: 300)
        let cropped = try! XCTUnwrap(VisionDiffer.crop(image, to: region, margin: 0))
        // Should clamp to image bounds: width=100, height=100
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 100)

        // Region entirely inside, but negative origin via margin
        let region2 = CGRect(x: 10, y: 10, width: 100, height: 100)
        let cropped2 = try! XCTUnwrap(VisionDiffer.crop(image, to: region2, margin: 50))
        // Margin of 50 would push origin to (-40, -40) — clamped to (0, 0),
        // width/height = 110.
        XCTAssertEqual(cropped2.width, 160)
        XCTAssertEqual(cropped2.height, 160)
    }

    // MARK: - 15. Union-region helper — multiple changed refs

    func testUnionRegion_MultipleChangedRefs_CorrectBounds() {
        let b1 = CGRect(x: 100, y: 100, width: 50, height: 30)
        let b2 = CGRect(x: 300, y: 400, width: 80, height: 60)
        let b3 = CGRect(x: 500, y: 200, width: 40, height: 40)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: b1),
            makeElement(ref: 2, label: "B", bounds: b2),
            makeElement(ref: 3, label: "C", bounds: b3)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: b1),
            makeElement(ref: 2, label: "B*", bounds: b2),
            makeElement(ref: 3, label: "C*", bounds: b3)
        ])
        let tiers: [ElementRef: IdentityTier] = [
            ElementRef(index: 1): .label,
            ElementRef(index: 2): .label,
            ElementRef(index: 3): .label
        ]
        var policy = VisionDiffPolicy.default
        policy.forceVisionForFallbackTier = false
        guard let (region, idx, changed, _, _) = VisionDiffer.unionRegion(
            previous: prev, current: curr,
            tiers: tiers, policy: policy
        ) else {
            XCTFail("unionRegion should not return nil")
            return
        }
        let expected = b1.union(b2).union(b3)
        XCTAssertEqual(region.origin.x, expected.origin.x, accuracy: 1)
        XCTAssertEqual(region.origin.y, expected.origin.y, accuracy: 1)
        XCTAssertEqual(region.width, expected.width, accuracy: 1)
        XCTAssertEqual(region.height, expected.height, accuracy: 1)
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(changed.count, 3)
    }

    // MARK: - 16. Aggressive policy — tighter margin

    func testPolicy_aggressive_tighterMargin() {
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let bounds = CGRect(x: 200, y: 200, width: 100, height: 100)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: bounds)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: bounds)
        ])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        let diff = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers,
            policy: .aggressive
        )
        let unwrapped = try! XCTUnwrap(diff)
        // Aggressive margin = 8, so region is bounds + 16.
        XCTAssertEqual(unwrapped.changeRegion.width, bounds.width + 16, accuracy: 1)
        XCTAssertEqual(unwrapped.changeRegion.height, bounds.height + 16, accuracy: 1)
        XCTAssertEqual(VisionDiffPolicy.aggressive.marginPx, 8)
    }

    // MARK: - 17. Conservative policy — higher threshold

    func testPolicy_conservative_higherThreshold() {
        // 1000x1000 display, element 750x750 = 56%.
        // default threshold = 0.7 → should stay as crop.
        // conservative threshold = 0.8 → still crop.
        // Let's do element 800x800 = 64% — still below both thresholds but
        // above default's threshold when margin is added.
        let image = makeSyntheticCGImage(width: 1000, height: 1000, color: .gray)
        let mid = CGRect(x: 100, y: 100, width: 800, height: 800)
        let prev = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: mid)
        ])
        let curr = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: mid)
        ])
        let tiers: [ElementRef: IdentityTier] = [ElementRef(index: 1): .label]
        // With default policy: margin 32 → region 864x864 = 746K = 74.6% of area
        // → fullscreen fallback (threshold 0.7).
        var defaultPolicy = VisionDiffPolicy.default
        defaultPolicy.forceVisionForFallbackTier = false
        let diffDefault = VisionDiffer.diff(
            previous: prev, current: curr,
            currentImage: image, tiers: tiers,
            policy: defaultPolicy
        )
        XCTAssertEqual(diffDefault?.fullScreenFallback, true,
                       "default policy should trigger fullscreen fallback here")

        // With conservative policy: threshold 0.8 but also margin 64 → region
        // 928x928 = 861K = 86.1%. That's above 0.8 too, so still fullscreen.
        // To really show conservative gives different behavior, use a smaller
        // element (500x500 = 25% area, margined 628x628 = 39.4%) — both
        // policies should crop it.
        let smaller = CGRect(x: 100, y: 100, width: 500, height: 500)
        let prev2 = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A", bounds: smaller)
        ])
        let curr2 = makeSyntheticMap(elements: [
            makeElement(ref: 1, label: "A*", bounds: smaller)
        ])
        var conservative = VisionDiffPolicy.conservative
        conservative.forceVisionForFallbackTier = false
        let diffConservative = VisionDiffer.diff(
            previous: prev2, current: curr2,
            currentImage: image, tiers: tiers,
            policy: conservative
        )
        let unwrapped = try! XCTUnwrap(diffConservative)
        XCTAssertFalse(unwrapped.fullScreenFallback)
        XCTAssertEqual(VisionDiffPolicy.conservative.fullScreenThreshold, 0.8)
        XCTAssertEqual(VisionDiffPolicy.conservative.marginPx, 64)
    }

    // MARK: - Helpers

    /// Render a solid-color CGImage at the given size. Fastest way to get a
    /// valid CGImage for crop/encode tests without hitting real screen.
    private func makeSyntheticCGImage(width: Int, height: Int, color: NSColor) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private func makeSyntheticMap(
        elements: [ScreenElement],
        displayWidth: Int = 1000,
        displayHeight: Int = 1000
    ) -> ScreenMap {
        makeMapWithDisplays(
            displays: [
                DisplayInfo(
                    id: 1, index: 0, name: "Main", origin: .zero,
                    width: displayWidth, height: displayHeight,
                    scale: 1, isMain: true
                )
            ],
            elements: elements
        )
    }

    private func makeMapWithDisplays(
        displays: [DisplayInfo],
        elements: [ScreenElement]
    ) -> ScreenMap {
        ScreenMap(
            timestamp: Date(),
            captureMs: 1,
            displays: displays,
            focusedApp: AppInfo(name: "Test", bundleID: "com.test", pid: 1),
            windows: [
                WindowInfo(
                    index: 0, appName: "Test", appBundleID: "com.test",
                    title: "Win", bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    isFocused: true, layer: 0, displayIndex: 0
                )
            ],
            elements: elements,
            navigation: nil,
            safety: .empty,
            metadata: CaptureMetadata(
                axCoveragePercent: 1, ocrUsed: false,
                elementCount: elements.count,
                interactiveCount: elements.filter { $0.role.isInteractive }.count,
                offScreenHint: nil
            )
        )
    }

    private func makeElement(
        ref: Int,
        label: String,
        bounds: CGRect,
        displayIndex: Int = 0
    ) -> ScreenElement {
        ScreenElement(
            ref: ElementRef(index: ref),
            role: .button,
            subrole: "",
            label: label,
            value: "",
            bounds: bounds,
            clickPoint: CGPoint(x: bounds.midX, y: bounds.midY),
            state: .enabled,
            actions: [.press],
            parentRef: nil,
            depth: 0,
            source: .accessibility,
            confidence: 1.0,
            appBundleID: "com.test",
            windowIndex: 0,
            displayIndex: displayIndex
        )
    }
}
