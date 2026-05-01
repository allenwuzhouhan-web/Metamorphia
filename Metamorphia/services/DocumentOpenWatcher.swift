/*
 * Metamorphia
 * Document-open sensor — emits ActivityEvent.documentOpened into the activity
 * spine whenever a file is created or renamed into a watched directory.
 *
 * Signal sources:
 *  1. FSEvents on ~/Downloads, ~/Documents, ~/Desktop — delivers fast, low-
 *     overhead notifications for file creation and rename events.
 *  2. A 60-second NSDocumentController poll — catches files opened via the
 *     macOS Open Recent mechanism that may not generate FSEvents.
 *
 * Depth filter: events more than 2 path components below a watched root are
 * dropped to avoid deep traversal noise.
 *
 * Coalescing: repeated events for the same path within 0.5 s are collapsed to
 * one emission, covering atomic-save patterns (tmp → final rename pair).
 *
 * Privacy invariants (load-bearing — do not relax):
 *  - The file path is never logged, stored, or emitted.
 *  - Only the file extension, a coarse size bucket, and the opener bundle ID
 *    are recorded.
 *
 * Feature gate: Defaults[.observeDocumentOpen] (default false). When false,
 * start() is a no-op and no FSEvents stream is opened.
 */

import AppKit
import CoreServices
import Defaults
import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception
import os

// MARK: - Defaults key

extension Defaults.Keys {
    /// Master switch for document-open observation. Default false — user opts in.
    public static let observeDocumentOpen = Key<Bool>(
        "metamorphia.sensor.documentOpen.enabled",
        default: false
    )
}

// MARK: - DocumentOpenWatcher

@MainActor
public final class DocumentOpenWatcher {

    // MARK: - Dependencies

    private let stream: ActivityStream

    // MARK: - FSEvents state

    private var fsStream: FSEventStreamRef?

    // MARK: - LS poll task

    private var lsPollTask: Task<Void, Never>?

    // MARK: - Coalescing

    /// Last-seen timestamp per path. Paths repeated within `coalesceWindow` seconds
    /// are dropped to one emission.
    private var coalesce: [String: Date] = [:]
    private let coalesceWindow: TimeInterval = 0.5

    // MARK: - Watched roots

    let watchedRoots: [URL]

    // MARK: - Recent-document diffing

    private var lastKnownRecents: Set<String> = []

    // MARK: - Lifecycle guard

    private var running = false

    // MARK: - Logging

    private let logger = os.Logger(subsystem: "com.metamorphia", category: "DocumentOpenWatcher")

    // MARK: - Init

    public init(stream: ActivityStream) {
        self.stream = stream
        let home = FileManager.default.homeDirectoryForCurrentUser
        watchedRoots = [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Desktop"),
        ]
    }

    // MARK: - Lifecycle

    public func start() {
        guard Defaults[.observeDocumentOpen] else { return }
        guard !running else { return }
        running = true

        startFSEvents()
        startLSPoll()
    }

    public func stop() {
        guard running else { return }
        running = false

        if let stream = fsStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsStream = nil
        }

        lsPollTask?.cancel()
        lsPollTask = nil
    }

    // MARK: - Test seam

    /// Inject a synthetic FSEvent path without touching real FSEvents. Lets tests
    /// exercise coalescing and depth-filter logic directly.
    public func injectEvent(path: String, at date: Date = Date()) {
        processPath(path, at: date)
    }

    // MARK: - FSEvents setup

    private func startFSEvents() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagIgnoreSelf |
            kFSEventStreamCreateFlagNoDefer
        )

        let paths = watchedRoots.map { $0.path } as CFArray

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, count, pathsPtr, eventFlags, _ in
                guard let info else { return }
                let me = Unmanaged<DocumentOpenWatcher>.fromOpaque(info).takeUnretainedValue()
                let ps = unsafeBitCast(pathsPtr, to: NSArray.self) as! [String]
                let flagsBuffer = eventFlags
                MainActor.assumeIsolated {
                    for i in 0..<count {
                        let path = ps[i]
                        let f = flagsBuffer.advanced(by: i).pointee
                        // Skip directory events.
                        if f & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }
                        // Only care about created or renamed items.
                        if f & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) == 0 { continue }
                        me.processPath(path, at: Date())
                    }
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        fsStream = stream
    }

    // MARK: - Path processing

    private func processPath(_ path: String, at date: Date) {
        // Depth filter: reject paths more than 2 components below a watched root.
        guard let root = watchedRoots.first(where: { path.hasPrefix($0.path) }) else { return }
        let relative = String(path.dropFirst(root.path.count + 1))
        let componentCount = relative.split(separator: "/", omittingEmptySubsequences: true).count
        guard componentCount <= 2 else { return }

        // Coalescing: same path within the window → drop.
        if let last = coalesce[path], date.timeIntervalSince(last) < coalesceWindow { return }
        coalesce[path] = date

        // Evict stale coalesce entries if the map grows large.
        if coalesce.count > 200 {
            let cutoff = date.addingTimeInterval(-60)
            coalesce = coalesce.filter { $0.value > cutoff }
        }

        // Extension filter.
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 8 else { return }

        // File size — best-effort; 0 on failure.
        let size: Int64 = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0

        // Opener bundle ID — best-effort. NSWorkspace returns the app's URL;
        // we read the bundle to recover the identifier.
        let bundleID: String? = {
            guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
            return Bundle(url: appURL)?.bundleIdentifier
        }()

        emit(bundleID: bundleID, ext: ext, size: size, at: date)
    }

    // MARK: - Emission

    private func emit(bundleID: String?, ext: String, size: Int64, at date: Date) {
        let bucket = DocSizeBucket.classify(bytes: size)
        let candidate = PrivacyFirewall.Candidate(
            bundleID: bundleID,
            kind: "documentOpened",
            at: date
        )
        Task { [stream] in
            let (_, drop) = await PrivacyFirewall.shared.admit(lane: "documentWatch", candidate)
            guard case .ok = drop else { return }
            await stream.emit(.documentOpened(bundleID: bundleID, fileExtension: ext, sizeBucket: bucket, at: date))
        }
        logger.info("documentOpened ext=\(ext) bucket=\(bucket.rawValue) bundle=\(bundleID ?? "?")")
    }

    // MARK: - LS poll

    private func startLSPoll() {
        lsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in self?.pollRecentDocuments() }
            }
        }
    }

    private func pollRecentDocuments() {
        let recents = NSDocumentController.shared.recentDocumentURLs
        let watchedPaths = Set(watchedRoots.map { $0.path })

        var newPaths: [String] = []
        for url in recents {
            let path = url.path
            guard watchedRoots.contains(where: { path.hasPrefix($0.path) }) else { continue }
            if !lastKnownRecents.contains(path) {
                newPaths.append(path)
            }
        }
        lastKnownRecents = Set(recents.map { $0.path })
        _ = watchedPaths

        for path in newPaths {
            processPath(path, at: Date())
        }
    }
}
