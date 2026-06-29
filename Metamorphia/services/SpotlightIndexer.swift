import Combine
import CoreSpotlight
import Defaults
import Foundation
import UniformTypeIdentifiers

/// Indexes Retrace recall items and Shelf items into Spotlight as
/// CSSearchableItem (titles + short snippets only — no bodies, no paths).
/// Entirely opt-in via Defaults[.enableSpotlightIndexing]; a one-time full
/// pass runs on start, plus incremental updates on ingest/shelf changes.
/// Disabling the opt-in deletes the app's whole Spotlight domain.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private init() {}

    private let domain = "com.metamorphia.spotlight"
    private let retraceType = "com.metamorphia.retrace.item"
    private let shelfType = "com.metamorphia.shelf.item"
    private var started = false
    private var optInCancellable: AnyCancellable?

    func start() {
        guard !started else { return }
        started = true
        // React to opt-in toggles: index on enable, purge on disable.
        optInCancellable = Defaults.publisher(.enableSpotlightIndexing)
            .sink { [weak self] change in
                Task { @MainActor [weak self] in
                    if change.newValue {
                        await self?.indexAll()
                    } else {
                        self?.purgeAll()
                    }
                }
            }
        guard Defaults[.enableSpotlightIndexing] else { return }
        Task { await indexAll() }
    }

    // MARK: - Full pass

    /// Indexes the most recent Retrace scenes (via broad search) and all
    /// shelf items. Called once at start and whenever the opt-in is enabled.
    private func indexAll() async {
        guard Defaults[.enableSpotlightIndexing] else { return }
        var items: [CSSearchableItem] = []

        // Retrace: use a broad query for common terms to surface recent content.
        // RetraceSurface.search is a ranked search, not a dump, so we use a
        // deliberately wide query. Items without hits are not indexed here;
        // incremental indexing (indexRetrace) fills in new items at ingest.
        if let result = await RetraceSurface.shared.search("the") {
            items += result.scenes.prefix(200).map { scene in
                let hero = scene.hero.item
                let id = "retrace:\(hero.id.uuidString)"
                let title = hero.title ?? "(untitled)"
                let snippet = String(hero.body.prefix(180))
                return makeItem(id: id, type: retraceType, title: title, snippet: snippet.isEmpty ? nil : snippet)
            }
        }

        // Shelf items.
        items += ShelfStateViewModel.shared.items.map { item in
            makeItem(id: "shelf:\(item.id.uuidString)", type: shelfType,
                     title: item.displayName, snippet: nil)
        }

        guard !items.isEmpty else { return }
        try? await CSSearchableIndex.default().indexSearchableItems(items)
    }

    // MARK: - Incremental indexing

    /// Index a single Retrace item. Call from the ingest path when a new
    /// item is committed. Gated on the opt-in flag so callers don't need
    /// to check it themselves.
    func indexRetrace(id: String, title: String, snippet: String) {
        guard Defaults[.enableSpotlightIndexing] else { return }
        let item = makeItem(id: "retrace:\(id)", type: retraceType,
                            title: title, snippet: snippet.isEmpty ? nil : snippet)
        CSSearchableIndex.default().indexSearchableItems([item], completionHandler: nil)
    }

    /// Index a single Shelf item.
    func indexShelf(id: String, title: String) {
        guard Defaults[.enableSpotlightIndexing] else { return }
        let item = makeItem(id: "shelf:\(id)", type: shelfType, title: title, snippet: nil)
        CSSearchableIndex.default().indexSearchableItems([item], completionHandler: nil)
    }

    /// Remove a single Shelf item from the index.
    func removeShelf(id: String) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: ["shelf:\(id)"], completionHandler: nil)
    }

    // MARK: - Purge

    private func purgeAll() {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domain], completionHandler: nil)
    }

    // MARK: - Factory

    private func makeItem(id: String, type: String, title: String, snippet: String?) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.content)
        attrs.title = title
        if let snippet, !snippet.isEmpty {
            attrs.contentDescription = snippet
        }
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attrs)
    }
}
