/*
 * Metamorphia
 * Clipboard entity extraction hook for Project Continuum Phase 1.
 *
 * Subscribes to ClipboardManager.$clipboardHistory and runs EntityExtractor
 * over every new text item, posting continuumEntitiesExtracted notifications
 * so Phase 2's InterestGraphStore can potentiate entity weights from copied
 * text without touching the clipboard-finance code in MarketQuoteMonitor.
 *
 * Only text-bearing items are processed (text, url, rtf). Images and file
 * references are skipped — there is nothing to tag.
 *
 * Invariants:
 *  - Singleton is inert until `start(aliasStore:termFrequency:)` is called.
 *  - Exactly one EntityAliasStore / RollingTermFrequency is shared with
 *    AICommandViewModel (passed in from MetamorphiaBootstrap); no duplicate
 *    writers to entity-aliases.json.
 *  - Dedupe gate: pin/unpin/clear on the same ClipboardItem.id does not
 *    re-extract or re-post.
 */

import Foundation
import Combine
import MetamorphiaAgentKit

@MainActor
public final class ClipboardInsights {

    public static let shared = ClipboardInsights()

    private var extractor: EntityExtractor?
    private var cancellables = Set<AnyCancellable>()

    /// Last ClipboardItem.id that was submitted for extraction. Guards against
    /// re-posting when pin/unpin/clear triggers a $clipboardHistory change
    /// without a genuinely new first item.
    private var lastProcessedItemID: UUID?

    private init() {
        // Inert until start(aliasStore:termFrequency:) is called from bootstrap.
    }

    // MARK: - Bootstrap entry point

    /// Wire up the shared stores and begin observing clipboard changes.
    /// Must be called exactly once from MetamorphiaBootstrap before the
    /// ClipboardManager starts emitting items.
    public func start(aliasStore: EntityAliasStore, termFrequency: RollingTermFrequency) {
        guard extractor == nil else { return }   // idempotent
        self.extractor = EntityExtractor(aliasStore: aliasStore, termFrequency: termFrequency)
        observeClipboard()
    }

    // MARK: - Clipboard observation

    private func observeClipboard() {
        ClipboardManager.shared.$clipboardHistory
            .dropFirst()
            .compactMap { $0.first }
            // Dedupe: pin/unpin/clear all trigger a $clipboardHistory change but
            // the first item stays the same. Only proceed when the id changes.
            .removeDuplicates(by: { $0.id == $1.id })
            .sink { [weak self] item in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleClipboardItem(item)
                }
            }
            .store(in: &cancellables)
    }

    private func handleClipboardItem(_ item: ClipboardItem) async {
        guard let extractor else { return }
        guard let text = item.stringData, !text.isEmpty else { return }

        // Belt-and-suspenders dedupe in case Combine's removeDuplicates
        // ever races with a rapid two-item replacement.
        guard item.id != lastProcessedItemID else { return }
        lastProcessedItemID = item.id

        let entities = await extractor.extract(text)
        guard !entities.isEmpty else { return }

        NotificationCenter.default.post(
            Notification.continuumEntitiesExtracted(entities: entities, source: .clipboard, text: text, clipboardItemId: item.id)
        )
    }
}
