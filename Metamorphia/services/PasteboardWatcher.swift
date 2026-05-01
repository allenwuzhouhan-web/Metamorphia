/*
 * Metamorphia
 * Pasteboard-change sensor — emits ActivityEvent.clipboardCopied into the
 * activity spine whenever the system pasteboard changes and the content can
 * be classified.
 *
 * Polling strategy:
 *   • 0.5 Hz in normal mode, 0.5 s interval.
 *   • 2.0 s interval when Low Power Mode is active (NSProcessInfo).
 *   • Timer is recreated on NSProcessInfoPowerStateDidChange so the interval
 *     adjusts without restarting the watcher.
 *
 * Privacy invariants (load-bearing — do not relax):
 *   - Clipboard content is never logged, stored, or emitted.
 *   - Only kind (text/url/image/file/other) + byte count + origin are recorded.
 *   - Password-manager apps are detected by bundle ID; their output is
 *     classified as (.other, 0, .denylist) — no byte count.
 *   - Items with the ConcealedType UTI are emitted as (.other, 0, .concealed).
 *   - Items with the TransientType UTI are silently dropped (no event).
 *
 * Feature gate: Defaults[.observePasteboard] (default false). When the gate is
 * off, tick() is a no-op but the timer keeps running so the watcher can resume
 * immediately when the gate is re-enabled without a restart.
 */

import AppKit
import Defaults
import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception
import os

// MARK: - PasteboardReadable

/// Protocol abstracting NSPasteboard so tests can inject a fake pasteboard
/// without triggering macOS Sonoma paste-access alerts.
public protocol PasteboardReadable: AnyObject {
    var changeCount: Int { get }
    var pasteboardTypes: [NSPasteboard.PasteboardType]? { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: PasteboardReadable {
    public var pasteboardTypes: [NSPasteboard.PasteboardType]? { self.types }
}

// MARK: - Defaults key

extension Defaults.Keys {
    /// Master switch for pasteboard observation. Default false — user opts in.
    public static let observePasteboard = Key<Bool>(
        "metamorphia.sensor.pasteboard.enabled",
        default: false
    )
}

// MARK: - PasteboardWatcher

@MainActor
public final class PasteboardWatcher {

    // MARK: - Dependencies

    private let stream: ActivityStream
    private let pasteboard: PasteboardReadable
    private let clock: () -> Date

    // MARK: - State

    private var lastChangeCount: Int
    private var timer: Timer?
    private var lowPowerObserver: NSObjectProtocol?
    private var running = false

    // MARK: - Logging

    private let logger = os.Logger(subsystem: "com.metamorphia", category: "PasteboardWatcher")

    // MARK: - Password-manager denylist

    /// Bundle IDs whose clipboard output is suppressed to (.other, 0, .denylist).
    public static let passwordManagerDenylist: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.apple.Passwords",
        "me.proton.pass",
        "com.dashlane.dashlane-mac",
        "org.keepassxc.keepassxc",
    ]

    // MARK: - Init

    public init(
        stream: ActivityStream,
        pasteboard: PasteboardReadable = NSPasteboard.general,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.stream = stream
        self.pasteboard = pasteboard
        self.clock = clock
        self.lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        guard Defaults[.observePasteboard] else { return }
        running = true
        scheduleTimer()

        // Restart timer with updated interval whenever Low Power Mode toggles.
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.running else { return }
                self.timer?.invalidate()
                self.scheduleTimer()
            }
        }
    }

    public func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        if let observer = lowPowerObserver {
            NotificationCenter.default.removeObserver(observer)
            lowPowerObserver = nil
        }
    }

    // MARK: - Test seam

    /// Synchronously invoke one tick cycle. Intended for unit tests that cannot
    /// wait for a real timer to fire.
    public func tickNow() { tick() }

    // MARK: - Internal

    private func scheduleTimer() {
        let interval = pollInterval()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        // Re-check gate on every tick so live toggling takes effect without
        // restarting the watcher. running flag is intentionally not cleared —
        // the timer keeps running so we resume immediately when re-enabled.
        guard Defaults[.observePasteboard] else { return }

        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard let (kind, bytes, origin) = classify() else { return }

        let when = clock()
        let bid = currentFrontmostBundleID()
        let candidate = PrivacyFirewall.Candidate(
            bundleID: bid,
            kind: "clipboardCopied",
            at: when
        )
        Task { [stream] in
            let (_, drop) = await PrivacyFirewall.shared.admit(lane: "clipboardWatch", candidate)
            guard case .ok = drop else { return }
            await stream.emit(.clipboardCopied(kind: kind, byteCount: bytes, origin: origin, at: when))
        }
        logger.info("clipboard kind=\(kind.rawValue) bytes=\(bytes) origin=\(origin.rawValue)")
    }

    private func pollInterval() -> TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 2.0 : 0.5
    }

    // MARK: - Classification

    /// Inspect the current pasteboard contents and return (kind, byteCount, origin),
    /// or nil if the item is unclassifiable (TransientType or unknown type).
    private func classify() -> (ClipboardKind, Int, PasteOrigin)? {
        guard let types = pasteboard.pasteboardTypes else { return nil }

        // Transient items (e.g. drag-and-drop intermediates) are silently dropped.
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) {
            return nil
        }

        // Password manager / concealed items — emit shape only, zero bytes.
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) {
            return (.other, 0, .concealed)
        }

        // Universal Clipboard (Handoff) — item arrived from another Apple device.
        if types.contains(NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")) {
            let bytes = pasteboard.data(
                forType: NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
            )?.count ?? 0
            // Classify kind from remaining types.
            let kind = coarseKind(from: types)
            return (kind, bytes, .remote)
        }

        // Password-manager frontmost app — suppress content, zero bytes.
        if let bundleID = currentFrontmostBundleID(),
           Self.passwordManagerDenylist.contains(bundleID) {
            return (.other, 0, .denylist)
        }

        // Normal local classification — one data read.
        if types.contains(.string) {
            if let str = pasteboard.string(forType: .string) {
                let bytes = str.utf8.count
                // Treat URL-shaped strings as .url kind.
                if str.hasPrefix("http://") || str.hasPrefix("https://") {
                    return (.url, bytes, .local)
                }
                return (.text, bytes, .local)
            }
        }

        if types.contains(.fileURL) {
            return (.file, 0, .local)
        }

        // Image types: PNG, TIFF, and other public image UTIs.
        let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
        ]
        for imageType in imagePasteboardTypes {
            if types.contains(imageType) {
                let bytes = pasteboard.data(forType: imageType)?.count ?? 0
                return (.image, bytes, .local)
            }
        }

        if types.contains(.URL) {
            return (.url, 0, .local)
        }

        // Unclassifiable — don't emit.
        return nil
    }

    /// Coarse kind for Universal Clipboard items where we can't inspect full content.
    private func coarseKind(from types: [NSPasteboard.PasteboardType]) -> ClipboardKind {
        if types.contains(.string) { return .text }
        if types.contains(.fileURL) { return .file }
        if types.contains(.png) || types.contains(.tiff) { return .image }
        if types.contains(.URL) { return .url }
        return .other
    }

    private func currentFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
