import CloudKit
import Foundation
import MetamorphiaRemoteKit
import UIKit

/// Writes one `PendingCommand` record to the user's private CloudKit database.
/// The Mac listener polls that database, runs the command, then deletes the
/// record. No result writeback in v1 — the iPhone trusts the send.
@MainActor
final class CommandSender {
    static let shared = CommandSender()

    private lazy var container = CKContainer(identifier: CloudKeys.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }

    func send(_ command: Command) async throws {
        let record = CKRecord(recordType: CloudKeys.RecordType.pendingCommand)
        record[CloudKeys.Field.kind] = command.kind
        if let payload = command.payload {
            record[CloudKeys.Field.payload] = payload
        }
        record[CloudKeys.Field.createdAt] = Date()
        record[CloudKeys.Field.senderID] = senderID
        _ = try await database.save(record)
    }

    func iCloudIsAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    /// M9: fetch the latest TurnResult for a session. Returns the newest record
    /// by `updatedAt` — interim "streaming" writes arrive first then the final
    /// "complete" write. The phone's poll loop calls this every ~1s until it
    /// sees status "complete" or times out after ~2 min.
    func latestTurnResult(for sessionID: String) async throws -> TurnResult? {
        let predicate = NSPredicate(format: "%K == %@", CloudKeys.Field.sessionID, sessionID)
        let query = CKQuery(recordType: CloudKeys.RecordType.turnResult, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CloudKeys.Field.updatedAt, ascending: false)]
        let (matches, _) = try await database.records(matching: query, resultsLimit: 1)
        guard let record = matches.compactMap({ try? $0.1.get() }).first else { return nil }
        return TurnResult(
            sessionID: record[CloudKeys.Field.sessionID] as? String ?? sessionID,
            text:      record[CloudKeys.Field.text]      as? String ?? "",
            status:    record[CloudKeys.Field.status]    as? String ?? "",
            updatedAt: record[CloudKeys.Field.updatedAt] as? Date   ?? Date()
        )
    }

    /// M9: register a CKQuerySubscription so iCloud pushes when the Mac writes a
    /// TurnResult. Idempotent per subscriptionID. APNs delivery requires the app
    /// to call UIApplication.shared.registerForRemoteNotifications() — HomeView
    /// falls back to a 1s poll loop when push isn't delivered in time.
    func registerTurnResultSubscription() async {
        guard await iCloudIsAvailable() else { return }
        let subscription = CKQuerySubscription(
            recordType: CloudKeys.RecordType.turnResult,
            predicate: NSPredicate(value: true),
            subscriptionID: "turn-result-sub",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do { _ = try await database.save(subscription) }
        catch let e as CKError where e.code == .serverRejectedRequest { /* already exists */ }
        catch { /* poll fallback covers it */ }
    }

    private var senderID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }
}
