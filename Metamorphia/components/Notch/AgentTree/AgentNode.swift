import Foundation
#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

/// Lifecycle state of an agent tree node, UI-side mirror of
/// ``AgentNodeStateRef`` from the MetamorphiaAgentKit package. Kept as a distinct
/// type so the UI can add affordances (colors, icons) without widening the
/// sink protocol.
public enum AgentNodeState: Equatable {
    case pending
    case running
    case done
    case failed

#if canImport(MetamorphiaAgentKit)
    init(_ ref: AgentNodeStateRef) {
        switch ref {
        case .pending: self = .pending
        case .running: self = .running
        case .done:    self = .done
        case .failed:  self = .failed
        }
    }
#endif
}

/// A single node in the agent execution tree rendered above the notch's
/// response area. The root is always the master "Oracle" agent; children
/// represent sub-agents spawned by ``SubAgentCoordinator``.
public struct AgentNode: Identifiable, Equatable {
    public let id: String
    public let identity: AgentIdentity
    public var state: AgentNodeState
    /// The ≤32-char live status label swapped in for the node's default
    /// tagline while it is running.
    public var liveStatus: String?
    public var children: [AgentNode]

    public init(
        id: String,
        identity: AgentIdentity,
        state: AgentNodeState = .pending,
        liveStatus: String? = nil,
        children: [AgentNode] = []
    ) {
        self.id = id
        self.identity = identity
        self.state = state
        self.liveStatus = liveStatus
        self.children = children
    }
}

/// Snapshot of the whole tree shared with the UI as an `@Published`.
public struct AgentTreeSnapshot: Equatable {
    public var root: AgentNode

    public init(root: AgentNode) {
        self.root = root
    }

    /// In-place mutation helper — recursively finds `id` and runs `mutate` on
    /// it. Returns `true` if the node was found and mutated.
    @discardableResult
    public mutating func mutate(id: String, _ mutate: (inout AgentNode) -> Void) -> Bool {
        if root.id == id {
            mutate(&root)
            return true
        }
        return Self.mutate(in: &root.children, id: id, mutate)
    }

    /// Append `node` as a child of `parentId`. If `parentId` is nil the node
    /// is attached directly under the root. Returns `true` on success.
    @discardableResult
    public mutating func append(child: AgentNode, under parentId: String?) -> Bool {
        guard let parentId else {
            root.children.append(child)
            return true
        }
        return mutate(id: parentId) { node in
            node.children.append(child)
        }
    }

    private static func mutate(
        in children: inout [AgentNode],
        id: String,
        _ mutate: (inout AgentNode) -> Void
    ) -> Bool {
        for idx in children.indices {
            if children[idx].id == id {
                mutate(&children[idx])
                return true
            }
            if Self.mutate(in: &children[idx].children, id: id, mutate) {
                return true
            }
        }
        return false
    }
}
