import Foundation
#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

/// The roster of one-word agent identities we display in the notch.
/// The ``displayName`` is always a single word; the ``tagline`` is the
/// default ≤10-word sentence rendered next to it when the node isn't
/// currently broadcasting a live status.
public enum AgentIdentity: Equatable {
    case oracle
    case scout
    case curator
    case warden
    case mime
    case scribe
    // Reserved — not assigned yet, kept here so the catalog is the single
    // source of truth when future specializations get wired in.
    case forge
    case sage
    case herald
    case ranger
    case tinker
    case muse

    public var displayName: String {
        switch self {
        case .oracle:  return "Oracle"
        case .scout:   return "Scout"
        case .curator: return "Curator"
        case .warden:  return "Warden"
        case .mime:    return "Mime"
        case .scribe:  return "Scribe"
        case .forge:   return "Forge"
        case .sage:    return "Sage"
        case .herald:  return "Herald"
        case .ranger:  return "Ranger"
        case .tinker:  return "Tinker"
        case .muse:    return "Muse"
        }
    }

    public var tagline: String {
        switch self {
        case .oracle:  return "Answers directly, delegates when the task is big"
        case .scout:   return "Combs the web for facts and pulls back citations"
        case .curator: return "Finds, reads, and rearranges files across your disk"
        case .warden:  return "Manages apps, windows, music, and macOS settings"
        case .mime:    return "Clicks, types, and scrolls the screen on your behalf"
        case .scribe:  return "Drafts text, emails, and formatted written output"
        case .forge:   return "Reserved — future builder role"
        case .sage:    return "Reserved — future knowledge role"
        case .herald:  return "Reserved — future notification role"
        case .ranger:  return "Reserved — future navigator role"
        case .tinker:  return "Reserved — future repair role"
        case .muse:    return "Reserved — future creative role"
        }
    }
}

public enum AgentNameCatalog {
#if canImport(MetamorphiaAgentKit)
    /// Convert a cross-target ``AgentIdentityRef`` (emitted by the package)
    /// into the UI-side ``AgentIdentity`` enum.
    public static func identity(for ref: AgentIdentityRef) -> AgentIdentity {
        switch ref {
        case .oracle:  return .oracle
        case .scout:   return .scout
        case .curator: return .curator
        case .warden:  return .warden
        case .mime:    return .mime
        case .scribe:  return .scribe
        case .forge:   return .forge
        case .sage:    return .sage
        case .herald:  return .herald
        case .ranger:  return .ranger
        case .tinker:  return .tinker
        case .muse:    return .muse
        }
    }

    /// Map a ``SubAgentType`` directly to its tree identity — exists for
    /// convenience when the package emits a raw `SubAgentType` without first
    /// passing through ``AgentIdentityRef``.
    public static func identity(for subAgentType: SubAgentType) -> AgentIdentity {
        identity(for: AgentIdentityRef.from(subAgentType: subAgentType))
    }
#endif
}
