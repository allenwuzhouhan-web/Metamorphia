import Foundation
import CoreGraphics
import AppKit

// MARK: - Vision Diff

/// Rank 8 — the cropped-region output of the vision differ.
///
/// A `VisionDiff` is what callers send to an LLM vision API. Instead of
/// shipping the full 3840×2160 display screenshot every frame, the differ
/// computes the bounding box of every changed element between the previous
/// and current `ScreenMap`, adds a margin, crops the full-resolution image
/// to that region, and encodes just the cropped PNG as base64.
///
/// The savings are dramatic on sticky UIs: a 500×400 region inside a 4K
/// display ships ~0.5 MB of base64 vs. ~8 MB for the full screen — a ~94%
/// reduction in LLM vision-API payload.
public struct VisionDiff: Sendable {
    /// Opaque session key the caller supplied to `VisionDiffer.diff`. Threaded
    /// through so downstream pipelines (cache keys, logging) can group diffs
    /// by session.
    public let sessionID: String

    /// Wall-clock timestamp the diff was computed.
    public let timestamp: Date

    /// Bounding box of the change region in the source image's pixel
    /// coordinates (top-left origin). Includes the configured margin and is
    /// clamped to image bounds. For `fullScreenFallback == true`, this is the
    /// full image rect.
    public let changeRegion: CGRect

    /// Display index the change region belongs to. Matches
    /// `ScreenElement.displayIndex` / `ScreenMap.displays[i].index`.
    public let changeRegionDisplayIndex: Int

    /// The cropped region as a `CGImage`. Consumers that need a raw image
    /// (e.g. to persist to disk or re-encode) read this directly.
    public let croppedImage: SendableImage

    /// PNG base64 of `croppedImage`. This is what callers feed to
    /// LLM vision APIs — Claude, GPT-4V, etc.
    public let croppedBase64: String

    /// Refs that changed fields (label/value/state/position) between snapshots.
    public let changedRefs: [ElementRef]

    /// Refs present in current but not previous.
    public let addedRefs: [ElementRef]

    /// Refs present in previous but not current.
    public let removedRefs: [ElementRef]

    /// 0–1 confidence score. 1.0 = high-signal diff (every contributing element
    /// had a stable tier), 0.0 = noise-dominated. Computed as
    /// `1 - (noise_elements / total_contributing)` where noise is
    /// stability < 0.5 that the diff picked up only because of the
    /// fallback-tier sweep (i.e. not already in the ChangeDetector output).
    public let confidence: Float

    /// True when the union region would have exceeded `fullScreenThreshold`
    /// of the display area. The crop is then the full image — sending a
    /// cropped "almost-everything" frame is worse than the full frame, since
    /// vision models lose less context.
    public let fullScreenFallback: Bool

    /// Width of `croppedImage` in pixels.
    public let imageWidth: Int

    /// Height of `croppedImage` in pixels.
    public let imageHeight: Int

    public init(
        sessionID: String,
        timestamp: Date,
        changeRegion: CGRect,
        changeRegionDisplayIndex: Int,
        croppedImage: SendableImage,
        croppedBase64: String,
        changedRefs: [ElementRef],
        addedRefs: [ElementRef],
        removedRefs: [ElementRef],
        confidence: Float,
        fullScreenFallback: Bool,
        imageWidth: Int,
        imageHeight: Int
    ) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.changeRegion = changeRegion
        self.changeRegionDisplayIndex = changeRegionDisplayIndex
        self.croppedImage = croppedImage
        self.croppedBase64 = croppedBase64
        self.changedRefs = changedRefs
        self.addedRefs = addedRefs
        self.removedRefs = removedRefs
        self.confidence = confidence
        self.fullScreenFallback = fullScreenFallback
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

// MARK: - Multi-Display Vision Diff

/// Result of `VisionDiffer.diffMultiDisplay` when changes span more than one
/// display. The `primary` diff is the display with the largest changed area;
/// `secondary` holds per-display diffs for the remaining displays, each
/// individually cropped.
public struct MultiDisplayVisionDiff: Sendable {
    public let primary: VisionDiff
    public let secondary: [VisionDiff]

    public init(primary: VisionDiff, secondary: [VisionDiff]) {
        self.primary = primary
        self.secondary = secondary
    }
}

// MARK: - Policy

/// Policy knobs for the vision differ. Default values are tuned for typical
/// 5K Retina displays and Claude's 512-KB-per-image soft limit.
public struct VisionDiffPolicy: Sendable {
    /// Pixels of margin added around the change union. Larger margin gives
    /// the vision model more context but raises payload bytes.
    public var marginPx: CGFloat

    /// Fraction of display area above which we emit the full frame instead
    /// of a near-full crop. Below this, crop wins; above, full frame wins
    /// (vision models get more useful context from an uncropped image).
    public var fullScreenThreshold: CGFloat

    /// Minimum total area (pixels²) for the diff to be emitted. Changes
    /// smaller than this are considered noise and the differ returns nil —
    /// no vision call for a tiny tooltip flicker.
    public var minDiffArea: CGFloat

    /// Maximum base64 byte payload. Crops that encode larger are
    /// down-sampled until they fit. Soft cap — keeps LLM payloads bounded.
    public var maxBase64Bytes: Int

    /// When true, stability-score < 0.5 refs from the current map are folded
    /// into the diff region even if they didn't change. Low-trust refs
    /// deserve visual confirmation.
    public var forceVisionForFallbackTier: Bool

    public init(
        marginPx: CGFloat = 32,
        fullScreenThreshold: CGFloat = 0.7,
        minDiffArea: CGFloat = 100,
        maxBase64Bytes: Int = 512 * 1024,
        forceVisionForFallbackTier: Bool = true
    ) {
        self.marginPx = marginPx
        self.fullScreenThreshold = fullScreenThreshold
        self.minDiffArea = minDiffArea
        self.maxBase64Bytes = maxBase64Bytes
        self.forceVisionForFallbackTier = forceVisionForFallbackTier
    }

    /// Standard policy — balanced defaults.
    public static let `default` = VisionDiffPolicy()

    /// Conservative policy: larger margin + higher fullscreen threshold.
    /// Preserves more context at the cost of payload bytes. Pick this when
    /// token budget is not the bottleneck.
    public static let conservative = VisionDiffPolicy(
        marginPx: 64,
        fullScreenThreshold: 0.8,
        minDiffArea: 50,
        maxBase64Bytes: 1024 * 1024,
        forceVisionForFallbackTier: true
    )

    /// Aggressive policy: tight margin + low fullscreen threshold.
    /// Minimizes payload bytes at the cost of context. Pick this when
    /// every token matters and the vision model can work with small crops.
    public static let aggressive = VisionDiffPolicy(
        marginPx: 8,
        fullScreenThreshold: 0.5,
        minDiffArea: 200,
        maxBase64Bytes: 256 * 1024,
        forceVisionForFallbackTier: false
    )
}

// MARK: - Vision Differ

/// Rank 8 — the cropping + encoding pipeline that turns a pair of
/// `ScreenMap`s + the current full-resolution screenshot into a
/// bytes-efficient `VisionDiff` suitable for an LLM vision API.
///
/// Algorithm:
/// 1. Run `ChangeDetector.diff(previous:current:)` to get added/removed/changed.
/// 2. Collect bounds of every changed ref that lives on a visible display.
/// 3. If `forceVisionForFallbackTier` is on, fold in fallback-tier refs from
///    the current map — their identity is shaky, so visual confirmation
///    is worth the extra region growth.
/// 4. Compute the bounding-box union, inflate by `marginPx`, clamp to image.
/// 5. If the union is too small → return nil (skip the vision call entirely).
/// 6. If the union is too large → emit full frame with `fullScreenFallback = true`.
/// 7. Otherwise crop to the union.
/// 8. Encode to PNG → base64; downsample if the payload exceeds `maxBase64Bytes`.
public enum VisionDiffer {

    // MARK: - Primary entry point

    /// Build a visual diff from two maps + the freshly-captured full-resolution
    /// image. Returns nil when there are no meaningful changes (below
    /// `minDiffArea`) or when the crop fails.
    ///
    /// `currentImage` must be the image of the primary change display. Callers
    /// that cover multiple displays should prefer `diffMultiDisplay`.
    public static func diff(
        previous: ScreenMap,
        current: ScreenMap,
        currentImage: CGImage,
        tiers: [ElementRef: IdentityTier],
        policy: VisionDiffPolicy = .default,
        sessionID: String = "default"
    ) -> VisionDiff? {
        guard let union = unionRegionFull(
            previous: previous,
            current: current,
            tiers: tiers,
            policy: policy
        ) else {
            return nil
        }

        let imageRect = CGRect(x: 0, y: 0, width: currentImage.width, height: currentImage.height)
        let displayArea: CGFloat = {
            // Prefer the display the change lives on. Fall back to the main
            // display, then the image itself.
            if let display = current.displays.first(where: { $0.index == union.displayIndex }) {
                return CGFloat(display.width) * CGFloat(display.height)
            }
            if let main = current.displays.first(where: \.isMain) {
                return CGFloat(main.width) * CGFloat(main.height)
            }
            return CGFloat(currentImage.width * currentImage.height)
        }()

        let rawRegion = union.region
        let rawArea = rawRegion.width * rawRegion.height

        // Skip — changes below the noise floor.
        guard rawArea >= policy.minDiffArea else { return nil }

        // Apply margin + clamp to image bounds.
        let margined = rawRegion
            .insetBy(dx: -policy.marginPx, dy: -policy.marginPx)
            .intersection(imageRect)

        // Guard against degenerate intersections (changes entirely outside the
        // image's pixel bounds — shouldn't happen but protects the encoder).
        guard !margined.isEmpty, margined.width > 0, margined.height > 0 else {
            return nil
        }

        let marginedArea = margined.width * margined.height
        let fullScreenFallback = marginedArea > displayArea * policy.fullScreenThreshold

        let chosenImage: CGImage
        let chosenRegion: CGRect
        if fullScreenFallback {
            chosenImage = currentImage
            chosenRegion = imageRect
        } else {
            guard let cropped = crop(currentImage, to: margined, margin: 0) else {
                return nil
            }
            chosenImage = cropped
            chosenRegion = margined
        }

        // Encode → base64 → fit to maxBase64Bytes.
        guard let (encodedImage, base64) = encodePNGFitting(
            image: chosenImage,
            maxBytes: policy.maxBase64Bytes
        ) else {
            return nil
        }

        // Confidence: fraction of contributing elements that come from the
        // ChangeDetector (signal) vs. the fallback-tier sweep (noise).
        let confidence = computeConfidence(
            changedCount: union.changed.count,
            addedCount: union.added.count,
            removedCount: union.removed.count,
            noiseCount: union.fallbackNoiseCount
        )

        return VisionDiff(
            sessionID: sessionID,
            timestamp: Date(),
            changeRegion: chosenRegion,
            changeRegionDisplayIndex: union.displayIndex,
            croppedImage: SendableImage(encodedImage),
            croppedBase64: base64,
            changedRefs: union.changed,
            addedRefs: union.added,
            removedRefs: union.removed,
            confidence: confidence,
            fullScreenFallback: fullScreenFallback,
            imageWidth: encodedImage.width,
            imageHeight: encodedImage.height
        )
    }

    // MARK: - Multi-display

    /// Build a per-display multi-display diff. Returns nil when no display
    /// has a meaningful change. The `primary` entry is the display with the
    /// largest change area; `secondary` holds the others in descending
    /// area order.
    ///
    /// `currentImagesByDisplay` must key on `DisplayInfo.index`.
    public static func diffMultiDisplay(
        previous: ScreenMap,
        current: ScreenMap,
        currentImagesByDisplay: [Int: CGImage],
        tiers: [ElementRef: IdentityTier],
        policy: VisionDiffPolicy = .default,
        sessionID: String = "default"
    ) -> MultiDisplayVisionDiff? {
        // Build per-display partitioned snapshots so each diff runs only over
        // elements that live on that display — otherwise a bounding-box union
        // across two displays produces a nonsense region.
        let displayIndices = Set(current.displays.map { $0.index })
            .union(previous.displays.map { $0.index })

        var perDisplayDiffs: [(area: CGFloat, diff: VisionDiff)] = []
        for idx in displayIndices {
            guard let image = currentImagesByDisplay[idx] else { continue }
            // Translate bounds from global top-left space into the display's
            // local image pixel space. Each display's captured image has
            // origin (0,0) at the top-left of that display, but AX bounds
            // are in the unified top-left Y-down space across all displays.
            let originOffset = current.displays
                .first(where: { $0.index == idx })?.topLeftOrigin ?? .zero
            let prevSlice = makeSliceForDisplay(
                previous, displayIndex: idx, originOffset: originOffset
            )
            let currSlice = makeSliceForDisplay(
                current, displayIndex: idx, originOffset: originOffset
            )
            guard let diff = diff(
                previous: prevSlice,
                current: currSlice,
                currentImage: image,
                tiers: tiers,
                policy: policy,
                sessionID: sessionID
            ) else { continue }
            let area = diff.changeRegion.width * diff.changeRegion.height
            perDisplayDiffs.append((area: area, diff: diff))
        }

        guard !perDisplayDiffs.isEmpty else { return nil }
        perDisplayDiffs.sort { $0.area > $1.area }

        let primary = perDisplayDiffs.removeFirst().diff
        let secondary = perDisplayDiffs.map { $0.diff }
        return MultiDisplayVisionDiff(primary: primary, secondary: secondary)
    }

    // MARK: - Union computation

    /// Computed bounding-box union — exposed without the cropping/encoding
    /// pass so planners can estimate crop size before committing to a vision
    /// call. Returns nil if neither the ChangeDetector nor the
    /// fallback-tier sweep produced any elements.
    public static func unionRegion(
        previous: ScreenMap,
        current: ScreenMap,
        tiers: [ElementRef: IdentityTier],
        policy: VisionDiffPolicy
    ) -> (region: CGRect, displayIndex: Int, changed: [ElementRef], added: [ElementRef], removed: [ElementRef])? {
        guard let full = unionRegionFull(
            previous: previous,
            current: current,
            tiers: tiers,
            policy: policy
        ) else { return nil }
        return (full.region, full.displayIndex, full.changed, full.added, full.removed)
    }

    /// Internal variant that also carries the noise-count used for confidence
    /// computation. Kept internal so the public surface stays tight.
    static func unionRegionFull(
        previous: ScreenMap,
        current: ScreenMap,
        tiers: [ElementRef: IdentityTier],
        policy: VisionDiffPolicy
    ) -> (region: CGRect, displayIndex: Int, changed: [ElementRef], added: [ElementRef], removed: [ElementRef], fallbackNoiseCount: Int)? {
        let screenDiff = ChangeDetector.diff(previous: previous, current: current)

        // Build lookup of current elements for bounds/display-index resolution.
        let currByRef = Dictionary(
            current.elements.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let prevByRef = Dictionary(
            previous.elements.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let changedRefs = screenDiff.changed.map { $0.ref }
        let addedRefs = screenDiff.added.map { $0.ref }
        let removedRefs = screenDiff.removed.map { $0.ref }

        // Dedup + collect contributing refs that have bounds.
        var seenSignal = Set<ElementRef>()
        var contributingBounds: [(bounds: CGRect, displayIndex: Int)] = []

        func add(ref: ElementRef, element: ScreenElement?) {
            guard let el = element, let b = el.bounds else { return }
            if seenSignal.contains(ref) { return }
            seenSignal.insert(ref)
            contributingBounds.append((bounds: b, displayIndex: el.displayIndex))
        }

        for ref in changedRefs { add(ref: ref, element: currByRef[ref]) }
        for ref in addedRefs { add(ref: ref, element: currByRef[ref]) }
        for ref in removedRefs { add(ref: ref, element: prevByRef[ref]) }

        let signalCount = contributingBounds.count

        // Fold in fallback-tier refs (low-stability) when the policy asks for
        // it. These don't carry change signal — they're folded in so the
        // vision model can confirm them, not because they've moved.
        var fallbackNoiseCount = 0
        if policy.forceVisionForFallbackTier {
            for (ref, tier) in tiers where tier == .fallback {
                if seenSignal.contains(ref) { continue }
                guard let el = currByRef[ref], let b = el.bounds else { continue }
                seenSignal.insert(ref)
                contributingBounds.append((bounds: b, displayIndex: el.displayIndex))
                fallbackNoiseCount += 1
            }
        }

        guard !contributingBounds.isEmpty else { return nil }

        // Pick the dominant display: the one with the most contributing
        // elements. For multi-display scenarios, this anchors the union; the
        // `diffMultiDisplay` wrapper partitions by display before calling us
        // so the union never crosses displays in practice.
        var displayCounts: [Int: Int] = [:]
        for entry in contributingBounds {
            displayCounts[entry.displayIndex, default: 0] += 1
        }
        let dominantDisplay = displayCounts
            .max(by: { $0.value < $1.value })?.key ?? 0

        // Union only the dominant-display contributors. Off-display elements
        // are surfaced as refs in the VisionDiff but don't expand the crop.
        let dominantBounds = contributingBounds
            .filter { $0.displayIndex == dominantDisplay }
            .map { $0.bounds }

        guard let union = dominantBounds.reduce(nil as CGRect?, { acc, r in
            acc.map { $0.union(r) } ?? r
        }) else { return nil }

        _ = signalCount // silence warning in release builds

        return (
            region: union,
            displayIndex: dominantDisplay,
            changed: changedRefs,
            added: addedRefs,
            removed: removedRefs,
            fallbackNoiseCount: fallbackNoiseCount
        )
    }

    // MARK: - Cropping

    /// Crop a CGImage to `region`, optionally expanded by `margin` pixels on
    /// each side. The region is clamped to the image's pixel bounds —
    /// requests that fall partially off the edge are truncated rather than
    /// failing. Returns nil only for degenerate zero-area inputs.
    public static func crop(_ image: CGImage, to region: CGRect, margin: CGFloat) -> CGImage? {
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let expanded = region.insetBy(dx: -margin, dy: -margin)
        let clamped = expanded.intersection(imageRect)
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        // CGImage.cropping expects integer-aligned rects for deterministic
        // pixel counts. Round outward so we don't clip a fractional pixel.
        let aligned = CGRect(
            x: floor(clamped.origin.x),
            y: floor(clamped.origin.y),
            width: ceil(clamped.width),
            height: ceil(clamped.height)
        ).intersection(imageRect)
        guard aligned.width >= 1, aligned.height >= 1 else { return nil }
        return image.cropping(to: aligned)
    }

    // MARK: - Encoding

    /// Encode to PNG, then base64. Downsamples the image in-place when the
    /// resulting base64 would exceed `maxBytes`. Returns the final (possibly
    /// downsampled) `CGImage` plus the base64 payload.
    static func encodePNGFitting(
        image: CGImage,
        maxBytes: Int
    ) -> (image: CGImage, base64: String)? {
        var current = image
        // First attempt at full resolution.
        guard var png = pngData(current) else { return nil }
        var base64 = png.base64EncodedString()
        if base64.utf8.count <= maxBytes {
            return (current, base64)
        }

        // Downsample until we fit or we can't shrink further. Each pass
        // halves the width until we're under the cap; bails out if the
        // image becomes too small to be useful.
        while base64.utf8.count > maxBytes && current.width > 64 && current.height > 64 {
            let newWidth = max(64, current.width / 2)
            let scale = CGFloat(newWidth) / CGFloat(current.width)
            let newHeight = max(64, Int(CGFloat(current.height) * scale))
            guard let resized = downsample(current, toWidth: newWidth, height: newHeight) else {
                return nil
            }
            current = resized
            guard let nextPng = pngData(current) else { return nil }
            png = nextPng
            base64 = png.base64EncodedString()
        }

        return (current, base64)
    }

    /// PNG-encode a `CGImage`. Wraps `NSBitmapImageRep.representation(using:)`
    /// for consistency with `ScreenCapture.toPNGData`.
    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Re-render a CGImage at a new size using a plain `CGContext`. Keeps
    /// the high-interpolation default so cropped regions stay readable for
    /// the vision model after downsampling.
    static func downsample(_ image: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Confidence

    /// Confidence heuristic — see the `VisionDiff.confidence` docstring.
    /// Returns 1.0 when there's no noise, or when every contributor was signal.
    static func computeConfidence(
        changedCount: Int,
        addedCount: Int,
        removedCount: Int,
        noiseCount: Int
    ) -> Float {
        let signalTotal = changedCount + addedCount + removedCount
        let total = signalTotal + noiseCount
        guard total > 0 else { return 1.0 }
        return Float(signalTotal) / Float(total)
    }

    // MARK: - Helpers

    /// Build a shallow ScreenMap slice that only contains elements living on
    /// the given display index, with their bounds translated into that
    /// display's local image pixel space. Reuses every other field from `map`.
    /// Used by `diffMultiDisplay` so each per-display diff crop aligns with
    /// the corresponding local `CGImage`.
    private static func makeSliceForDisplay(
        _ map: ScreenMap,
        displayIndex: Int,
        originOffset: CGPoint
    ) -> ScreenMap {
        let slicedElements = map.elements
            .filter { $0.displayIndex == displayIndex }
            .map { el -> ScreenElement in
                // Translate bounds + clickPoint into display-local space.
                let localBounds = el.bounds.map {
                    CGRect(
                        origin: CGPoint(
                            x: $0.origin.x - originOffset.x,
                            y: $0.origin.y - originOffset.y
                        ),
                        size: $0.size
                    )
                }
                let localClick = el.clickPoint.map {
                    CGPoint(x: $0.x - originOffset.x, y: $0.y - originOffset.y)
                }
                return ScreenElement(
                    ref: el.ref,
                    role: el.role,
                    subrole: el.subrole,
                    label: el.label,
                    value: el.value,
                    bounds: localBounds,
                    clickPoint: localClick,
                    state: el.state,
                    actions: el.actions,
                    parentRef: el.parentRef,
                    depth: el.depth,
                    source: el.source,
                    confidence: el.confidence,
                    appBundleID: el.appBundleID,
                    windowIndex: el.windowIndex,
                    displayIndex: el.displayIndex
                )
            }
        // Also translate the display in the slice to sit at (0,0) so the
        // downstream `diff()` sees a single local display.
        let localDisplays: [DisplayInfo] = map.displays.map { d in
            DisplayInfo(
                id: d.id,
                index: d.index,
                name: d.name,
                origin: d.index == displayIndex ? .zero : d.origin,
                width: d.width,
                height: d.height,
                scale: d.scale,
                isMain: d.isMain
            )
        }
        return ScreenMap(
            timestamp: map.timestamp,
            captureMs: map.captureMs,
            displays: localDisplays,
            focusedApp: map.focusedApp,
            windows: map.windows,
            elements: slicedElements,
            navigation: map.navigation,
            safety: map.safety,
            metadata: map.metadata,
            browserDOM: map.browserDOM,
            menus: map.menus
        )
    }
}
