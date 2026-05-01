import XCTest
@testable import MetamorphiaPerception

final class ComputerTests: XCTestCase {

    func testElementRefParse() {
        let ref = ElementRef.parse("@e5")
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.index, 5)
        XCTAssertEqual(ref?.description, "@e5")
    }

    func testElementRefParseInvalid() {
        XCTAssertNil(ElementRef.parse("e5"))
        XCTAssertNil(ElementRef.parse("@x5"))
        XCTAssertNil(ElementRef.parse(""))
    }

    func testElementRoleMapping() {
        XCTAssertEqual(ElementRole.from(axRole: "AXButton"), .button)
        XCTAssertEqual(ElementRole.from(axRole: "AXTextField"), .textField)
        XCTAssertEqual(ElementRole.from(axRole: "AXUnknownThing"), .unknown)
    }

    func testElementRoleInteractive() {
        XCTAssertTrue(ElementRole.button.isInteractive)
        XCTAssertTrue(ElementRole.textField.isInteractive)
        XCTAssertTrue(ElementRole.link.isInteractive)
        XCTAssertFalse(ElementRole.staticText.isInteractive)
        XCTAssertFalse(ElementRole.group.isInteractive)
        XCTAssertFalse(ElementRole.window.isInteractive)
    }

    func testElementStateNames() {
        let state: ElementState = [.enabled, .focused]
        let names = state.names
        XCTAssertTrue(names.contains("enabled"))
        XCTAssertTrue(names.contains("focused"))
        XCTAssertFalse(names.contains("disabled"))
    }

    func testElementActionMapping() {
        XCTAssertEqual(ElementAction.from(axAction: "AXPress"), .press)
        XCTAssertEqual(ElementAction.from(axAction: "AXShowMenu"), .showMenu)
        XCTAssertNil(ElementAction.from(axAction: "AXUnknown"))
    }

    func testRefStabilizerConsistency() {
        let stabilizer = RefStabilizer()

        let ref1 = stabilizer.assign(makeAssignment(role: .button, label: "OK", bounds: CGRect(x: 100, y: 200, width: 80, height: 30)))
        let ref2 = stabilizer.assign(makeAssignment(role: .textField, label: "Name", bounds: CGRect(x: 300, y: 400, width: 80, height: 30)))

        // Different elements get different refs
        XCTAssertNotEqual(ref1.index, ref2.index)

        // After commit, same identity should get same ref
        stabilizer.commitSnapshot()
        let ref1Again = stabilizer.assign(makeAssignment(role: .button, label: "OK", bounds: CGRect(x: 100, y: 200, width: 80, height: 30)))
        XCTAssertEqual(ref1.index, ref1Again.index)
    }

    func testRefStabilizerCoarseGrid() {
        let stabilizer = RefStabilizer()

        // Same element, slightly different position. Label+ancestry (Tier 2) doesn't
        // care about position, so ref is stable regardless of grid.
        let ref1 = stabilizer.assign(makeAssignment(role: .button, label: "OK", bounds: CGRect(x: 100, y: 200, width: 80, height: 30)))
        stabilizer.commitSnapshot()
        let ref2 = stabilizer.assign(makeAssignment(role: .button, label: "OK", bounds: CGRect(x: 110, y: 210, width: 80, height: 30)))

        // Same identity → same ref
        XCTAssertEqual(ref1.index, ref2.index)
    }

    private func makeAssignment(
        role: ElementRole,
        label: String,
        bounds: CGRect,
        identifier: String = "",
        ancestryHash: UInt64 = AncestryHash.empty,
        siblingIndex: Int = 0
    ) -> RefAssignment {
        RefAssignment(
            bundleID: "com.app",
            role: role,
            label: label,
            identifier: identifier,
            bounds: bounds,
            parentBounds: nil,
            ancestryHash: ancestryHash,
            depth: 0,
            siblingIndex: siblingIndex
        )
    }

    func testSnapshotContentHash() {
        let el1 = makeElement(role: .button, label: "OK")
        let el2 = makeElement(role: .button, label: "Cancel")

        let hash1 = Snapshot.contentHash(of: [el1, el2])
        let hash2 = Snapshot.contentHash(of: [el1, el2])
        let hash3 = Snapshot.contentHash(of: [el2, el1]) // Different order

        XCTAssertEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
    }

    // MARK: - Phase 2: Change Detection

    func testDiffEmpty() {
        let map = makeScreenMap(elements: [
            makeElement(ref: 1, role: .button, label: "OK"),
            makeElement(ref: 2, role: .button, label: "Cancel"),
        ])
        let diff = ChangeDetector.diff(previous: map, current: map)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.summary, "No changes")
    }

    func testDiffAddedElements() {
        let map1 = makeScreenMap(elements: [
            makeElement(ref: 1, role: .button, label: "OK"),
        ])
        let map2 = makeScreenMap(elements: [
            makeElement(ref: 1, role: .button, label: "OK"),
            makeElement(ref: 2, role: .button, label: "Cancel"),
        ])
        let diff = ChangeDetector.diff(previous: map1, current: map2)
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertEqual(diff.added.first?.label, "Cancel")
        XCTAssertEqual(diff.removed.count, 0)
    }

    func testDiffRemovedElements() {
        let map1 = makeScreenMap(elements: [
            makeElement(ref: 1, role: .button, label: "OK"),
            makeElement(ref: 2, role: .button, label: "Cancel"),
        ])
        let map2 = makeScreenMap(elements: [
            makeElement(ref: 1, role: .button, label: "OK"),
        ])
        let diff = ChangeDetector.diff(previous: map1, current: map2)
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.removed.first?.label, "Cancel")
    }

    func testDiffChangedState() {
        let el1 = makeElement(ref: 1, role: .button, label: "OK", state: .enabled)
        let el2 = makeElement(ref: 1, role: .button, label: "OK", state: .disabled)
        let map1 = makeScreenMap(elements: [el1])
        let map2 = makeScreenMap(elements: [el2])
        let diff = ChangeDetector.diff(previous: map1, current: map2)
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.changed.count, 1)
        XCTAssertEqual(diff.changed.first?.field, "state")
    }

    func testDiffAppSwitch() {
        let map1 = makeScreenMap(elements: [], appName: "Safari", pid: 100)
        let map2 = makeScreenMap(elements: [], appName: "Finder", pid: 200)
        let diff = ChangeDetector.diff(previous: map1, current: map2)
        XCTAssertTrue(diff.appSwitched)
        XCTAssertEqual(diff.previousApp, "Safari")
        XCTAssertEqual(diff.currentApp, "Finder")
    }

    // MARK: - Phase 2: Danger Detection

    func testDangerDetectorSafe() {
        let el = makeElement(ref: 1, role: .button, label: "Submit")
        let context = DangerDetector.ScanContext(appBundleID: "com.example.app", windowTitle: "My App")
        let result = DangerDetector.classify(element: el, context: context)
        XCTAssertEqual(result.level, .caution) // submit is caution
    }

    func testDangerDetectorDangerous() {
        let el = makeElement(ref: 1, role: .button, label: "Delete Account")
        let context = DangerDetector.ScanContext(appBundleID: "com.example.app", windowTitle: "Settings")
        let result = DangerDetector.classify(element: el, context: context)
        XCTAssertEqual(result.level, .dangerous)
    }

    func testDangerDetectorElevatedContext() {
        let el = makeElement(ref: 1, role: .button, label: "Reset")
        let context = DangerDetector.ScanContext(appBundleID: "com.apple.systempreferences", windowTitle: "General")
        let result = DangerDetector.classify(element: el, context: context)
        XCTAssertEqual(result.level, .dangerous) // "reset" escalated in System Preferences
    }

    func testDangerDetectorNonInteractive() {
        let el = makeElement(ref: 1, role: .staticText, label: "Delete Account")
        let context = DangerDetector.ScanContext(appBundleID: nil, windowTitle: "")
        let results = DangerDetector.scan(elements: [el], context: context)
        XCTAssertTrue(results.isEmpty) // Static text is never dangerous
    }

    // MARK: - Phase 2: Sensitive Field Detection

    func testSensitiveFieldPassword() {
        let el = makeElement(ref: 1, role: .textField, label: "Password", state: .password)
        let result = SensitiveFieldDetector.classify(element: el, allElements: [el])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .password)
    }

    func testSensitiveFieldCreditCard() {
        let el = makeElement(ref: 1, role: .textField, label: "Card Number")
        let result = SensitiveFieldDetector.classify(element: el, allElements: [el])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .creditCard)
    }

    func testSensitiveFieldNearbyLabel() {
        let label = makeElement(ref: 1, role: .staticText, label: "Social Security Number", clickPoint: CGPoint(x: 100, y: 100))
        let field = makeElement(ref: 2, role: .textField, label: "", clickPoint: CGPoint(x: 200, y: 100))
        let result = SensitiveFieldDetector.classify(element: field, allElements: [label, field])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .ssn)
    }

    func testSensitiveRedaction() {
        XCTAssertEqual(SensitiveFieldDetector.redact("mypassword", type: .password), "••••••••")
        XCTAssertEqual(SensitiveFieldDetector.redact("4111111111111111", type: .creditCard), "••••-••••-••••-1111")
        XCTAssertEqual(SensitiveFieldDetector.redact("123-45-6789", type: .ssn), "•••-••-••••")
        XCTAssertEqual(SensitiveFieldDetector.redact("sk-abc123xyz", type: .apiKey), "sk-a••••••••")
    }

    func testLuhnValidation() {
        // 4111111111111111 is a valid Visa test number
        let el = makeElement(ref: 1, role: .textField, label: "card", value: "4111111111111111")
        let result = SensitiveFieldDetector.classify(element: el, allElements: [el])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .creditCard)
    }

    // MARK: - Phase 2: DHash

    func testDHashIdentical() {
        XCTAssertTrue(ChangeDetector.hasVisualChange(previousHash: 0, currentHash: 0) == false)
    }

    func testDHashDifferent() {
        XCTAssertTrue(ChangeDetector.hasVisualChange(previousHash: 0, currentHash: UInt64.max))
    }

    // MARK: - Phase 2: Diff Encoder

    func testDiffEncoderEmpty() {
        let diff = ChangeDetector.ScreenDiff(
            hasMajorChange: false, appSwitched: false,
            previousApp: nil, currentApp: nil,
            added: [], removed: [], changed: [],
            summary: "No changes"
        )
        let json = DiffEncoder.encode(diff)
        XCTAssertTrue(json.contains("\"changed\":false"))
        XCTAssertTrue(json.contains("No changes"))
    }

    func testDiffEncoderSSE() {
        let diff = ChangeDetector.ScreenDiff(
            hasMajorChange: false, appSwitched: true,
            previousApp: "Safari", currentApp: "Finder",
            added: [], removed: [], changed: [],
            summary: "App switched"
        )
        let sse = DiffEncoder.encodeSSE(diff)
        XCTAssertTrue(sse.hasPrefix("event: focus\n"))
        XCTAssertTrue(sse.contains("data: "))
        XCTAssertTrue(sse.hasSuffix("\n\n"))
    }

    // MARK: - Phase 3: Element Database

    func testElementDatabaseUpsertAndGet() {
        let db = ElementDatabase(inMemory: true)
        db.upsertElement(
            hash: "test_hash_1",
            appBundleID: "com.test.app",
            role: "button",
            label: "OK",
            confidence: 0.5
        )
        let record = db.getElement(hash: "test_hash_1")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.label, "OK")
        XCTAssertEqual(record?.role, "button")
        XCTAssertEqual(record?.appBundleID, "com.test.app")
        XCTAssertEqual(record?.timesSeen, 1)
    }

    func testElementDatabaseConfidenceScoring() {
        let db = ElementDatabase(inMemory: true)
        db.upsertElement(hash: "conf_test", appBundleID: nil, role: "button", label: "Test", confidence: 0.5)

        // Correct match: conf = 0.5 + (1-0.5)*0.1 = 0.55
        db.recordCorrectMatch(hash: "conf_test")
        var record = db.getElement(hash: "conf_test")
        XCTAssertNotNil(record)
        XCTAssertEqual(record!.confidence, 0.55, accuracy: 0.01)

        // Wrong match: conf = 0.55 * 0.8 = 0.44
        db.recordWrongMatch(hash: "conf_test")
        record = db.getElement(hash: "conf_test")
        XCTAssertEqual(record!.confidence, 0.44, accuracy: 0.01)
    }

    func testElementDatabaseStats() {
        let db = ElementDatabase(inMemory: true)
        db.upsertElement(hash: "a", appBundleID: nil, role: "button", label: "A")
        db.upsertElement(hash: "b", appBundleID: nil, role: "button", label: "B")
        let stats = db.stats()
        XCTAssertEqual(stats.elementCount, 2)
        XCTAssertEqual(stats.patternCount, 0)
    }

    func testElementDatabaseCorrections() {
        let db = ElementDatabase(inMemory: true)
        db.insertCorrection(
            elementHash: "hash1",
            expectedLabel: "Settings",
            actualLabel: "Share",
            appBundleID: "com.test",
            windowContext: "Main",
            intendedAction: "click settings",
            selectedSignature: "sig_share",
            correctSignature: "sig_settings"
        )
        let corrections = db.recentCorrections(appBundleID: "com.test")
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.actualLabel, "Share")
        XCTAssertEqual(corrections.first?.expectedLabel, "Settings")
    }

    func testElementDatabaseWorkflows() {
        let db = ElementDatabase(inMemory: true)
        db.saveWorkflow(id: "wf1", name: "Test Workflow", appBundleID: "com.test", stepsJSON: "[{\"step\":1}]")
        let wf = db.getWorkflow(id: "wf1")
        XCTAssertNotNil(wf)
        XCTAssertEqual(wf?.name, "Test Workflow")
        XCTAssertEqual(wf?.timesReplayed, 0)

        db.recordReplay(workflowID: "wf1", success: true)
        let updated = db.getWorkflow(id: "wf1")
        XCTAssertEqual(updated?.timesReplayed, 1)
        XCTAssertEqual(updated?.successCount, 1)
    }

    func testElementDatabaseAppProfiles() {
        let db = ElementDatabase(inMemory: true)
        let profile = AppProfileRecord(
            bundleID: "com.test.app", appName: "TestApp", appVersion: "1.0",
            needsOCR: false, axCoveragePct: 0.95,
            elementCountAvg: 50, interactiveCountAvg: 20,
            structuralHash: "abc123", roleDistributionJSON: nil,
            toolbarSignature: nil, menuBarItemsJSON: nil,
            customRolesJSON: nil, elementAliasesJSON: nil,
            lastProfiled: Date(), profiledBy: "auto", profileVersion: 1
        )
        db.saveAppProfile(profile)
        let retrieved = db.getAppProfile(bundleID: "com.test.app")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.appName, "TestApp")
        XCTAssertEqual(retrieved?.elementCountAvg, 50)
    }

    // MARK: - Phase 3: Unknown Element Handler

    func testUnknownElementMissingLabel() {
        let el = makeElement(ref: 1, role: .button, label: "")
        let trigger = UnknownElementHandler.evaluate(el)
        XCTAssertEqual(trigger, .missingLabel)
    }

    func testUnknownElementKnownElement() {
        let el = makeElement(ref: 1, role: .button, label: "OK")
        let trigger = UnknownElementHandler.evaluate(el)
        XCTAssertNil(trigger)
    }

    func testUnknownElementLowConfidence() {
        let el = ScreenElement(
            ref: ElementRef(index: 1), role: .button, subrole: "",
            label: "mystery", value: "", bounds: nil, clickPoint: nil,
            state: .enabled, actions: [], parentRef: nil, depth: 0,
            source: .accessibility, confidence: 0.2,
            appBundleID: nil, windowIndex: 0
        )
        let trigger = UnknownElementHandler.evaluate(el)
        XCTAssertEqual(trigger, .lowConfidence)
    }

    // MARK: - Phase 3: Pattern Recognizer

    func testStructuralSignature() {
        let sig = PatternRecognizer.structuralSignature(
            role: "AXButton", parentRole: "AXToolbar", depth: 2, label: "Back"
        )
        XCTAssertEqual(sig, "AXButton/AXToolbar@2#back")
    }

    func testConfusionPatternExtraction() {
        let db = ElementDatabase(inMemory: true)
        // Insert 3 identical corrections to create a confusion pattern
        for _ in 0..<3 {
            db.insertCorrection(
                elementHash: nil, expectedLabel: "Settings", actualLabel: "Share",
                appBundleID: "com.test", windowContext: nil,
                intendedAction: nil, selectedSignature: "sig_share", correctSignature: "sig_settings"
            )
        }
        let patterns = PatternRecognizer.extractConfusionPatterns(appBundleID: "com.test", db: db)
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns.first?.frequency, 3)
        XCTAssertEqual(patterns.first?.wrongSignature, "sig_share")
        XCTAssertEqual(patterns.first?.correctSignature, "sig_settings")
    }

    // MARK: - Phase 3: Drift Detector

    func testDriftDetectorNoDrift() {
        let profile = AppProfileRecord(
            bundleID: "com.test", appName: "Test", appVersion: "1.0",
            needsOCR: false, axCoveragePct: 1.0,
            elementCountAvg: 10, interactiveCountAvg: 5,
            structuralHash: nil, roleDistributionJSON: nil,
            toolbarSignature: nil, menuBarItemsJSON: nil,
            customRolesJSON: nil, elementAliasesJSON: nil,
            lastProfiled: Date(), profiledBy: "auto", profileVersion: 1
        )
        let map = makeScreenMap(elements: Array(0..<10).map {
            makeElement(ref: $0, role: .button, label: "Button \($0)")
        })
        let report = DriftDetector.detect(currentMap: map, storedProfile: profile)
        XCTAssertEqual(report.severity, .none)
    }

    func testDriftDetectorMajorDrift() {
        let profile = AppProfileRecord(
            bundleID: "com.test", appName: "Test", appVersion: "1.0",
            needsOCR: false, axCoveragePct: 1.0,
            elementCountAvg: 50, interactiveCountAvg: 30,
            structuralHash: "old_hash", roleDistributionJSON: nil,
            toolbarSignature: nil, menuBarItemsJSON: nil,
            customRolesJSON: nil, elementAliasesJSON: nil,
            lastProfiled: Date(), profiledBy: "auto", profileVersion: 1
        )
        // Current has only 10 elements (was 50) — major drift
        let map = makeScreenMap(elements: Array(0..<10).map {
            makeElement(ref: $0, role: .button, label: "Button \($0)")
        })
        let report = DriftDetector.detect(currentMap: map, storedProfile: profile)
        XCTAssertTrue(report.severity >= .major)
    }

    // MARK: - Phase 4: Disambiguator

    func testDisambiguatorSingleMatch() {
        let el = makeElement(ref: 1, role: .button, label: "Submit")
        let map = makeScreenMap(elements: [el])
        let results = Disambiguator.disambiguate(label: "Submit", in: map)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.element.ref.index, 1)
    }

    func testDisambiguatorMultipleMatches() {
        let el1 = makeElement(ref: 1, role: .button, label: "Submit", state: .enabled, clickPoint: CGPoint(x: 100, y: 100))
        let el2 = makeElement(ref: 2, role: .button, label: "Submit", state: .disabled, clickPoint: CGPoint(x: 500, y: 500))
        let map = makeScreenMap(elements: [el1, el2])
        let results = Disambiguator.disambiguate(label: "Submit", in: map)
        XCTAssertEqual(results.count, 2)
        // Enabled element should rank higher
        XCTAssertEqual(results.first?.element.ref.index, 1)
        XCTAssertTrue(results[0].score > results[1].score)
    }

    func testDisambiguatorNoMatch() {
        let el = makeElement(ref: 1, role: .button, label: "Cancel")
        let map = makeScreenMap(elements: [el])
        let results = Disambiguator.disambiguate(label: "Submit", in: map)
        XCTAssertTrue(results.isEmpty)
    }

    func testDisambiguatorFindByRef() {
        let el = makeElement(ref: 5, role: .button, label: "OK")
        let map = makeScreenMap(elements: [el])
        let found = Disambiguator.findByRef("@e5", in: map)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.label, "OK")
    }

    // MARK: - Phase 4: UndoAdvisor

    func testReversibilityToggle() {
        let el = makeElement(ref: 1, role: .checkbox, label: "Enable notifications")
        let map = makeScreenMap(elements: [el])
        let assessment = UndoAdvisor.assessReversibility(element: el, map: map)
        XCTAssertTrue(assessment.isReversible)
        XCTAssertNotNil(assessment.reversalMethod)
        XCTAssertTrue(assessment.confidence > 0.9)
    }

    func testReversibilityDelete() {
        let el = makeElement(ref: 1, role: .button, label: "Delete Account")
        let map = makeScreenMap(elements: [el])
        let assessment = UndoAdvisor.assessReversibility(element: el, map: map)
        XCTAssertFalse(assessment.isReversible)
    }

    func testReversibilityTextField() {
        let el = makeElement(ref: 1, role: .textField, label: "Name")
        let map = makeScreenMap(elements: [el])
        let assessment = UndoAdvisor.assessReversibility(element: el, map: map)
        XCTAssertTrue(assessment.isReversible)
        XCTAssertEqual(assessment.reversalMethod, "⌘Z to undo")
    }

    // MARK: - Phase 4: ActionSuggester

    func testActionSuggesterExactMatch() {
        let el = makeElement(ref: 1, role: .button, label: "Save")
        let map = makeScreenMap(elements: [el])
        let plan = ActionSuggester.suggest(goal: "save", in: map)
        XCTAssertFalse(plan.steps.isEmpty)
        XCTAssertEqual(plan.steps.first?.element.ref.index, 1)
        XCTAssertTrue(plan.confidence > 0.5)
    }

    func testActionSuggesterWordMatch() {
        let el1 = makeElement(ref: 1, role: .button, label: "Send Email")
        let el2 = makeElement(ref: 2, role: .button, label: "Cancel")
        let map = makeScreenMap(elements: [el1, el2])
        let plan = ActionSuggester.suggest(goal: "send the email", in: map)
        XCTAssertFalse(plan.steps.isEmpty)
        XCTAssertEqual(plan.steps.first?.element.ref.index, 1)
    }

    func testActionSuggesterNoMatch() {
        let el = makeElement(ref: 1, role: .button, label: "OK")
        let map = makeScreenMap(elements: [el])
        let plan = ActionSuggester.suggest(goal: "delete everything", in: map)
        XCTAssertTrue(plan.steps.isEmpty || plan.confidence < 0.3)
    }

    func testActionPlanFormat() {
        let el = makeElement(ref: 1, role: .button, label: "Save")
        let map = makeScreenMap(elements: [el])
        let plan = ActionSuggester.suggest(goal: "save the file", in: map)
        let formatted = ActionSuggester.formatPlan(plan)
        XCTAssertTrue(formatted.contains("Goal: save the file"))
        XCTAssertTrue(formatted.contains("Confidence:"))
    }

    // MARK: - Browser DOM Capture (Phase: full HTML perception)

    func testBrowserDOMCaptureConstruction() {
        let capture = BrowserDOMCapture(
            url: "https://example.com",
            title: "Example Domain",
            html: "<html><body>hello</body></html>",
            fetchedAt: Date(),
            source: .safariAppleScript
        )
        XCTAssertEqual(capture.url, "https://example.com")
        XCTAssertEqual(capture.title, "Example Domain")
        XCTAssertTrue(capture.html.contains("hello"))
        XCTAssertEqual(capture.source, .safariAppleScript)
    }

    func testScreenMapOptionalBrowserDOM() {
        // Backwards-compat: ScreenMap without browserDOM is still constructable.
        let el = makeElement(ref: 1, role: .button, label: "Save")
        let mapWithout = makeScreenMap(elements: [el])
        XCTAssertNil(mapWithout.browserDOM)

        // And a new map can carry a full DOM.
        let dom = BrowserDOMCapture(
            url: "https://x.com",
            title: "x",
            html: "<html></html>",
            fetchedAt: Date(),
            source: .chromeCDP
        )
        let mapWith = ScreenMap(
            timestamp: mapWithout.timestamp,
            captureMs: mapWithout.captureMs,
            display: mapWithout.display,
            focusedApp: mapWithout.focusedApp,
            windows: mapWithout.windows,
            elements: mapWithout.elements,
            navigation: mapWithout.navigation,
            safety: mapWithout.safety,
            metadata: mapWithout.metadata,
            browserDOM: dom
        )
        XCTAssertNotNil(mapWith.browserDOM)
        XCTAssertEqual(mapWith.browserDOM?.source, .chromeCDP)
    }

    func testSnapshotEncoderIncludesDOM() {
        let el = makeElement(ref: 1, role: .button, label: "Go")
        let baseMap = makeScreenMap(elements: [el])
        let dom = BrowserDOMCapture(
            url: "https://test.local",
            title: "T",
            html: "<p>hi</p>",
            fetchedAt: Date(),
            source: .chromeCDP
        )
        let map = ScreenMap(
            timestamp: baseMap.timestamp, captureMs: baseMap.captureMs,
            display: baseMap.display, focusedApp: baseMap.focusedApp,
            windows: baseMap.windows, elements: baseMap.elements,
            navigation: baseMap.navigation, safety: baseMap.safety,
            metadata: baseMap.metadata, browserDOM: dom
        )
        let json = SnapshotEncoder.encode(map)
        XCTAssertTrue(json.contains("\"v\":2"), "schema version should be 2")
        XCTAssertTrue(json.contains("\"dom\""), "dom field should be serialized")
        XCTAssertTrue(json.contains("\"url\":\"https:\\/\\/test.local\""))
        XCTAssertTrue(json.contains("\"src\":\"chrome-cdp\""))
    }

    func testTextFormatterCompactDOMLine() {
        // TextFormatter must emit ONLY a compact summary line, never the full HTML.
        // This is the invariant that keeps Claude tokens flat.
        let el = makeElement(ref: 1, role: .button, label: "Go")
        let baseMap = makeScreenMap(elements: [el])
        let longHTML = String(repeating: "<div>x</div>", count: 5000)
        let dom = BrowserDOMCapture(
            url: "https://safari.local",
            title: "Safari Page",
            html: longHTML,
            fetchedAt: Date(),
            source: .safariAppleScript
        )
        let map = ScreenMap(
            timestamp: baseMap.timestamp, captureMs: baseMap.captureMs,
            display: baseMap.display, focusedApp: baseMap.focusedApp,
            windows: baseMap.windows, elements: baseMap.elements,
            navigation: baseMap.navigation, safety: baseMap.safety,
            metadata: baseMap.metadata, browserDOM: dom
        )
        let text = TextFormatter.format(map)
        XCTAssertTrue(text.contains("DOM: https://safari.local"))
        XCTAssertTrue(text.contains("Safari Page"))
        XCTAssertTrue(text.contains("safari-as"))
        XCTAssertFalse(text.contains("<div>x</div>"), "full HTML must NOT leak into LLM text")
    }

    // MARK: - PerceptionLoop

    func testPerceptionLoopStartStopLifecycle() async {
        // Smoke test: start and stop without errors. Does not exercise the capture
        // path (which requires a real macOS window) but verifies the actor lifecycle.
        let loop = PerceptionLoop()
        await loop.start(targetHz: 5.0)
        await loop.stop()
        // Second start should be a no-op (and not crash)
        await loop.start(targetHz: 5.0)
        await loop.stop()
    }

    func testPerceptionLoopObserveReturnsStream() async {
        // The observe() method should return an AsyncStream that can be subscribed
        // to and cancelled cleanly without hanging.
        let loop = PerceptionLoop()
        let stream = loop.observe()
        var iterator = stream.makeAsyncIterator()
        // Cancel iterator immediately — nothing has been yielded, so next() should
        // block. We terminate via a timeout task.
        let pollTask = Task<ScreenMap?, Never> {
            await iterator.next()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        pollTask.cancel()
        // No assertion needed — the test passes if we reach this point without hanging.
    }

    // MARK: - Menu Bar Reader (non-screenshot path)

    func testMenuItemConstruction() {
        let item = MenuItem(
            title: "Export As…",
            path: ["File", "Export As…"],
            shortcut: "cmd+shift+e",
            enabled: true,
            hasSubmenu: true
        )
        XCTAssertEqual(item.title, "Export As…")
        XCTAssertEqual(item.path, ["File", "Export As…"])
        XCTAssertEqual(item.shortcut, "cmd+shift+e")
        XCTAssertTrue(item.enabled)
        XCTAssertTrue(item.hasSubmenu)
    }

    func testScreenMapDefaultEmptyMenus() {
        // Backwards-compat: legacy ScreenMap constructions omit the menus arg.
        let el = makeElement(ref: 1, role: .button, label: "Save")
        let map = makeScreenMap(elements: [el])
        XCTAssertTrue(map.menus.isEmpty)
    }

    func testSnapshotEncoderIncludesMenus() {
        let el = makeElement(ref: 1, role: .button, label: "Go")
        let baseMap = makeScreenMap(elements: [el])
        let menus = [
            MenuItem(title: "New",    path: ["File", "New"],    shortcut: "cmd+n",       enabled: true,  hasSubmenu: false),
            MenuItem(title: "Save",   path: ["File", "Save"],   shortcut: "cmd+s",       enabled: true,  hasSubmenu: false),
            MenuItem(title: "Export", path: ["File", "Export"], shortcut: nil,           enabled: true,  hasSubmenu: true),
            MenuItem(title: "glTF",   path: ["File", "Export", "glTF"], shortcut: nil,   enabled: false, hasSubmenu: false),
        ]
        let map = ScreenMap(
            timestamp: baseMap.timestamp, captureMs: baseMap.captureMs,
            display: baseMap.display, focusedApp: baseMap.focusedApp,
            windows: baseMap.windows, elements: baseMap.elements,
            navigation: baseMap.navigation, safety: baseMap.safety,
            metadata: baseMap.metadata, menus: menus
        )
        let json = SnapshotEncoder.encode(map)
        XCTAssertTrue(json.contains("\"menus\""), "menus field should be serialized")
        XCTAssertTrue(json.contains("\"Save\""), "menu titles should be serialized")
        XCTAssertTrue(json.contains("\"sc\":\"cmd+s\""), "shortcut should be serialized under 'sc'")
        XCTAssertTrue(json.contains("\"sub\":true"), "submenu flag should be serialized for container items")
        XCTAssertTrue(json.contains("\"enabled\":false"), "disabled state preserved")
    }

    func testTextFormatterEmitsCompactMenuSummary() {
        let el = makeElement(ref: 1, role: .button, label: "Go")
        let baseMap = makeScreenMap(elements: [el])
        let menus = [
            MenuItem(title: "New",  path: ["File", "New"],  shortcut: "cmd+n", enabled: true, hasSubmenu: false),
            MenuItem(title: "Undo", path: ["Edit", "Undo"], shortcut: "cmd+z", enabled: true, hasSubmenu: false),
            MenuItem(title: "Zoom", path: ["View", "Zoom"], shortcut: nil,     enabled: true, hasSubmenu: false),
        ]
        let map = ScreenMap(
            timestamp: baseMap.timestamp, captureMs: baseMap.captureMs,
            display: baseMap.display, focusedApp: baseMap.focusedApp,
            windows: baseMap.windows, elements: baseMap.elements,
            navigation: baseMap.navigation, safety: baseMap.safety,
            metadata: baseMap.metadata, menus: menus
        )
        let text = TextFormatter.format(map)
        XCTAssertTrue(text.contains("Menus:"))
        XCTAssertTrue(text.contains("(3 items total)"))
        // Compact summary must NOT include full titles for every item — that's reserved
        // for the local-model prompt, not for Claude.
        XCTAssertFalse(text.contains("cmd+n"), "TextFormatter should not dump individual shortcuts")
    }

    // MARK: - Helpers

    private func makeElement(
        ref: Int = 1,
        role: ElementRole,
        label: String,
        value: String = "",
        state: ElementState = .enabled,
        clickPoint: CGPoint? = nil
    ) -> ScreenElement {
        ScreenElement(
            ref: ElementRef(index: ref),
            role: role,
            subrole: "",
            label: label,
            value: value,
            bounds: clickPoint.map { CGRect(origin: $0, size: CGSize(width: 80, height: 30)) },
            clickPoint: clickPoint,
            state: state,
            actions: [],
            parentRef: nil,
            depth: 0,
            source: .accessibility,
            confidence: 1.0,
            appBundleID: nil,
            windowIndex: 0
        )
    }

    private func makeScreenMap(
        elements: [ScreenElement],
        appName: String = "TestApp",
        pid: Int32 = 1
    ) -> ScreenMap {
        ScreenMap(
            timestamp: Date(),
            captureMs: 10,
            display: DisplayInfo(id: 1, width: 1512, height: 982, scale: 2),
            focusedApp: AppInfo(name: appName, bundleID: "com.test.\(appName)", pid: pid),
            windows: [],
            elements: elements,
            navigation: nil,
            safety: .empty,
            metadata: CaptureMetadata(
                axCoveragePercent: 1.0, ocrUsed: false,
                elementCount: elements.count,
                interactiveCount: elements.filter { $0.role.isInteractive }.count,
                offScreenHint: nil
            )
        )
    }
}
