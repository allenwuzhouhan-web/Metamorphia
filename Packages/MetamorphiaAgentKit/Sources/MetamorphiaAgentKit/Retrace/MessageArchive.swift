import Foundation
import SQLite3
import CryptoKit

/// Reads iMessage history from `~/Library/Messages/chat.db` and archives new
/// messages into Retrace. Requires Full Disk Access — callers must verify.
///
/// Incremental: tracks the last seen Messages `message.ROWID` via
/// `archive_state`, so replays only pick up new rows.
///
/// Privacy: the sender handle is stored as a SHA-256 short-hash in the
/// activity stream receipt. The message body itself lives in the Retrace
/// index (which is local-only). No outbound network I/O.
public final class MessageArchive: @unchecked Sendable {

    public let ingest: RetraceIngest
    public let dbPath: String

    public static let defaultPath = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
    static let sourceKey = "messages.chat-db"

    public init(ingest: RetraceIngest, dbPath: String = MessageArchive.defaultPath) {
        self.ingest = ingest
        self.dbPath = dbPath
    }

    /// Scan for new rows since the watermark and ingest them. Returns the
    /// number of rows archived. Safe to call on a timer — incremental.
    @discardableResult
    public func runIncremental(limit: Int = 1000) async -> Int {
        guard FileManager.default.isReadableFile(atPath: dbPath) else { return 0 }

        var db: OpaquePointer?
        // Open the source in read-only mode on a temporary copy if possible.
        // Messages keeps an exclusive lock on chat.db when the app is open,
        // so we use SQLite's `immutable=1` URI which bypasses the lock.
        let uri = "file:\(dbPath)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_close(db) }

        let previousWatermark = Int64(await ingest.index.archiveWatermark(for: Self.sourceKey) ?? "0") ?? 0

        // Pull new messages with human-readable text (skipping attachment-only).
        // attributedBody can be populated when `text` is null (iOS 16+).
        let sql = """
        SELECT m.ROWID, m.guid, m.date, m.is_from_me, m.text,
               h.id AS handle_id, c.chat_identifier
          FROM message m
          LEFT JOIN handle h ON h.ROWID = m.handle_id
          LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
          LEFT JOIN chat c ON c.ROWID = cmj.chat_id
         WHERE m.ROWID > ? AND m.text IS NOT NULL AND LENGTH(m.text) >= 2
         ORDER BY m.ROWID ASC
         LIMIT ?
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int64(stmt, 1, previousWatermark)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        struct Row {
            let rowid: Int64
            let guid: String
            let date: Int64
            let isFromMe: Bool
            let text: String
            let handleID: String?
            let chatIdentifier: String?
        }

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let guid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let date = sqlite3_column_int64(stmt, 2)
            let isFromMe = sqlite3_column_int(stmt, 3) != 0
            let text = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let handleID = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let chatID = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            rows.append(Row(rowid: rowid, guid: guid, date: date, isFromMe: isFromMe, text: text, handleID: handleID, chatIdentifier: chatID))
        }
        guard !rows.isEmpty else { return 0 }

        var archived = 0
        for row in rows {
            // Messages.app stores dates as nanoseconds since 2001-01-01 (Cocoa epoch).
            let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
            let seconds = Double(row.date) / 1_000_000_000.0
            let timestamp = referenceDate.addingTimeInterval(seconds)

            let senderHash = row.handleID.map { Self.shortHash($0) } ?? (row.isFromMe ? "self" : "unknown")
            let title = row.isFromMe ? "You → \(row.chatIdentifier ?? "?")" : "\(row.handleID ?? "?") → You"

            let draft = RetraceIngest.Draft(
                kind: .message,
                timestamp: timestamp,
                title: title,
                body: row.text,
                confidence: 1.0,
                sourceMeta: [
                    "guid": row.guid,
                    "senderHash": senderHash,
                    "chatIdentifier": row.chatIdentifier ?? "",
                    "isFromMe": row.isFromMe ? "1" : "0",
                ],
                interestEvent: .longDwell,
                interestScale: 0.2
            )
            if await ingest.ingest(draft) != nil {
                archived += 1
            }
        }

        if let maxRowid = rows.map(\.rowid).max() {
            await ingest.index.setArchiveWatermark(String(maxRowid), for: Self.sourceKey)
        }
        return archived
    }

    static func shortHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
