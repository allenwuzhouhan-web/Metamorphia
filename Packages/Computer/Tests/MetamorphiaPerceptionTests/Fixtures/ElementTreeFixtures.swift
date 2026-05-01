import Foundation
import CoreGraphics
@testable import MetamorphiaPerception

/// Test fixtures that build lightweight element-tree scenarios for RefStabilizer tests.
///
/// Each fixture produces an ordered `[FixtureNode]` flat list (parent-first, depth-first)
/// mirroring how `AXReader` emits `RawElement` lists to `PerceptionPipeline.buildElements`.
/// The fixtures deliberately omit `RawElement` so tests can drive `RefStabilizer.assign`
/// directly without spinning up the pipeline.
enum ElementTreeFixtures {

    // MARK: - Node shape

    /// One node in a synthetic AX-like tree. Tests feed these into the stabilizer as
    /// `RefAssignment` inputs. Position is authored in *parent-relative* form — the
    /// fixture walker converts it to absolute bounds.
    struct FixtureNode {
        let role: ElementRole
        let label: String
        let identifier: String
        /// Parent-relative origin, in points. For the root node this is the screen origin.
        let relativeOrigin: CGPoint
        let size: CGSize

        init(
            role: ElementRole,
            label: String = "",
            identifier: String = "",
            relativeOrigin: CGPoint = .zero,
            size: CGSize = CGSize(width: 80, height: 30)
        ) {
            self.role = role
            self.label = label
            self.identifier = identifier
            self.relativeOrigin = relativeOrigin
            self.size = size
        }
    }

    /// A tree node for builder APIs — lets fixtures nest via children.
    struct Tree {
        let node: FixtureNode
        var children: [Tree]

        init(_ node: FixtureNode, children: [Tree] = []) {
            self.node = node
            self.children = children
        }
    }

    /// Flat parent-first element list with absolute bounds + depth, ready to feed into
    /// the stabilizer as `RefAssignment`s.
    struct FlatElement {
        let role: ElementRole
        let label: String
        let identifier: String
        let bounds: CGRect
        let depth: Int
    }

    // MARK: - Flattening

    /// Depth-first pre-order walk — matches AXReader's emission order.
    static func flatten(_ tree: Tree, bundleID: String, translate: CGPoint = .zero, depth: Int = 0) -> [FlatElement] {
        var out: [FlatElement] = []
        let absOrigin = CGPoint(
            x: tree.node.relativeOrigin.x + translate.x,
            y: tree.node.relativeOrigin.y + translate.y
        )
        let bounds = CGRect(origin: absOrigin, size: tree.node.size)
        out.append(FlatElement(
            role: tree.node.role,
            label: tree.node.label,
            identifier: tree.node.identifier,
            bounds: bounds,
            depth: depth
        ))
        for child in tree.children {
            out.append(contentsOf: flatten(child, bundleID: bundleID, translate: absOrigin, depth: depth + 1))
        }
        return out
    }

    // MARK: - Assignment driver

    /// Drives `RefStabilizer.assign` over a flat element list using the same
    /// ancestry-tracking logic as `PerceptionPipeline.buildElements`. Returns the refs
    /// in order so tests can assert against them without rebuilding the pipeline.
    static func assignRefs(
        _ elements: [FlatElement],
        bundleID: String = "com.test.app",
        stabilizer: RefStabilizer
    ) -> [ElementRef] {
        var parentStack: [(depth: Int, ref: ElementRef, role: ElementRole, label: String, bounds: CGRect?)] = []
        var siblingCounter: [UInt64: Int] = [:]
        var refs: [ElementRef] = []

        for el in elements {
            // Pop to strictly-shallower parent.
            while let last = parentStack.last, last.depth >= el.depth {
                let popped = last
                parentStack.removeLast()
                // Drop sibling counters scoped to popped parent.
                siblingCounter = siblingCounter.filter { key, _ in
                    (key & 0xFFFF_FFFF_0000_0000) != (UInt64(UInt32(truncatingIfNeeded: popped.ref.index)) << 32)
                }
            }

            let parent = parentStack.last
            let parentRefIndex = parent?.ref.index ?? 0
            let parentBounds = parent?.bounds
            let chain = parentStack.map { ($0.role, $0.label) }
            let ancestry = AncestryHash.compute(from: chain)

            let siblingKey = makeSiblingKey(parentRefIndex: parentRefIndex, role: el.role)
            let siblingIndex = siblingCounter[siblingKey, default: 0]
            siblingCounter[siblingKey] = siblingIndex + 1

            let assignment = RefAssignment(
                bundleID: bundleID,
                role: el.role,
                label: el.label,
                identifier: el.identifier,
                bounds: el.bounds,
                parentBounds: parentBounds,
                ancestryHash: ancestry,
                depth: el.depth,
                siblingIndex: siblingIndex
            )
            let ref = stabilizer.assign(assignment)
            refs.append(ref)
            parentStack.append((depth: el.depth, ref: ref, role: el.role, label: el.label, bounds: el.bounds))
        }

        return refs
    }

    private static func makeSiblingKey(parentRefIndex: Int, role: ElementRole) -> UInt64 {
        let parentBits = UInt64(UInt32(truncatingIfNeeded: parentRefIndex)) << 32
        var roleHash: UInt32 = 5381
        for byte in role.rawValue.utf8 {
            roleHash = (roleHash &<< 5) &+ roleHash &+ UInt32(byte)
        }
        return parentBits | UInt64(roleHash)
    }

    // MARK: - Scenario builders

    /// Sidebar with two list items that both contain a "Close" button — the classic
    /// duplicate-label siblings case. Tier 2 must disambiguate via occurrence index.
    static func sidebarWithDuplicateCloseButtons() -> Tree {
        Tree(
            FixtureNode(role: .window, label: "MainWindow", relativeOrigin: .zero, size: CGSize(width: 600, height: 800)),
            children: [
                Tree(
                    FixtureNode(role: .list, label: "Sidebar", relativeOrigin: CGPoint(x: 0, y: 50), size: CGSize(width: 200, height: 500)),
                    children: [
                        Tree(
                            FixtureNode(role: .group, label: "Item A", relativeOrigin: CGPoint(x: 0, y: 0), size: CGSize(width: 200, height: 60)),
                            children: [
                                Tree(FixtureNode(role: .button, label: "Close", relativeOrigin: CGPoint(x: 160, y: 15), size: CGSize(width: 30, height: 30)))
                            ]
                        ),
                        Tree(
                            FixtureNode(role: .group, label: "Item B", relativeOrigin: CGPoint(x: 0, y: 80), size: CGSize(width: 200, height: 60)),
                            children: [
                                Tree(FixtureNode(role: .button, label: "Close", relativeOrigin: CGPoint(x: 160, y: 15), size: CGSize(width: 30, height: 30)))
                            ]
                        ),
                    ]
                )
            ]
        )
    }

    /// Safari-like window with a toolbar Back button at a configurable x offset —
    /// used to test ref stability across small/medium/large reflows.
    static func safariWithBackButton(backButtonX: CGFloat) -> Tree {
        Tree(
            FixtureNode(role: .window, label: "Safari", relativeOrigin: .zero, size: CGSize(width: 1200, height: 800)),
            children: [
                Tree(
                    FixtureNode(role: .toolbar, label: "Toolbar", relativeOrigin: CGPoint(x: 0, y: 0), size: CGSize(width: 1200, height: 40)),
                    children: [
                        Tree(FixtureNode(role: .button, label: "Back", relativeOrigin: CGPoint(x: backButtonX, y: 10), size: CGSize(width: 40, height: 24)))
                    ]
                ),
                Tree(FixtureNode(role: .webArea, label: "example.com", relativeOrigin: CGPoint(x: 0, y: 40), size: CGSize(width: 1200, height: 760)))
            ]
        )
    }

    /// File menu with a "Save" button and a toolbar with its own "Save" button —
    /// verifies ancestry disambiguates same-label siblings across containers.
    static func windowWithFileMenuAndToolbarSave() -> Tree {
        Tree(
            FixtureNode(role: .window, label: "EditorWindow", relativeOrigin: .zero, size: CGSize(width: 1000, height: 700)),
            children: [
                Tree(
                    FixtureNode(role: .menuBar, label: "MenuBar", relativeOrigin: .zero, size: CGSize(width: 1000, height: 24)),
                    children: [
                        Tree(
                            FixtureNode(role: .menuBarItem, label: "File", relativeOrigin: CGPoint(x: 0, y: 0), size: CGSize(width: 50, height: 24)),
                            children: [
                                Tree(FixtureNode(role: .menuItem, label: "Save", relativeOrigin: CGPoint(x: 0, y: 30), size: CGSize(width: 120, height: 22)))
                            ]
                        )
                    ]
                ),
                Tree(
                    FixtureNode(role: .toolbar, label: "Toolbar", relativeOrigin: CGPoint(x: 0, y: 24), size: CGSize(width: 1000, height: 40)),
                    children: [
                        Tree(FixtureNode(role: .button, label: "Save", relativeOrigin: CGPoint(x: 10, y: 8), size: CGSize(width: 60, height: 24)))
                    ]
                )
            ]
        )
    }

    /// Canvas app (Blender/DaVinci-style) with icon-only buttons: empty labels,
    /// no identifiers, only bounds. Tier 3 must keep these stable across parent
    /// reflows via parent-anchored position.
    static func canvasAppWithIconButtons(parentOrigin: CGPoint = .zero, parentSize: CGSize = CGSize(width: 400, height: 60)) -> Tree {
        Tree(
            FixtureNode(role: .window, label: "Canvas", relativeOrigin: .zero, size: CGSize(width: 1200, height: 800)),
            children: [
                Tree(
                    FixtureNode(role: .toolbar, label: "", relativeOrigin: parentOrigin, size: parentSize),
                    children: [
                        // 4 icon buttons evenly spaced along the toolbar's x-axis.
                        Tree(FixtureNode(role: .button, label: "", relativeOrigin: CGPoint(x: parentSize.width * 0.05, y: 15), size: CGSize(width: 30, height: 30))),
                        Tree(FixtureNode(role: .button, label: "", relativeOrigin: CGPoint(x: parentSize.width * 0.30, y: 15), size: CGSize(width: 30, height: 30))),
                        Tree(FixtureNode(role: .button, label: "", relativeOrigin: CGPoint(x: parentSize.width * 0.55, y: 15), size: CGSize(width: 30, height: 30))),
                        Tree(FixtureNode(role: .button, label: "", relativeOrigin: CGPoint(x: parentSize.width * 0.80, y: 15), size: CGSize(width: 30, height: 30))),
                    ]
                )
            ]
        )
    }

    /// A page with N list items, optionally interrupted by a dialog sheet. Used for
    /// add/remove-without-shift tests.
    static func pageWithOptionalDialog(itemCount: Int = 5, includeDialog: Bool) -> Tree {
        var pageChildren: [Tree] = []
        for i in 0..<itemCount {
            pageChildren.append(Tree(FixtureNode(
                role: .button,
                label: "Item \(i)",
                relativeOrigin: CGPoint(x: 20, y: 60 + CGFloat(i) * 40),
                size: CGSize(width: 160, height: 30)
            )))
        }
        if includeDialog {
            pageChildren.append(Tree(
                FixtureNode(role: .dialog, label: "Confirm", relativeOrigin: CGPoint(x: 200, y: 200), size: CGSize(width: 300, height: 160)),
                children: [
                    Tree(FixtureNode(role: .button, label: "OK", relativeOrigin: CGPoint(x: 200, y: 120), size: CGSize(width: 60, height: 24))),
                    Tree(FixtureNode(role: .button, label: "Cancel", relativeOrigin: CGPoint(x: 270, y: 120), size: CGSize(width: 60, height: 24))),
                ]
            ))
        }
        return Tree(
            FixtureNode(role: .window, label: "PageWindow", relativeOrigin: .zero, size: CGSize(width: 800, height: 600)),
            children: pageChildren
        )
    }
}
