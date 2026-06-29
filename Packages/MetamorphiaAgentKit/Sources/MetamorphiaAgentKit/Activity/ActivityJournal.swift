import Foundation
import CryptoKit

// MARK: - ActivityJournal

/// Disk-backed encrypted ledger for ``ActivityEvent`` values.
///
/// Design:
/// - Serialises the day's full event list on each flush (rewrite-in-full, never
///   append-in-place to a sealed ciphertext).
/// - Debounced writes: mutations accumulate in memory for up to 4 s before a
///   flush is triggered, preventing per-event I/O.
/// - Daily rotation: events are grouped by the calendar day of their timestamp.
///   On the first event whose day differs from the current write target the
///   previous day is flushed and a new file is opened.
/// - Atomic writes: payload is written to `.tmp`, fsync'd, then renamed.
/// - Retention: files older than 7 days are deleted on startup and on each
///   rotation.
/// - Size cap: if today's file would exceed 100 MB the event is dropped and a
///   single warning is logged (prevents pathological storms).
/// - Encryption: each file is a 4-byte LE length prefix followed by a
///   ChaChaPoly sealed blob of JSON-encoded `[ActivityEvent]`.  When
///   `SecurePersistence` is unavailable the file is written as plain JSON with a
///   `.json` extension.
public final class ActivityJournal: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = ActivityJournal()

    // MARK: - Tunables (overridable for tests)

    /// Maximum size in bytes for a single day's journal file before writes are
    /// halted.  Default 100 MB.
    public var dailySizeCap: Int = 100 * 1_024 * 1_024

    /// How many days of files to retain.
    public var retentionDays: Int = 7

    // MARK: - Private state

    private let queue = DispatchQueue(label: "ActivityJournal.state", qos: .utility)
    private let writeQueue = DispatchQueue(label: "ActivityJournal.write", qos: .utility)

    private var gate: ActivityStreamGate = AlwaysOnGate()
    private var securePersistence: SecurePersistence?

    /// Events collected since the last flush, grouped by ISO-date key.
    private var buffer: [String: [ActivityEvent]] = [:]

    /// The ISO date string we are currently writing to (YYYY-MM-DD).
    private var currentDateKey: String = ""

    /// Set to `true` when the day's file has already hit the size cap.
    private var sizeCapped: Bool = false
    private var sizeCappedLogged: Bool = false

    /// Whether the encryption-unavailable warning has been emitted once.
    private var encryptionWarningLogged: Bool = false

    /// Debounced write bookkeeping.
    private var pendingWrite: DispatchWorkItem?
    private static let writeDebounce: TimeInterval = 4.0

    /// Counter exposed for tests to detect flush count without inspecting file
    /// modification timestamps.
    internal private(set) var flushCount: Int = 0

    /// Base directory for all journal files.
    private let baseDirectory: URL

    // MARK: - Init

    /// Designated initialiser.  Tests pass `directoryOverride` to isolate I/O.
    public init(directoryOverride: URL? = nil) {
        if let override = directoryOverride {
            self.baseDirectory = override
        } else {
            self.baseDirectory = URL.applicationSupportDirectory
                .appendingPathComponent("Metamorphia", isDirectory: true)
                .appendingPathComponent("activity-journal", isDirectory: true)
        }
    }

    // MARK: - Lifecycle

    /// Wire the journal into an ``ActivityStream`` with encrypted storage.
    ///
    /// This is the ergonomic default. `persistence` is required; call
    /// ``startInsecure(stream:gate:)`` only when the Keychain is unavailable.
    ///
    /// - Parameters:
    ///   - stream: The shared stream whose events this journal should persist.
    ///   - persistence: A `SecurePersistence` for encrypted storage.
    ///   - gate: Optional gate that can pause recording without unsubscribing.
    public func start(
        stream: ActivityStreamWritable,
        persistence: SecurePersistence,
        gate: ActivityStreamGate = AlwaysOnGate()
    ) {
        _start(stream: stream, persistence: persistence, gate: gate)
    }

    /// Wire the journal into an ``ActivityStream`` without encryption.
    ///
    /// **Privacy tradeoff:** events are written as plain JSON on disk. Use this
    /// path only when the Keychain is genuinely unavailable (e.g. in unit tests
    /// or sandboxed environments without entitlements). In all other cases prefer
    /// ``start(stream:persistence:gate:)``.
    ///
    /// - Parameters:
    ///   - stream: The shared stream whose events this journal should persist.
    ///   - gate: Optional gate that can pause recording without unsubscribing.
    public func startInsecure(
        stream: ActivityStreamWritable,
        gate: ActivityStreamGate = AlwaysOnGate()
    ) {
        _start(stream: stream, persistence: nil, gate: gate)
    }

    // MARK: - Private lifecycle

    private func _start(
        stream: ActivityStreamWritable,
        persistence: SecurePersistence?,
        gate: ActivityStreamGate
    ) {
        queue.sync {
            self.securePersistence = persistence
            self.gate = gate
        }
        loadExistingFilesFromDisk()
        stream.attachWriter { [weak self] event in
            self?.record(event)
        }
    }

    // MARK: - Record

    /// Append `event` to the in-memory buffer and schedule a debounced flush.
    ///
    /// Thread-safe; may be called from any queue.
    public func record(_ event: ActivityEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.gate.isEnabled else { return }

            let dayKey = Self.isoDateKey(for: event.timestamp)

            // Rotation: if the event belongs to a different day than the current
            // write target, flush the previous day first.
            if !self.currentDateKey.isEmpty && dayKey != self.currentDateKey {
                self.flushDayImmediate(dateKey: self.currentDateKey)
                self.pruneOldFiles()
                self.sizeCapped = false
                self.sizeCappedLogged = false
                self.currentDateKey = dayKey
            } else if self.currentDateKey.isEmpty {
                self.currentDateKey = dayKey
            }

            // Size cap guard: skip appending once cap is hit for the day.
            if self.sizeCapped {
                return
            }

            self.buffer[dayKey, default: []].append(event)
            self.scheduleWrite()
        }
    }

    // MARK: - Query

    /// Return all events recorded for `day` (reads from disk; decrypts if needed).
    ///
    /// This method blocks its caller until the read completes.  Call from a
    /// background thread or async context.
    public func events(on day: Date) -> [ActivityEvent] {
        let key = Self.isoDateKey(for: day)
        // If there are unflushed events in the buffer for this day, include them.
        var buffered: [ActivityEvent] = []
        queue.sync {
            buffered = self.buffer[key] ?? []
        }
        let fromDisk = readEvents(dateKey: key)
        // Merge: disk is the persisted baseline; buffer may have newer events
        // that are not yet on disk.  De-duplicate by using Set would lose order,
        // so we combine: disk first, then append buffered events not already
        // present on disk (by Hashable identity).
        let diskSet = Set(fromDisk)
        let newFromBuffer = buffered.filter { !diskSet.contains($0) }
        return fromDisk + newFromBuffer
    }

    // MARK: - Test hooks

    /// Force an immediate synchronous flush of all buffered days.  For use in
    /// tests only.
    @discardableResult
    internal func forceFlushSync() -> Int {
        var keys: [String] = []
        queue.sync { keys = Array(self.buffer.keys) }
        for key in keys {
            queue.sync { self.flushDayImmediate(dateKey: key) }
        }
        return flushCount
    }

    /// Returns all events currently persisted across the retained day files.
    ///
    /// For test verification only. Reads (and decrypts) on demand so the
    /// fully-decoded set is released after the call rather than held resident.
    public func replayedEvents() -> [ActivityEvent] {
        queue.sync { allExistingDayFiles().flatMap { readEvents(dateKey: $0) } }
    }

    // MARK: - Private: Scheduling

    private func scheduleWrite() {
        // Must be called from within `queue`.
        pendingWrite?.cancel()
        let keys = Array(buffer.keys)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for key in keys {
                self.queue.sync { self.flushDayImmediate(dateKey: key) }
            }
        }
        pendingWrite = work
        writeQueue.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }

    // MARK: - Private: Flush

    /// Flush a single day's buffer to disk synchronously.
    ///
    /// Must be called from within `queue`.
    private func flushDayImmediate(dateKey: String) {
        guard let events = buffer[dateKey], !events.isEmpty else { return }

        // Merge with any data already on disk for partial days (e.g. the
        // journal was restarted mid-day).
        let existing = readEvents(dateKey: dateKey)
        let existingSet = Set(existing)
        let merged = existing + events.filter { !existingSet.contains($0) }

        let result = writeDayToDisk(events: merged, dateKey: dateKey)
        switch result {
        case .success:
            buffer[dateKey] = nil
            flushCount += 1
        case .failure(let err):
            print("[ActivityJournal] flush failed for \(dateKey): \(err)")
        }
    }

    // MARK: - Private: Disk I/O

    /// Write `events` for `dateKey` to disk atomically (.tmp → rename).
    @discardableResult
    private func writeDayToDisk(events: [ActivityEvent], dateKey: String) -> Result<Void, Error> {
        do {
            try FileManager.default.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true
            )

            let jsonData = try JSONEncoder().encode(events)

            // Size cap check.
            if jsonData.count > dailySizeCap {
                if !sizeCappedLogged {
                    print("[ActivityJournal] WARNING: daily size cap (\(dailySizeCap) bytes) reached for \(dateKey). Further events dropped.")
                    sizeCappedLogged = true
                    sizeCapped = true
                }
                return .success(())
            }

            let payload: Data
            if let sp = securePersistence {
                let sealed = try sp.encrypt(jsonData)
                var lengthBytes = Data(count: 4)
                let length = UInt32(sealed.count)
                lengthBytes[0] = UInt8(length & 0xFF)
                lengthBytes[1] = UInt8((length >> 8) & 0xFF)
                lengthBytes[2] = UInt8((length >> 16) & 0xFF)
                lengthBytes[3] = UInt8((length >> 24) & 0xFF)
                payload = lengthBytes + sealed
            } else {
                if !encryptionWarningLogged {
                    print("[ActivityJournal] encryption unavailable; writing plain JSON")
                    encryptionWarningLogged = true
                }
                payload = jsonData
            }

            let finalURL = fileURL(for: dateKey)
            let tmpURL = finalURL.deletingPathExtension()
                .appendingPathExtension(finalURL.pathExtension + ".tmp")

            // Write to tmp via a single handle: create → write → fsync → close.
            // `createFile(atPath:contents:)` is non-throwing and returns whether
            // the file was created. A false return means we couldn't create the
            // tmp file (disk full, permission denied, invalid path), and the
            // subsequent `FileHandle(forWritingTo:)` would fail with a less
            // actionable error — check the flag directly.
            guard FileManager.default.createFile(atPath: tmpURL.path, contents: nil) else {
                return .failure(NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: "could not create tmp file at \(tmpURL.path)"]
                ))
            }
            let handle = try FileHandle(forWritingTo: tmpURL)
            try handle.write(contentsOf: payload)
            try handle.synchronize()
            try handle.close()

            // Atomic rename.
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)

            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Read and decrypt (or plain-decode) events for `dateKey` from disk.
    private func readEvents(dateKey: String) -> [ActivityEvent] {
        let url = fileURL(for: dateKey)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }

        if securePersistence != nil {
            // Format: [4-byte LE length][sealed bytes]
            guard data.count >= 4 else { return [] }
            let length = Int(data[0]) | (Int(data[1]) << 8) | (Int(data[2]) << 16) | (Int(data[3]) << 24)
            guard data.count >= 4 + length else { return [] }
            let sealed = data[4..<(4 + length)]
            guard let sp = securePersistence,
                  let plain = try? sp.decrypt(sealed),
                  let events = try? JSONDecoder().decode([ActivityEvent].self, from: plain)
            else { return [] }
            return events
        } else {
            return (try? JSONDecoder().decode([ActivityEvent].self, from: data)) ?? []
        }
    }

    // MARK: - Private: Startup

    private func loadExistingFilesFromDisk() {
        // Discard any leftover .tmp files.
        discardOrphanedTmps()
        // Prune old files.
        pruneOldFiles()
        // Day files are intentionally not decoded into memory here: the only
        // consumer is the test-only `replayedEvents()` hook, which reads them on
        // demand. Materialising up to `retentionDays` of decoded events into a
        // long-lived buffer would leave that decode resident for the whole
        // process lifetime for no production benefit.
    }

    private func discardOrphanedTmps() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.pathExtension == "tmp" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func pruneOldFiles() {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: Date()
        ) ?? Date()
        let cutoffKey = Self.isoDateKey(for: cutoff)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil
        ) else { return }

        var pruned = 0
        for url in contents {
            let key = dayKey(from: url)
            guard let key else { continue }
            if key < cutoffKey {
                try? FileManager.default.removeItem(at: url)
                pruned += 1
            }
        }
        if pruned > 0 {
            print("[ActivityJournal] pruned \(pruned) file(s) older than \(retentionDays) days")
        }
    }

    /// Returns all existing day-file date keys (YYYY-MM-DD) sorted ascending.
    private func allExistingDayFiles() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.compactMap { dayKey(from: $0) }.sorted()
    }

    // MARK: - Private: URL helpers

    private func fileURL(for dateKey: String) -> URL {
        let ext = securePersistence != nil ? "enc" : "json"
        return baseDirectory.appendingPathComponent("activity-\(dateKey).\(ext)")
    }

    /// Extract the YYYY-MM-DD key from a journal file URL, or nil if unrecognised.
    private func dayKey(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("activity-") else { return nil }
        let key = String(name.dropFirst("activity-".count))
        // Validate rough ISO-date shape (10 chars, YYYY-MM-DD).
        guard key.count == 10 else { return nil }
        return key
    }

    /// Format a `Date` as `YYYY-MM-DD` using the current locale calendar.
    private static func isoDateKey(for date: Date) -> String {
        let cal = Calendar.current
        let year  = cal.component(.year,  from: date)
        let month = cal.component(.month, from: date)
        let day   = cal.component(.day,   from: date)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

// MARK: - ActivityStreamWritable

/// The subset of ``ActivityStream``'s API that ``ActivityJournal`` depends on.
///
/// Defined here so the journal can be compiled and tested before Coder A's
/// ``ActivityStream`` actor is merged.  ``ActivityStream`` must conform to this
/// protocol (a one-line retroactive conformance is sufficient).
public protocol ActivityStreamWritable {
    nonisolated func attachWriter(_ writer: @Sendable @escaping (ActivityEvent) -> Void)
}
