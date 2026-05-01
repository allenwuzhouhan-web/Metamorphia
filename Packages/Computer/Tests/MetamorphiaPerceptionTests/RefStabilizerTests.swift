import XCTest
import CoreGraphics
@testable import MetamorphiaPerception

/// Rank 4 — Stable Element UIDs across layout reflows.
///
/// These tests exercise the tiered identity cascade in `RefStabilizer`:
/// 1. `identifier` — AX identifier attribute (most stable)
/// 2. `label`      — non-empty label + ancestry + occurrence index
/// 3. `position`   — parent-anchored 10% bucket + sibling index
/// 4. `fallback`   — coarse 50 px grid (explicit instability contract)
///
/// Each test drives either `RefStabilizer.assign` directly or through the fixture
/// flattener in `ElementTreeFixtures.assignRefs`, then asserts the expected
/// ref-identity and tier.
final class RefStabilizerTests: XCTestCase {

    // MARK: - Tier 1 (identifier)

    func testIdentifierAttributeSurvivesLabelChange() {
        // Snapshot 1: button identified by AX identifier "save-btn" with label "Save".
        let stabilizer = RefStabilizer()
        let a = stabilizer.assign(assignment(
            role: .button, label: "Save", identifier: "save-btn",
            bounds: CGRect(x: 10, y: 10, width: 80, height: 30)
        ))
        stabilizer.commitSnapshot()

        // Snapshot 2: label changed to "Save…" (localization flip, trailing ellipsis,
        // whatever) but the identifier is the dev-assigned anchor and remains.
        let b = stabilizer.assign(assignment(
            role: .button, label: "Save\u{2026}", identifier: "save-btn",
            bounds: CGRect(x: 10, y: 10, width: 80, height: 30)
        ))

        XCTAssertEqual(a.index, b.index, "Identifier (tier 1) must stick even when label mutates.")
        XCTAssertEqual(stabilizer.identityTier(for: b), .identifier)
        XCTAssertEqual(stabilizer.stabilityScore(for: b), 1.0, accuracy: 0.0001)
    }

    // MARK: - Tier 2 (label + ancestry)

    func testLabelSurvivesSmallPositionShift() {
        let stabilizer = RefStabilizer()
        let a = stabilizer.assign(assignment(
            role: .button, label: "OK",
            bounds: CGRect(x: 100, y: 100, width: 80, height: 30)
        ))
        stabilizer.commitSnapshot()
        // 15 px shift in both axes (well under grid granularity).
        let b = stabilizer.assign(assignment(
            role: .button, label: "OK",
            bounds: CGRect(x: 115, y: 115, width: 80, height: 30)
        ))
        XCTAssertEqual(a.index, b.index, "Label-tier refs are position-invariant.")
        XCTAssertEqual(stabilizer.identityTier(for: b), .label)
        XCTAssertEqual(stabilizer.stabilityScore(for: b), 0.75, accuracy: 0.0001)
    }

    func testLabelSurvivesMediumShift() {
        // 60 px shift — would cross a 50 px grid boundary in the old weak stabilizer,
        // but Tier 2 has no position component so ref stays stable.
        let stabilizer = RefStabilizer()
        let a = stabilizer.assign(assignment(
            role: .button, label: "Continue",
            bounds: CGRect(x: 200, y: 400, width: 100, height: 30)
        ))
        stabilizer.commitSnapshot()
        let b = stabilizer.assign(assignment(
            role: .button, label: "Continue",
            bounds: CGRect(x: 260, y: 460, width: 100, height: 30)
        ))
        XCTAssertEqual(a.index, b.index)
        XCTAssertEqual(stabilizer.identityTier(for: b), .label)
    }

    // MARK: - Duplicate labels

    func testDuplicateLabelSiblings_GetDistinctRefs() {
        // Two "Close" buttons inside different list items under the same sidebar.
        let stabilizer = RefStabilizer()
        let tree = ElementTreeFixtures.sidebarWithDuplicateCloseButtons()
        let flat = ElementTreeFixtures.flatten(tree, bundleID: "com.app")
        let refs = ElementTreeFixtures.assignRefs(flat, stabilizer: stabilizer)

        let closeRefs = zip(flat, refs).compactMap { el, ref -> ElementRef? in
            el.label == "Close" ? ref : nil
        }
        XCTAssertEqual(closeRefs.count, 2, "Fixture should produce two Close buttons.")
        XCTAssertNotEqual(closeRefs[0].index, closeRefs[1].index,
                          "Duplicate-label siblings must receive distinct refs.")

        // Snapshot rotation — refs must remain identical.
        stabilizer.commitSnapshot()
        let refs2 = ElementTreeFixtures.assignRefs(flat, stabilizer: stabilizer)
        let closeRefs2 = zip(flat, refs2).compactMap { el, ref -> ElementRef? in
            el.label == "Close" ? ref : nil
        }
        XCTAssertEqual(closeRefs[0].index, closeRefs2[0].index,
                       "First Close button must keep its ref across snapshots.")
        XCTAssertEqual(closeRefs[1].index, closeRefs2[1].index,
                       "Second Close button must keep its ref across snapshots.")
    }

    func testDuplicateLabelInDifferentContainers_GetDistinctRefs() {
        // "Save" in File menu vs "Save" button in toolbar. Different ancestry → different refs.
        let stabilizer = RefStabilizer()
        let tree = ElementTreeFixtures.windowWithFileMenuAndToolbarSave()
        let flat = ElementTreeFixtures.flatten(tree, bundleID: "com.app")
        let refs = ElementTreeFixtures.assignRefs(flat, stabilizer: stabilizer)

        let menuSave = zip(flat, refs).first { el, _ in
            el.role == .menuItem && el.label == "Save"
        }
        let toolbarSave = zip(flat, refs).first { el, _ in
            el.role == .button && el.label == "Save"
        }
        XCTAssertNotNil(menuSave, "Fixture should include a File > Save menu item.")
        XCTAssertNotNil(toolbarSave, "Fixture should include a toolbar Save button.")
        XCTAssertNotEqual(menuSave?.1.index, toolbarSave?.1.index,
                          "Same label in different containers must produce different refs.")

        // Both should be tier 2 (label), but their ancestry hashes differ.
        XCTAssertEqual(stabilizer.identityTier(for: menuSave!.1), .label)
        XCTAssertEqual(stabilizer.identityTier(for: toolbarSave!.1), .label)
    }

    // MARK: - Tier 3 (parent-anchored position)

    func testEmptyLabelElement_UsesParentAnchoredPosition() {
        // Snapshot 1: toolbar at origin (0, 24), 400×60 with 4 icon buttons.
        let stabilizer = RefStabilizer()
        let tree1 = ElementTreeFixtures.canvasAppWithIconButtons(
            parentOrigin: CGPoint(x: 0, y: 24),
            parentSize: CGSize(width: 400, height: 60)
        )
        let flat1 = ElementTreeFixtures.flatten(tree1, bundleID: "com.canvas")
        let refs1 = ElementTreeFixtures.assignRefs(flat1, stabilizer: stabilizer)

        let buttonRefs1 = zip(flat1, refs1).compactMap { el, ref -> ElementRef? in
            (el.role == .button && el.label.isEmpty) ? ref : nil
        }
        XCTAssertEqual(buttonRefs1.count, 4)
        // All icon buttons should be tier 3 (position) — no label, no identifier, have bounds.
        for ref in buttonRefs1 {
            XCTAssertEqual(stabilizer.identityTier(for: ref), .position,
                           "Icon buttons without labels/identifiers should use tier 3.")
        }
        stabilizer.commitSnapshot()

        // Snapshot 2: parent toolbar reflows — shifted 200 px right, 20 px taller.
        // Icon buttons keep the same RELATIVE position within the parent, so tier 3
        // anchored-bucket hash is unchanged.
        let tree2 = ElementTreeFixtures.canvasAppWithIconButtons(
            parentOrigin: CGPoint(x: 200, y: 44),
            parentSize: CGSize(width: 400, height: 60)
        )
        let flat2 = ElementTreeFixtures.flatten(tree2, bundleID: "com.canvas")
        let refs2 = ElementTreeFixtures.assignRefs(flat2, stabilizer: stabilizer)

        let buttonRefs2 = zip(flat2, refs2).compactMap { el, ref -> ElementRef? in
            (el.role == .button && el.label.isEmpty) ? ref : nil
        }
        XCTAssertEqual(buttonRefs1, buttonRefs2,
                       "Parent-anchored tier-3 icon refs must survive a 200 px parent shift.")
    }

    // MARK: - Add / remove stability

    func testElementRemoved_NewElementDoesNotStealRef() {
        // Snapshot 1: 5 buttons, record their refs.
        let stabilizer = RefStabilizer()
        let tree1 = ElementTreeFixtures.pageWithOptionalDialog(itemCount: 5, includeDialog: false)
        let flat1 = ElementTreeFixtures.flatten(tree1, bundleID: "com.app")
        let refs1 = ElementTreeFixtures.assignRefs(flat1, stabilizer: stabilizer)

        // Grab the ref of "Item 4" (the last one we'll remove).
        let item4Ref = zip(flat1, refs1).first { $0.0.label == "Item 4" }?.1
        XCTAssertNotNil(item4Ref)
        stabilizer.commitSnapshot()

        // Snapshot 2: "Item 4" removed and a wholly new "Settings" button added in its place.
        var tree2 = ElementTreeFixtures.pageWithOptionalDialog(itemCount: 4, includeDialog: false)
        tree2.children.append(ElementTreeFixtures.Tree(ElementTreeFixtures.FixtureNode(
            role: .button,
            label: "Settings",
            relativeOrigin: CGPoint(x: 20, y: 60 + 4 * 40),
            size: CGSize(width: 160, height: 30)
        )))
        let flat2 = ElementTreeFixtures.flatten(tree2, bundleID: "com.app")
        let refs2 = ElementTreeFixtures.assignRefs(flat2, stabilizer: stabilizer)

        let settingsRef = zip(flat2, refs2).first { $0.0.label == "Settings" }?.1
        XCTAssertNotNil(settingsRef)
        XCTAssertNotEqual(settingsRef?.index, item4Ref?.index,
                          "New element must not reuse the removed element's ref index.")

        // All surviving Item 0..3 refs must be unchanged.
        for i in 0..<4 {
            let before = zip(flat1, refs1).first { $0.0.label == "Item \(i)" }?.1
            let after = zip(flat2, refs2).first { $0.0.label == "Item \(i)" }?.1
            XCTAssertEqual(before?.index, after?.index, "Item \(i) ref must survive removal of Item 4.")
        }
    }

    func testElementAddedThenRemoved_OldRefsStable() {
        // Snapshot 1: plain page, no dialog.
        let stabilizer = RefStabilizer()
        let flat1 = ElementTreeFixtures.flatten(
            ElementTreeFixtures.pageWithOptionalDialog(itemCount: 5, includeDialog: false),
            bundleID: "com.app"
        )
        let refs1 = ElementTreeFixtures.assignRefs(flat1, stabilizer: stabilizer)
        stabilizer.commitSnapshot()

        // Snapshot 2: dialog opens on top — page items must keep their refs.
        let flat2 = ElementTreeFixtures.flatten(
            ElementTreeFixtures.pageWithOptionalDialog(itemCount: 5, includeDialog: true),
            bundleID: "com.app"
        )
        let refs2 = ElementTreeFixtures.assignRefs(flat2, stabilizer: stabilizer)
        stabilizer.commitSnapshot()

        for i in 0..<5 {
            let a = zip(flat1, refs1).first { $0.0.label == "Item \(i)" }?.1
            let b = zip(flat2, refs2).first { $0.0.label == "Item \(i)" }?.1
            XCTAssertEqual(a?.index, b?.index, "Item \(i) ref must survive dialog open.")
        }

        // Snapshot 3: dialog closes — still unchanged.
        let flat3 = ElementTreeFixtures.flatten(
            ElementTreeFixtures.pageWithOptionalDialog(itemCount: 5, includeDialog: false),
            bundleID: "com.app"
        )
        let refs3 = ElementTreeFixtures.assignRefs(flat3, stabilizer: stabilizer)
        for i in 0..<5 {
            let a = zip(flat1, refs1).first { $0.0.label == "Item \(i)" }?.1
            let c = zip(flat3, refs3).first { $0.0.label == "Item \(i)" }?.1
            XCTAssertEqual(a?.index, c?.index, "Item \(i) ref must survive dialog open+close.")
        }
    }

    // MARK: - Lifecycle

    func testReset_ClearsAllState() {
        let stabilizer = RefStabilizer()
        _ = stabilizer.assign(assignment(role: .button, label: "A", bounds: CGRect(x: 0, y: 0, width: 10, height: 10)))
        _ = stabilizer.assign(assignment(role: .button, label: "B", bounds: CGRect(x: 20, y: 0, width: 10, height: 10)))
        stabilizer.commitSnapshot()
        _ = stabilizer.assign(assignment(role: .button, label: "C", bounds: CGRect(x: 40, y: 0, width: 10, height: 10)))

        stabilizer.reset()

        // After reset, next assign gets index 1 (counter rebased) and introspection
        // returns nil for refs from the old epoch.
        let fresh = stabilizer.assign(assignment(role: .button, label: "A", bounds: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertEqual(fresh.index, 1, "reset() must rebase the index counter.")
        XCTAssertEqual(stabilizer.identityTier(for: fresh), .label)

        // Ref from before reset is orphaned (not in previous or current maps).
        let orphan = ElementRef(index: 999)
        XCTAssertNil(stabilizer.identityTier(for: orphan))
        XCTAssertEqual(stabilizer.stabilityScore(for: orphan), 0.0, accuracy: 0.0001)
    }

    // MARK: - Tier introspection

    func testStabilityScoreByTier() {
        let stabilizer = RefStabilizer()
        // Tier 1 — has identifier.
        let t1 = stabilizer.assign(assignment(
            role: .button, label: "Btn", identifier: "id-x",
            bounds: CGRect(x: 10, y: 10, width: 30, height: 20)
        ))
        // Tier 2 — no identifier, has label.
        let t2 = stabilizer.assign(assignment(
            role: .textField, label: "Email",
            bounds: CGRect(x: 50, y: 10, width: 200, height: 20)
        ))
        // Tier 3 — no identifier, no label, has bounds.
        let t3 = stabilizer.assign(assignment(
            role: .image, label: "",
            bounds: CGRect(x: 300, y: 10, width: 30, height: 30)
        ))
        // Tier 4 — no identifier, no label, no bounds.
        let t4 = stabilizer.assign(RefAssignment(
            bundleID: "com.app", role: .group, label: "", identifier: "",
            bounds: nil, parentBounds: nil,
            ancestryHash: AncestryHash.empty, depth: 0, siblingIndex: 0
        ))

        XCTAssertEqual(stabilizer.stabilityScore(for: t1), 1.0, accuracy: 0.0001)
        XCTAssertEqual(stabilizer.stabilityScore(for: t2), 0.75, accuracy: 0.0001)
        XCTAssertEqual(stabilizer.stabilityScore(for: t3), 0.5, accuracy: 0.0001)
        XCTAssertEqual(stabilizer.stabilityScore(for: t4), 0.2, accuracy: 0.0001)
    }

    func testIdentityTierIntrospection() {
        let stabilizer = RefStabilizer()
        let withID = stabilizer.assign(assignment(
            role: .button, label: "X", identifier: "btn-1",
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10)
        ))
        let withLabel = stabilizer.assign(assignment(
            role: .button, label: "Label Only",
            bounds: CGRect(x: 20, y: 0, width: 80, height: 10)
        ))
        let withBoundsOnly = stabilizer.assign(assignment(
            role: .image, label: "",
            bounds: CGRect(x: 110, y: 0, width: 20, height: 20)
        ))
        let withNothing = stabilizer.assign(RefAssignment(
            bundleID: "com.app", role: .group, label: "", identifier: "",
            bounds: nil, parentBounds: nil,
            ancestryHash: AncestryHash.empty, depth: 0, siblingIndex: 0
        ))

        XCTAssertEqual(stabilizer.identityTier(for: withID), .identifier)
        XCTAssertEqual(stabilizer.identityTier(for: withLabel), .label)
        XCTAssertEqual(stabilizer.identityTier(for: withBoundsOnly), .position)
        XCTAssertEqual(stabilizer.identityTier(for: withNothing), .fallback)

        // Survives a commit (introspection reads from previous state too).
        stabilizer.commitSnapshot()
        XCTAssertEqual(stabilizer.identityTier(for: withID), .identifier,
                       "Tier metadata must survive commitSnapshot.")
    }

    // MARK: - Concurrency

    func testConcurrentAssignIsSafe() {
        let stabilizer = RefStabilizer()
        let queue = DispatchQueue(label: "ref-stabilizer-test", attributes: .concurrent)
        let group = DispatchGroup()
        let count = 100
        let collectedRefs = ConcurrentRefCollector()

        for i in 0..<count {
            queue.async(group: group) {
                let ref = stabilizer.assign(self.assignment(
                    role: .button,
                    label: "B\(i)",
                    bounds: CGRect(x: CGFloat(i % 10) * 50, y: CGFloat(i / 10) * 50, width: 40, height: 20)
                ))
                collectedRefs.append(ref)
            }
        }
        group.wait()

        let refs = collectedRefs.snapshot()
        XCTAssertEqual(refs.count, count, "All concurrent assigns must complete.")
        XCTAssertEqual(Set(refs.map { $0.index }).count, count,
                       "Every distinct-label assign must yield a distinct ref under concurrency.")
    }

    // MARK: - Ancestry hash

    func testAncestryHashDeterminism() {
        let chainA: [(role: ElementRole, label: String)] = [
            (.window, "Main"), (.toolbar, "Top"), (.group, "Left")
        ]
        let chainA_again: [(role: ElementRole, label: String)] = [
            (.window, "Main"), (.toolbar, "Top"), (.group, "Left")
        ]
        let chainB: [(role: ElementRole, label: String)] = [
            (.window, "Main"), (.toolbar, "Top"), (.group, "Right")
        ]
        let chainC: [(role: ElementRole, label: String)] = [
            (.window, "Main"), (.toolbar, "Bottom"), (.group, "Left")
        ]

        XCTAssertEqual(AncestryHash.compute(from: chainA), AncestryHash.compute(from: chainA_again),
                       "Same chain must yield same hash.")
        XCTAssertNotEqual(AncestryHash.compute(from: chainA), AncestryHash.compute(from: chainB),
                          "Different labels at same depth must yield different hashes.")
        XCTAssertNotEqual(AncestryHash.compute(from: chainA), AncestryHash.compute(from: chainC),
                          "Different labels at intermediate depth must yield different hashes.")

        // Empty chain is the documented sentinel.
        XCTAssertEqual(AncestryHash.compute(from: []), AncestryHash.empty)

        // Order matters — same labels reversed must hash differently.
        let reversed = Array(chainA.reversed())
        XCTAssertNotEqual(AncestryHash.compute(from: chainA), AncestryHash.compute(from: reversed),
                          "Ancestry order is significant (child vs. parent).")

        // Truncation: beyond maxDepth the earliest ancestors are dropped.
        let long1 = (0..<10).map { (role: ElementRole.group, label: "L\($0)") }
        let long2 = (0..<10).map { (role: ElementRole.group, label: "DIFF_\($0 > 3 ? "same" : "diff")_\($0)") }
        // Truncation keeps the last 6 — test by keeping the last 6 identical:
        let tail: [(role: ElementRole, label: String)] = [
            (.group, "tail1"), (.group, "tail2"), (.group, "tail3"),
            (.group, "tail4"), (.group, "tail5"), (.group, "tail6"),
        ]
        let withRootA: [(role: ElementRole, label: String)] = [(.window, "A")] + tail
        let withRootB: [(role: ElementRole, label: String)] = [(.window, "B")] + tail
        // Both have 7 entries (1 + 6). Truncation keeps the last 6 (all tail entries),
        // so the root differs but the hash is the same.
        XCTAssertEqual(AncestryHash.compute(from: withRootA), AncestryHash.compute(from: withRootB),
                       "Entries beyond maxDepth are dropped.")
        _ = long1
        _ = long2
    }

    // MARK: - Tier 4 (explicit instability contract)

    func testLargeReflow_500pxShift_RefChangesForTier4Only() {
        // This test documents the explicit instability contract for the weakest tiers:
        //   - Tier 2 (label)      — ref is INVARIANT under large reflows.
        //   - Tier 3 (position)   — ref is INVARIANT when parent reflows and the child
        //                           keeps the same relative bucket (covered by the
        //                           testEmptyLabelElement_UsesParentAnchoredPosition case).
        //   - Tier 4 (fallback)   — ref CHANGES under large reflows. Documented.
        //
        // Tier 4 is reached when there is no identifier, no label, and either no bounds
        // or a tier-3 collision. We exercise the "no bounds" path because it's the most
        // common production shape (deeply-nested empty containers whose AX attributes
        // come back as nil).
        let stabilizer = RefStabilizer()

        // Anchor scenario: a tier-4 element at depth 2, sibling index 0.
        let beforeFallback = stabilizer.assign(RefAssignment(
            bundleID: "com.app", role: .unknown, label: "", identifier: "",
            bounds: nil, parentBounds: nil,
            ancestryHash: AncestryHash.empty, depth: 2, siblingIndex: 0
        ))
        XCTAssertEqual(stabilizer.identityTier(for: beforeFallback), .fallback,
                       "Unknown-role element with no signals must route to tier 4.")
        stabilizer.commitSnapshot()

        // Same element, still tier 4 with same (depth, siblingIndex) → same ref.
        let stillStable = stabilizer.assign(RefAssignment(
            bundleID: "com.app", role: .unknown, label: "", identifier: "",
            bounds: nil, parentBounds: nil,
            ancestryHash: AncestryHash.empty, depth: 2, siblingIndex: 0
        ))
        XCTAssertEqual(beforeFallback.index, stillStable.index,
                       "Tier 4 is stable when its (depth, sibling) signals are unchanged.")
        stabilizer.commitSnapshot()

        // Now something in the tree restructures — the element's depth changes (parent
        // moved under a new container). This is the "large reflow" a tier-4 element
        // cannot survive by design.
        let afterRestructure = stabilizer.assign(RefAssignment(
            bundleID: "com.app", role: .unknown, label: "", identifier: "",
            bounds: nil, parentBounds: nil,
            ancestryHash: AncestryHash.empty, depth: 5, siblingIndex: 0
        ))
        XCTAssertNotEqual(beforeFallback.index, afterRestructure.index,
                          "Tier 4 is expressly unstable across structural reflows — contract documented.")
        XCTAssertEqual(stabilizer.identityTier(for: afterRestructure), .fallback)

        // Also demonstrate: an element with bounds and no label/identifier routes to
        // tier 3 (position), which ALSO breaks under a 500 px absolute shift when there
        // are no parent bounds to anchor against.
        let stabilizer2 = RefStabilizer()
        let posBefore = stabilizer2.assign(RefAssignment(
            bundleID: "com.app", role: .image, label: "", identifier: "",
            bounds: CGRect(x: 100, y: 100, width: 10, height: 10),
            parentBounds: nil,
            ancestryHash: AncestryHash.empty, depth: 0, siblingIndex: 0
        ))
        XCTAssertEqual(stabilizer2.identityTier(for: posBefore), .position)
        stabilizer2.commitSnapshot()
        let posAfter = stabilizer2.assign(RefAssignment(
            bundleID: "com.app", role: .image, label: "", identifier: "",
            bounds: CGRect(x: 600, y: 600, width: 10, height: 10),
            parentBounds: nil,
            ancestryHash: AncestryHash.empty, depth: 0, siblingIndex: 0
        ))
        XCTAssertNotEqual(posBefore.index, posAfter.index,
                          "Tier 3 with no parent bounds falls back to screen buckets — breaks on 500 px shift.")

        // CONTRAST: a tier-2 labeled element at the same 500 px shift STAYS stable.
        let stabilizer3 = RefStabilizer()
        let labeledBefore = stabilizer3.assign(assignment(
            role: .button, label: "Anchor",
            bounds: CGRect(x: 100, y: 100, width: 40, height: 20)
        ))
        stabilizer3.commitSnapshot()
        let labeledAfter = stabilizer3.assign(assignment(
            role: .button, label: "Anchor",
            bounds: CGRect(x: 600, y: 600, width: 40, height: 20)
        ))
        XCTAssertEqual(labeledBefore.index, labeledAfter.index,
                       "Tier 2 (label) is INVARIANT under 500 px shifts — the whole point of Rank 4.")
    }

    // MARK: - Helpers

    private func assignment(
        role: ElementRole,
        label: String,
        identifier: String = "",
        bounds: CGRect,
        ancestryHash: UInt64 = AncestryHash.empty,
        parentBounds: CGRect? = nil,
        depth: Int = 0,
        siblingIndex: Int = 0,
        bundleID: String = "com.app",
        domSelector: String? = nil,
        menuPath: [String]? = nil,
        visualDHash: UInt64? = nil,
        visualText: String? = nil,
        visualGridBucket: RefAssignment.VisualGridBucket? = nil
    ) -> RefAssignment {
        RefAssignment(
            bundleID: bundleID,
            role: role,
            label: label,
            identifier: identifier,
            bounds: bounds,
            parentBounds: parentBounds,
            ancestryHash: ancestryHash,
            depth: depth,
            siblingIndex: siblingIndex,
            domSelector: domSelector,
            menuPath: menuPath,
            visualDHash: visualDHash,
            visualText: visualText,
            visualGridBucket: visualGridBucket
        )
    }

    // MARK: - Phase C: new tiers (dom, menu, visual)

    func testDomTier_bodyRoundTrips() {
        let stabilizer = RefStabilizer()
        let ref = stabilizer.assign(assignment(
            role: .button, label: "Save",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 30),
            domSelector: "#save"
        ))
        XCTAssertEqual(stabilizer.identityTier(for: ref), .dom)
        XCTAssertEqual(stabilizer.stabilityScore(for: ref), 0.85, accuracy: 0.0001)
        let key = stabilizer.identityKey(for: ref) ?? ""
        XCTAssertTrue(key.hasPrefix("app=com.app|t2|dom=#save"), "got: \(key)")
    }

    func testMenuTier_bodyIncludesBase64URLPath() {
        let stabilizer = RefStabilizer()
        let ref = stabilizer.assign(assignment(
            role: .menuItem, label: "Save",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 22),
            menuPath: ["File", "Save"]
        ))
        XCTAssertEqual(stabilizer.identityTier(for: ref), .menu)
        let key = stabilizer.identityKey(for: ref) ?? ""
        XCTAssertTrue(key.hasPrefix("app=com.app|t3|menu="), "got: \(key)")
    }

    func testVisualTier_bodyHasSha1AndDHashAndGrid() {
        // Visual tier fires when all higher tiers (identifier, menu, dom,
        // label) are missing and a visualDHash is present. Pure-visual
        // elements (canvas icons with no AX label) are the target shape.
        let stabilizer = RefStabilizer()
        let ref = stabilizer.assign(assignment(
            role: .ocrButton, label: "",
            bounds: CGRect(x: 100, y: 50, width: 60, height: 24),
            visualDHash: 0xABCD1234_5678_9ABC,
            visualText: "Send",
            visualGridBucket: .init(x: 2, y: 1)
        ))
        XCTAssertEqual(stabilizer.identityTier(for: ref), .visual)
        let key = stabilizer.identityKey(for: ref) ?? ""
        XCTAssertTrue(key.contains("|t6|"), "got: \(key)")
        XCTAssertTrue(key.contains("dhash="), "got: \(key)")
        XCTAssertTrue(key.contains("grid=x2y1"), "got: \(key)")
        XCTAssertTrue(key.contains("ocr="), "got: \(key)")
    }

    func testCascadePrefersMenuOverDomOverLabel() {
        // Element carries menuPath + domSelector + label simultaneously —
        // cascade order is menu > dom > label. This locks the priority so
        // future changes surface in tests rather than silently.
        let stabilizer = RefStabilizer()
        let ref = stabilizer.assign(assignment(
            role: .menuItem, label: "Save",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 22),
            domSelector: "#save",
            menuPath: ["File", "Save"]
        ))
        XCTAssertEqual(stabilizer.identityTier(for: ref), .menu)
    }

    func testCascadePrefersDomOverLabel_whenMenuNil() {
        let stabilizer = RefStabilizer()
        let ref = stabilizer.assign(assignment(
            role: .button, label: "Save",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 30),
            domSelector: "#save"
        ))
        XCTAssertEqual(stabilizer.identityTier(for: ref), .dom)
    }

    func testCommitSnapshot_rebasesNextIndex_reclaimsUnusedIndices() {
        // Issue 5 refs, commit, then ensure next assign gets a low index
        // rather than climbing monotonically.
        let stabilizer = RefStabilizer()
        for i in 0..<5 {
            _ = stabilizer.assign(assignment(
                role: .button, label: "Btn\(i)",
                bounds: CGRect(x: CGFloat(i) * 100, y: 0, width: 80, height: 30)
            ))
        }
        stabilizer.commitSnapshot()
        let after = stabilizer.assign(assignment(
            role: .button, label: "Fresh",
            bounds: CGRect(x: 999, y: 999, width: 80, height: 30)
        ))
        // Previously this would have issued @e6 minimum; after the rebase
        // the counter wraps back to the max-issued+1 = 6, so @e6 is the
        // expected next index. The regression being guarded against is an
        // @e5000+ drift after thousands of snapshots.
        XCTAssertLessThanOrEqual(after.index, 6,
            "nextIndex rebase failed: got @e\(after.index), expected ≤ @e6")
    }

    func testResolveByKey_findsRefAcrossSnapshotBoundary() {
        let stabilizer = RefStabilizer()
        let ref = stabilizer.assign(assignment(
            role: .button, label: "Commit", identifier: "commit-btn",
            bounds: CGRect(x: 50, y: 50, width: 100, height: 30)
        ))
        let key = stabilizer.identityKey(for: ref)
        XCTAssertNotNil(key)
        stabilizer.commitSnapshot()
        // Re-assign an identical element in the new snapshot so `claim`
        // revives the previous index, then probe by key — resolve should
        // return the live ref.
        _ = stabilizer.assign(assignment(
            role: .button, label: "Commit", identifier: "commit-btn",
            bounds: CGRect(x: 50, y: 50, width: 100, height: 30)
        ))
        let resolved = stabilizer.resolve(key: key!)
        XCTAssertEqual(resolved, ref)
    }
}

// MARK: - Concurrency helper

/// Small NSLock-protected collector so the concurrency test can aggregate refs from
/// many queues without racing on the array.
private final class ConcurrentRefCollector: @unchecked Sendable {
    private var refs: [ElementRef] = []
    private let lock = NSLock()

    func append(_ ref: ElementRef) {
        lock.lock()
        refs.append(ref)
        lock.unlock()
    }

    func snapshot() -> [ElementRef] {
        lock.lock()
        defer { lock.unlock() }
        return refs
    }
}
