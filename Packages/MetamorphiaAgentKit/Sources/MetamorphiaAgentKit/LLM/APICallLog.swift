import Foundation
import Combine

/// One recorded call to an LLM provider's HTTP API.
///
/// Captured at the request boundary inside every service, so the log covers
/// streaming and non-streaming calls, successes and failures alike. Token counts
/// are optional because streaming responses usually omit a usage block.
public struct APICallLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let provider: String
    public let model: String
    public let streaming: Bool
    public let inputChars: Int
    public let outputChars: Int
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let durationMs: Int
    public let success: Bool
    public let error: String?

    public init(
        date: Date,
        provider: String,
        model: String,
        streaming: Bool,
        inputChars: Int,
        outputChars: Int,
        promptTokens: Int?,
        completionTokens: Int?,
        durationMs: Int,
        success: Bool,
        error: String?
    ) {
        self.id = UUID()
        self.date = date
        self.provider = provider
        self.model = model
        self.streaming = streaming
        self.inputChars = inputChars
        self.outputChars = outputChars
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.durationMs = durationMs
        self.success = success
        self.error = error
    }
}

/// A bounded, in-memory, newest-first log of LLM API calls.
///
/// Thread-safe: services record from background tasks under a lock, and the
/// `@Published` snapshot is republished on the main thread so SwiftUI can observe
/// it directly. This is the single surviving Settings surface — the "AI API log".
public final class APICallLog: ObservableObject, @unchecked Sendable {
    public static let shared = APICallLog()

    /// Newest call first. Capped at `limit`.
    @Published public private(set) var entries: [APICallLogEntry] = []

    private let lock = NSLock()
    private var storage: [APICallLogEntry] = []
    private let limit = 200

    private init() {}

    public func record(_ entry: APICallLogEntry) {
        lock.lock()
        storage.insert(entry, at: 0)
        if storage.count > limit {
            storage.removeLast(storage.count - limit)
        }
        let snapshot = storage
        lock.unlock()
        publish(snapshot)
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        publish([])
    }

    private func publish(_ snapshot: [APICallLogEntry]) {
        if Thread.isMainThread {
            entries = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries = snapshot
            }
        }
    }
}
