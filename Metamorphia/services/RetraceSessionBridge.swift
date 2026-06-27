/*
 * Metamorphia
 * Subscribes to `ActivityStream` and writes a `sessions` row into the
 * Retrace index every time `SessionSegmenter` emits `.sessionClosed`. This
 * lets the query engine cluster hits by session (Phase 4 of the plan).
 *
 * The session row is lightweight — just bookkeeping for the UI scene
 * ribbon. Content items are linked to sessions through their own
 * `sessionID` column at ingest time.
 */

import Foundation
import Combine
import MetamorphiaAgentKit

@MainActor
final class RetraceSessionBridge {

    static let shared = RetraceSessionBridge()

    private var subscription: AnyCancellable?

    func start(stream: ActivityStream) {
        subscription?.cancel()
        subscription = stream.events
            .compactMap { event -> ActivityEvent? in
                if case .sessionClosed = event { return event } else { return nil }
            }
            .sink { event in
                Task.detached(priority: .background) {
                    await Self.handle(event)
                }
            }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    private static func handle(_ event: ActivityEvent) async {
        guard case let .sessionClosed(bundleID, docHint, durationSeconds, cadenceTier, at) = event else { return }
        guard let idx = await MainActor.run(body: { RetraceSurface.shared.index }) else { return }

        let endedAt = at
        let startedAt = at.addingTimeInterval(-Double(durationSeconds))
        let tierRaw: Int = {
            switch cadenceTier {
            case .idle:  return 0
            case .light: return 1
            case .heavy: return 2
            }
        }()

        idx.upsertSession(
            id: UUID(),            // SessionSegmenter doesn't expose an ID; generate one per closure.
            startedAt: startedAt,
            endedAt: endedAt,
            appBundleID: bundleID,
            docHint: docHint,
            cadenceTierRaw: tierRaw,
            placeHash: nil,
            topEntitiesJSON: nil
        )
    }
}
