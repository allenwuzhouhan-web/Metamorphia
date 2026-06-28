import AppKit
import CloudKit
import Foundation
import MetamorphiaRemoteKit
import Security

/// Polls the iCloud private database for `PendingCommand` records written by
/// the iPhone app and runs them on the Mac. Mirrors the lifecycle of
/// `MemoryUsageMonitor` — singleton, `Task.sleep` loop, symmetric
/// `startMonitoring()` / `stopMonitoring()`.
@MainActor
final class RemoteCommandListener {
    static let shared = RemoteCommandListener()

    private let pollInterval: TimeInterval = 30
    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var inFlight: Task<Void, Never>?

    /// Commands older than this are ignored: a stale record that somehow
    /// survived a failed delete must not be replayed long after it was issued.
    private let freshnessWindow: TimeInterval = 5 * 60

    /// Upper bound on records fetched per poll so a backlog can't flood
    /// execution in a single pass.
    private let fetchLimit = 20

    /// Upper bound on commands actually executed per poll pass.
    private let perPollExecutionCap = 10

    /// Bounded set of recently-handled record names, persisted so a delete that
    /// failed (or a record re-surfacing) can't cause the same command to run
    /// twice. Newest names are appended; the oldest are dropped past the cap.
    private var processedRecordNames: [String] = []
    private var processedRecordNameSet: Set<String> = []
    private static let processedHistoryLimit = 200
    private static let processedDefaultsKey = "remoteCommands.processedRecordNames"

    private lazy var container = CKContainer(identifier: CloudKeys.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }

    private init() {
        if let stored = UserDefaults.standard.array(forKey: Self.processedDefaultsKey) as? [String] {
            processedRecordNames = stored
            processedRecordNameSet = Set(stored)
        }
    }

    func startMonitoring() {
        guard pollTask == nil else { return }
        // CKContainer(identifier:) asserts when the app is not signed with a
        // team whose provisioning profile includes the declared iCloud
        // container. Ad-hoc / unsigned builds therefore crash the moment the
        // lazy `container` is touched. Skip the monitor entirely when the
        // iCloud entitlement is absent from the running binary.
        guard Self.hasICloudEntitlement else { return }
        registerSystemObservers()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                do {
                    try await Task.sleep(for: .seconds(self.pollInterval))
                } catch {
                    break
                }
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        inFlight?.cancel()
        inFlight = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.pollOnce() }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.inFlight?.cancel() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.pollOnce() }
        })
    }

    private func pollOnce() async {
        guard await iCloudIsAvailable() else { return }
        do {
            let records = try await fetchPending()
            var executedThisPoll = 0
            for record in records {
                let recordName = record.recordID.recordName

                // (a) Replay protection: never run a command whose record we've
                // already handled, even if a prior delete failed and it
                // re-surfaced. Try to delete it again, then skip.
                if processedRecordNameSet.contains(recordName) {
                    try? await database.deleteRecord(withID: record.recordID)
                    continue
                }

                guard let command = decode(record) else {
                    Logger.log("[RemoteCommands] Dropping unknown record \(recordName)", category: .warning)
                    markProcessed(recordName)
                    try? await database.deleteRecord(withID: record.recordID)
                    continue
                }

                // (b) Freshness: ignore stale records so a record that lingered
                // past a failed delete can't be replayed long after it was sent.
                if let created = record.creationDate,
                   Date().timeIntervalSince(created) > freshnessWindow {
                    Logger.log("[RemoteCommands] Dropping stale record \(recordName)", category: .warning)
                    markProcessed(recordName)
                    try? await database.deleteRecord(withID: record.recordID)
                    continue
                }

                // (c) Per-poll execution cap: stop executing once the cap is hit
                // so a backlog can't flood execution in a single pass. Remaining
                // fresh records are picked up on the next poll.
                guard executedThisPoll < perPollExecutionCap else { break }
                executedThisPoll += 1

                // Mark processed BEFORE running so a crash/delete-failure during
                // execution still can't cause a re-run on the next poll.
                markProcessed(recordName)
                await run(command, recordID: record.recordID)
            }
        } catch {
            Logger.log("[RemoteCommands] Poll failed: \(error.localizedDescription)", category: .error)
        }
    }

    /// Records a handled record name in the bounded, persisted replay-protection
    /// set, evicting the oldest entries past the cap.
    private func markProcessed(_ recordName: String) {
        guard !processedRecordNameSet.contains(recordName) else { return }
        processedRecordNames.append(recordName)
        processedRecordNameSet.insert(recordName)
        while processedRecordNames.count > Self.processedHistoryLimit {
            let evicted = processedRecordNames.removeFirst()
            processedRecordNameSet.remove(evicted)
        }
        UserDefaults.standard.set(processedRecordNames, forKey: Self.processedDefaultsKey)
    }

    private static var hasICloudEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
    }

    private func iCloudIsAvailable() async -> Bool {
        do {
            let status = try await container.accountStatus()
            if status != .available {
                Logger.log("[RemoteCommands] iCloud unavailable (status=\(status.rawValue)); commands queued remotely", category: .warning)
                return false
            }
            return true
        } catch {
            Logger.log("[RemoteCommands] accountStatus failed: \(error.localizedDescription)", category: .error)
            return false
        }
    }

    private func fetchPending() async throws -> [CKRecord] {
        let query = CKQuery(
            recordType: CloudKeys.RecordType.pendingCommand,
            predicate: NSPredicate(value: true)
        )
        query.sortDescriptors = [NSSortDescriptor(key: CloudKeys.Field.createdAt, ascending: true)]
        // (c) Bound the fetch so an attacker-seeded or accidental backlog in the
        // private DB can't pull an unbounded number of records into memory.
        let (matchResults, _) = try await database.records(matching: query, resultsLimit: fetchLimit)
        return matchResults.compactMap { try? $0.1.get() }
    }

    // AUDIT: (d) `CloudKeys.Field.senderID` is written by the iPhone sender but
    // there is no stable, pre-shared expected sender id to validate against on
    // the Mac. Security here rests on CloudKit private-database isolation: only
    // the same iCloud account's devices can write/read these records, so a
    // command can only originate from a device the user already owns. If a
    // stable expected sender is ever established (e.g. a paired-device id), it
    // should be compared against `record[CloudKeys.Field.senderID]` here and
    // mismatches rejected.

    private func decode(_ record: CKRecord) -> Command? {
        guard let kind = record[CloudKeys.Field.kind] as? String else { return nil }
        let payload = record[CloudKeys.Field.payload] as? Data
        return Command.decode(kind: kind, payload: payload)
    }

    private func run(_ command: Command, recordID: CKRecord.ID) async {
        let task = Task { @MainActor in
            self.perform(command)
            Logger.log("[RemoteCommands] Ran \(command.kind) [\(recordID.recordName)]", category: .network)
            do {
                try await self.database.deleteRecord(withID: recordID)
            } catch {
                Logger.log("[RemoteCommands] Delete \(recordID.recordName) failed: \(error.localizedDescription)", category: .error)
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func perform(_ command: Command) {
        switch command {
        case .sleepMac:
            runAppleScript(#"tell application "System Events" to sleep"#)
        case .lockMac:
            runAppleScript(#"tell application "System Events" to key code 12 using {control down, command down}"#)
        case .playMusic:
            MusicManager.shared.play()
        case .pauseMusic:
            MusicManager.shared.pause()
        case .nextTrack:
            MusicManager.shared.nextTrack()
        case .previousTrack:
            MusicManager.shared.previousTrack()
        case .setKeepAwake(let on):
            KeepAwake.shared.setEnabled(on)
        }
    }

    private func runAppleScript(_ source: String) {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            Logger.log("[RemoteCommands] AppleScript failed: \(message)", category: .error)
        }
    }
}
