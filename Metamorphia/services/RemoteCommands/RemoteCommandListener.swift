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

    private lazy var container = CKContainer(identifier: CloudKeys.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }

    func startMonitoring() {
        guard pollTask == nil else { return }
        // CKContainer(identifier:) asserts when the app is not signed with a
        // team whose provisioning profile includes the declared iCloud
        // container. Ad-hoc / unsigned builds therefore crash the moment the
        // lazy `container` is touched. Skip the monitor entirely when the
        // iCloud entitlement is absent from the running binary.
        guard Self.hasICloudEntitlement else { return }
        registerSystemObservers()
        // M9: register a CKQuerySubscription so iCloud pushes a silent
        // notification the instant the phone writes a PendingCommand — superseding
        // the 30s poll for latency. The poll loop below is kept as the fallback
        // for when push is unavailable (no APNs token, Low Power Mode, background
        // throttling). Push delivery requires the host to call
        // NSApplication.shared.registerForRemoteNotifications() at launch.
        Task { [weak self] in await self?.registerPushSubscription() }
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
            for record in records {
                guard let command = decode(record) else {
                    Logger.log("[RemoteCommands] Dropping unknown record \(record.recordID.recordName)", category: .warning)
                    try? await database.deleteRecord(withID: record.recordID)
                    continue
                }
                await run(command, recordID: record.recordID)
            }
        } catch {
            Logger.log("[RemoteCommands] Poll failed: \(error.localizedDescription)", category: .error)
        }
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
        let (matchResults, _) = try await database.records(matching: query)
        return matchResults.compactMap { try? $0.1.get() }
    }

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
        case .askAgent(let prompt, let sessionID):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let text = await MetamorphiaIntentEngine.run(
                    prompt: prompt,
                    systemPrompt: MetamorphiaIntentEngine.defaultSystemPrompt,
                    sessionID: sessionID,
                    showNotch: true
                )
                await self.writeTurnResult(
                    TurnResult(
                        sessionID: sessionID,
                        text: text,
                        status: "complete",
                        updatedAt: Date()
                    )
                )
            }
        }
    }

    /// M9: throttled interim write during streaming. Same record type as the
    /// final result but with status "streaming" and a fresh `updatedAt` so the
    /// phone's "newest by updatedAt" sort surfaces the latest partial. The caller
    /// (AICommandViewModel progress sink) is responsible for the ~1/sec throttle.
    /// Push is best-effort; the 30s Mac poll + 1s phone poll are the guaranteed
    /// delivery paths — these writes are additive only.
    func writeInterimTurnResult(sessionID: String, text: String) async {
        await writeTurnResult(
            TurnResult(sessionID: sessionID, text: text, status: "streaming", updatedAt: Date())
        )
    }

    /// M9: public entry point so the app's push notification handler can
    /// trigger an immediate poll when APNs delivers a silent push for a
    /// PendingCommand CKQuerySubscription event. The 30s loop runs regardless
    /// as the guaranteed fallback; this only shortens latency.
    /// NOTE: for silent pushes to arrive, the Mac host must call
    /// NSApplication.shared.registerForRemoteNotifications() at launch.
    func handleRemotePush() async { await pollOnce() }

    private func writeTurnResult(_ result: TurnResult) async {
        let record = CKRecord(recordType: CloudKeys.RecordType.turnResult)
        record[CloudKeys.Field.sessionID] = result.sessionID as CKRecordValue
        record[CloudKeys.Field.text]      = result.text      as CKRecordValue
        record[CloudKeys.Field.status]    = result.status    as CKRecordValue
        record[CloudKeys.Field.updatedAt] = result.updatedAt as CKRecordValue
        do {
            try await database.save(record)
            Logger.log("[RemoteCommands] Wrote TurnResult for session \(result.sessionID)", category: .network)
        } catch {
            Logger.log("[RemoteCommands] TurnResult write failed: \(error.localizedDescription)", category: .error)
        }
    }

    /// M9: register a CKQuerySubscription on PendingCommand so iCloud pushes a
    /// silent notification the moment the phone writes a command — superseding
    /// the 30s poll for latency. The poll loop is deliberately kept running as
    /// a fallback for when push is unavailable (no APNs token, Low Power Mode,
    /// background throttling). `hasICloudEntitlement` is already guarded by the
    /// caller. CKQuerySubscription save is idempotent per subscriptionID, so a
    /// re-run on relaunch is a cheap no-op server-side.
    private func registerPushSubscription() async {
        guard await iCloudIsAvailable() else { return }
        let subscriptionID = "pending-command-sub"
        let subscription = CKQuerySubscription(
            recordType: CloudKeys.RecordType.pendingCommand,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push; we re-poll on wake
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
            Logger.log("[RemoteCommands] Push subscription registered", category: .network)
        } catch let ckErr as CKError where ckErr.code == .serverRejectedRequest {
            // Already exists from a prior launch — fine.
        } catch {
            Logger.log("[RemoteCommands] Subscription register failed (poll still active): \(error.localizedDescription)", category: .warning)
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
