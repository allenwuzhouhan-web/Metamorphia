import Foundation

// MARK: - MenuItem

/// A single entry in the frontmost app's menu bar tree, extracted via `AXUIElement` —
/// entirely local, no pixels required. This is the foundation for driving apps whose
/// main canvas is opaque to the Accessibility API (Blender, DaVinci Resolve, CapCut,
/// Unity, most game engines and Metal/OpenGL apps): their menu bars remain fully
/// accessible and expose nearly every operation the app performs.
///
/// Populated by `MenuBarReader.readMenuBar(pid:)` and surfaced on `ScreenMap.menus`.
/// Invoked by `MenuBarReader.invoke(path:pid:)` — which re-walks the live AX tree at
/// the moment of dispatch so a stale snapshot can never produce a wrong press.
public struct MenuItem: Sendable {
    /// Human-readable title of the item, e.g. `"Export As…"`.
    public let title: String

    /// Full breadcrumb from the menu bar root, e.g. `["File", "Export As…", "glTF 2.0 (.glb/.gltf)"]`.
    /// This is the canonical invocation key — pass it to `MenuBarReader.invoke(path:pid:)`.
    public let path: [String]

    /// Keyboard shortcut in the form `"cmd+shift+e"`, or `nil` if the item has none.
    /// When present, the LocalDecisionEngine prefers firing the hotkey over walking
    /// the menu — zero AX calls required at dispatch time.
    public let shortcut: String?

    /// Whether the item is currently enabled. Disabled items are still listed so the
    /// agent can understand what operations exist even when they're contextually
    /// unavailable, but the refuse-gate rejects any attempt to invoke them.
    public let enabled: Bool

    /// Whether the item opens a submenu (i.e., has children). `true` items are not
    /// themselves invocable — the agent must drill in and pick a leaf.
    public let hasSubmenu: Bool

    public init(
        title: String,
        path: [String],
        shortcut: String?,
        enabled: Bool,
        hasSubmenu: Bool
    ) {
        self.title = title
        self.path = path
        self.shortcut = shortcut
        self.enabled = enabled
        self.hasSubmenu = hasSubmenu
    }
}
