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

    private var senderID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }
}
