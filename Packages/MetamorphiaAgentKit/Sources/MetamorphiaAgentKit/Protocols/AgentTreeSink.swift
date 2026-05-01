import Foundation

// MARK: - Sendable mirrors for cross-target tree events

/// Identity of an agent in the execution tree. The UI target maps this to
/// friendly names ("Oracle", "Scout", "Scribe", ...) via `AgentNameCatalog`;
/// this enum stays package-side so no UI dependency leaks in.
public enum AgentIdentityRef: String, Sendable, Equatable {
    case oracle
    case scout
    case curator
    case warden
    case mime
    case scribe
    // Reserved for future specializations — unused today.
    case forge
    case sage
    case herald
    case ranger
    case tinker
    case muse

    /// Map a package-side ``SubAgentType`` onto a tree identity.
    public static func from(subAgentType: SubAgentType) -> AgentIdentityRef {
        switch subAgentType {
        case .researcher:    return .scout
        case .fileOperator:  return .curator
        case .systemControl: return .warden
        case .uiAutomation:  return .mime
        case .composer:      return .scribe
        }
    }
}

/// Lifecycle state of a node in the agent tree.
public enum AgentNodeStateRef: String, Sendable, Equatable {
    case pending
    case running
    case done
    case failed
}

/// Snapshot of a single node crossing the sink boundary. UI target converts
/// these into its own `AgentNode` values, which carry live status strings and
/// children.
public struct AgentNodeSnapshot: Sendable, Equatable {
    public let id: String
    public let identity: AgentIdentityRef
    public let state: AgentNodeStateRef
    public let liveStatus: String?

    public init(
        id: String,
        identity: AgentIdentityRef,
        state: AgentNodeStateRef = .pending,
        liveStatus: String? = nil
    ) {
        self.id = id
        self.identity = identity
        self.state = state
        self.liveStatus = liveStatus
    }
}

// MARK: - Sink protocol

/// A sink for tree-lifecycle events emitted by the agent loop and
/// `SubAgentCoordinator`. Parallel to ``AgentProgressSink``, but scoped to the
/// parent/child relationships and per-node lifecycle that the UI needs to
/// render an Oracle → Scout/Scribe monospace tree.
///
/// Implementations should be thread-safe — events may arrive from detached
/// Tasks or sub-agent coordinator tasks.
public protocol AgentTreeSink: AnyObject, Sendable {
    /// Emitted once per run, before any nodes are added.
    func treeStarted(root: AgentIdentityRef)
    /// Emitted when a new node joins the tree. `parentId == nil` means the
    /// node is a direct child of the root.
    func nodeAdded(parentId: String?, node: AgentNodeSnapshot)
    /// Emitted when a node transitions between states or its live-status
    /// tagline changes. `liveStatus` is non-nil only while the node is
    /// running — `.done`/`.failed` clears it.
    func nodeStateChanged(id: String, state: AgentNodeStateRef, liveStatus: String?)
}

/// No-op sink for tests and contexts where tree events are ignored.
public final class NullTreeSink: AgentTreeSink, @unchecked Sendable {
    public init() {}
    public func treeStarted(root: AgentIdentityRef) {}
    public func nodeAdded(parentId: String?, node: AgentNodeSnapshot) {}
    public func nodeStateChanged(id: String, state: AgentNodeStateRef, liveStatus: String?) {}
}
