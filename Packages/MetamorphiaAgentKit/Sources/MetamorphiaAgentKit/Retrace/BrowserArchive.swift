import Foundation
import CryptoKit

/// Archives browser pages into Retrace. The host app's existing
/// `BrowserTabSensor` + `BrowserDOMCaptureTool` produce `(url, title, text)`
/// triples after a dwell threshold. This archive wraps the write side.
///
/// Private / incognito mode must be detected upstream — `BrowserTabSensor`
/// already does this fail-closed. This archive doesn't know about incognito
/// state and will write anything it's handed.
public struct BrowserArchive: Sendable {

    public let ingest: RetraceIngest

    public init(ingest: RetraceIngest) {
        self.ingest = ingest
    }

    @discardableResult
    public func record(
        url: String,
        title: String?,
        bodyText: String,
        browserBundleID: String,
        placeHash: String? = nil,
        at: Date = Date()
    ) async -> Int64? {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let draft = RetraceIngest.Draft(
            kind: .browser,
            timestamp: at,
            appBundleID: browserBundleID,
            url: url,
            placeHash: placeHash,
            title: title ?? URL(string: url)?.host,
            body: trimmed,
            confidence: 0.95,
            sourceMeta: [
                "browserBundleID": browserBundleID,
                "urlHashShort": Self.urlHashShort(url),
            ],
            interestEvent: .longDwell,
            interestScale: 0.3
        )
        return await ingest.ingest(draft)
    }

    static func urlHashShort(_ url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
