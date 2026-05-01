import Foundation

// MARK: - Notification name

public extension Notification.Name {
    /// Posted whenever the entity extractor produces results. UserInfo keys:
    /// - "source": EntitySource.rawValue (String)
    /// - "entities": [ExtractedEntity] — passed directly (Sendable + Hashable)
    /// - "text": String — the original text that was processed
    ///
    /// Prefer the typed helpers on `Notification` below rather than accessing
    /// userInfo keys directly.
    static let continuumEntitiesExtracted = Notification.Name("com.metamorphia.continuum.entitiesExtracted")
}

// MARK: - Source discriminator

/// Where a batch of entities originated.
public enum EntitySource: String, Sendable {
    case userTurn, clipboard, backfill, calendar, news
}

// MARK: - Typed notification helpers

public extension Notification {
    /// Build a typed `.continuumEntitiesExtracted` notification.
    static func continuumEntitiesExtracted(
        entities: [ExtractedEntity],
        source: EntitySource,
        text: String,
        clipboardItemId: UUID? = nil
    ) -> Notification {
        var info: [String: Any] = [
            "entities": entities,
            "source": source.rawValue,
            "text": text,
        ]
        if let id = clipboardItemId {
            info["clipboardItemId"] = id.uuidString
        }
        return Notification(
            name: .continuumEntitiesExtracted,
            object: nil,
            userInfo: info
        )
    }

    /// Typed accessor — returns `[ExtractedEntity]` from userInfo.
    /// Supports both the new direct-value form and the legacy `Data` form
    /// for backward compatibility during rollout.
    var continuumEntities: [ExtractedEntity]? {
        guard let info = userInfo else { return nil }
        // New form: direct [ExtractedEntity]
        if let direct = info["entities"] as? [ExtractedEntity] {
            return direct
        }
        // Legacy form: JSON-encoded Data
        // TODO(Phase 3): remove legacy Data decode path once confirmed unused in production
        if let data = info["entities"] as? Data {
            return try? JSONDecoder().decode([ExtractedEntity].self, from: data)
        }
        return nil
    }

    /// Typed accessor — returns the `EntitySource`.
    var continuumSource: EntitySource? {
        guard let raw = userInfo?["source"] as? String else { return nil }
        return EntitySource(rawValue: raw)
    }

    /// Typed accessor — returns the original text.
    var continuumText: String? {
        userInfo?["text"] as? String
    }

    /// Typed accessor — returns the clipboard item id carried by clipboard-source
    /// notifications. Nil for all other sources.
    var continuumClipboardItemId: UUID? {
        guard let raw = userInfo?["clipboardItemId"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}
