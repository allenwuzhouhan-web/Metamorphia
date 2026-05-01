import Foundation

/// Thin HTTP wrapper for RSS/Atom/JSON news endpoints.
///
/// Uses an ephemeral URLSession so no cookies or credentials survive between
/// fetches. Sends a plain, honest User-Agent string — randomisation would be
/// detection evasion, not privacy. Retries twice with linear back-off
/// (0.5s, 1.0s) on transient (5xx / timeout) errors.
public struct AnonymizedNewsFetcher: Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Metamorphia/1.0",
        ]
        self.session = URLSession(configuration: config)
    }

    // Internal init for injection in tests.
    init(session: URLSession) {
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> Data {
        var lastError: Error = FetchError.notData
        for attempt in 0..<3 {
            if attempt > 0 {
                // Back-off: 0.5s, 1.0s
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt))
            }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    throw FetchError.invalidResponse
                }
                guard (200...299).contains(http.statusCode) else {
                    // 4xx — not retryable (not found, forbidden, etc.)
                    if (400...499).contains(http.statusCode) {
                        throw FetchError.httpError(status: http.statusCode)
                    }
                    // 5xx — retryable
                    lastError = FetchError.httpError(status: http.statusCode)
                    continue
                }
                return data
            } catch let fetchError as FetchError {
                // Re-throw non-retryable fetch errors immediately.
                if case .httpError(let status) = fetchError, (400...499).contains(status) {
                    throw fetchError
                }
                lastError = fetchError
            } catch {
                // URLSession timeout / network unreachable — retryable.
                lastError = error
            }
        }
        throw lastError
    }

    public enum FetchError: Error, LocalizedError {
        case httpError(status: Int)
        case notData
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .httpError(let status): return "HTTP \(status) from news endpoint."
            case .notData:               return "No data returned from news endpoint."
            case .invalidResponse:       return "Non-HTTP response from news endpoint."
            }
        }
    }
}
