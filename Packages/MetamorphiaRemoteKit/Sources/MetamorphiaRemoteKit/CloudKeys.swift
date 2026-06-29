import Foundation

/// CloudKit container, record type, and field names shared between the iPhone
/// sender and the Mac listener. Constants live in one file so a rename can't
/// silently desync the two ends.
public enum CloudKeys {
    public static let containerIdentifier = "iCloud.com.johannendersmith.metamorphia.remote"

    public enum RecordType {
        public static let pendingCommand = "PendingCommand"
        public static let turnResult     = "TurnResult"
    }

    public enum Field {
        public static let kind      = "kind"
        public static let payload   = "payload"
        public static let createdAt = "createdAt"
        public static let senderID  = "senderID"

        // TurnResult record fields
        public static let sessionID = "sessionID"
        public static let text      = "text"
        public static let status    = "status"
        public static let updatedAt = "updatedAt"
    }
}
