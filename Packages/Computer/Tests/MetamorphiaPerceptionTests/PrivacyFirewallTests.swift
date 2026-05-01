import XCTest
@testable import MetamorphiaPerception

final class PrivacyFirewallTests: XCTestCase {

    // MARK: - Helpers

    private func firewall() -> PrivacyFirewall { PrivacyFirewall() }

    private func candidate(
        bundleID: String? = "com.example.app",
        kind: String = "focusChanged",
        ocrText: String? = nil,
        axRoleHint: String? = nil,
        pixelMeanHint: Double? = nil,
        at: Date = Date()
    ) -> PrivacyFirewall.Candidate {
        .init(bundleID: bundleID, kind: kind, ocrText: ocrText,
              axRoleHint: axRoleHint, pixelMeanHint: pixelMeanHint, at: at)
    }

    // MARK: - Pause

    func testPauseBlocksAdmission() async {
        let fw = firewall()
        await fw.pause(for: 60)
        let (token, drop) = await fw.admit(lane: "test", candidate())
        XCTAssertNil(token)
        if case .denyUserPaused = drop { /* expected */ } else {
            XCTFail("Expected denyUserPaused, got \(drop)")
        }
    }

    func testUnpauseRestoresAdmission() async {
        let fw = firewall()
        await fw.pause(for: 60)
        await fw.unpause()
        let (token, drop) = await fw.admit(lane: "test", candidate())
        XCTAssertNotNil(token)
        XCTAssertEqual(drop, .ok)
    }

    func testPauseExpires() async throws {
        let fw = firewall()
        await fw.pause(for: 0.5)
        // Let it expire
        try await Task.sleep(nanoseconds: 800_000_000)
        let (token, drop) = await fw.admit(lane: "test", candidate())
        XCTAssertNotNil(token)
        XCTAssertEqual(drop, .ok)
    }

    // MARK: - App denylist

    func testBuiltinDenylistBlocks() async {
        let fw = firewall()
        let blocked = [
            "com.1password.1password",
            "com.1password.1password7",
            "com.agilebits.onepassword7",
            "com.bitwarden.desktop",
            "com.lastpass.LastPass",
            "com.lastpass.lastpassmacapp",
            "com.dashlane.dashlanephonefinal",
            "com.dashlane.dashlane-mac",
            "com.apple.Passwords",
            "org.keepassxc.keepassxc",
            "me.proton.pass",
        ]
        for bid in blocked {
            let (token, drop) = await fw.admit(lane: "test", candidate(bundleID: bid))
            XCTAssertNil(token, "Expected nil token for \(bid)")
            if case .denyAppDenylist(let id) = drop {
                XCTAssertEqual(id, bid)
            } else {
                XCTFail("Expected denyAppDenylist for \(bid), got \(drop)")
            }
        }
    }

    func testUserDenylistAddAndRemove() async {
        let fw = firewall()
        let bid = "com.example.blocked"
        await fw.denyBundle(bid)
        let (t1, d1) = await fw.admit(lane: "test", candidate(bundleID: bid))
        XCTAssertNil(t1)
        if case .denyAppDenylist = d1 { /* ok */ } else { XCTFail("Expected deny") }

        await fw.allowBundle(bid)
        let (t2, d2) = await fw.admit(lane: "test", candidate(bundleID: bid))
        XCTAssertNotNil(t2)
        XCTAssertEqual(d2, .ok)
    }

    func testIsBundleDenied() async {
        let fw = firewall()
        let isBuiltin = await fw.isBundleDenied("com.1password.1password")
        XCTAssertTrue(isBuiltin)
        let isFree = await fw.isBundleDenied("com.example.innocent")
        XCTAssertFalse(isFree)
    }

    // MARK: - DRM

    func testDRMRequiresBothSignals() async {
        let fw = firewall()
        // Dark frame alone — not a DRM bundle — should pass
        let (t1, d1) = await fw.admit(lane: "test", candidate(
            bundleID: "com.example.video", pixelMeanHint: 1.0))
        XCTAssertNotNil(t1)
        XCTAssertEqual(d1, .ok)

        // DRM bundle alone, bright frame — should pass
        let (t2, d2) = await fw.admit(lane: "test", candidate(
            bundleID: "com.apple.TVApp", pixelMeanHint: 120.0))
        XCTAssertNotNil(t2)
        XCTAssertEqual(d2, .ok)

        // Both signals — deny
        let (t3, d3) = await fw.admit(lane: "test", candidate(
            bundleID: "com.apple.TVApp", pixelMeanHint: 2.0))
        XCTAssertNil(t3)
        XCTAssertEqual(d3, .denyDRM)
    }

    func testDRMBundleAtExactThreshold() async {
        let fw = firewall()
        // pixelMean == 4.0 should NOT trigger (< 4.0 required)
        let (t, d) = await fw.admit(lane: "test", candidate(
            bundleID: "com.netflix.Netflix", pixelMeanHint: 4.0))
        XCTAssertNotNil(t)
        XCTAssertEqual(d, .ok)
    }

    // MARK: - Secure input

    func testSecureTextFieldHintDenied() async {
        let fw = firewall()
        let (token, drop) = await fw.admit(lane: "test", candidate(axRoleHint: "AXSecureTextField"))
        XCTAssertNil(token)
        XCTAssertEqual(drop, .denySecureInput)
    }

    // MARK: - PII classifier

    func testPIIPasswordContext() async {
        let fw = firewall()
        let texts = [
            "password: hunter2",
            "pwd: mysecret123",
            "passphrase: correct horse",
        ]
        for text in texts {
            let (token, drop) = await fw.admit(lane: "test", candidate(ocrText: text))
            XCTAssertNil(token, "Expected deny for: \(text)")
            if case .denyPII(let kind) = drop {
                XCTAssertEqual(kind, .password, "Expected .password for: \(text)")
            } else {
                XCTFail("Expected denyPII(.password) for '\(text)', got \(drop)")
            }
        }
    }

    func testPIICreditCardLuhnValid() async {
        let fw = firewall()
        // Visa test number — Luhn valid
        let (token, drop) = await fw.admit(lane: "test",
            candidate(ocrText: "card: 4532015112830366"))
        XCTAssertNil(token)
        if case .denyPII(let kind) = drop {
            XCTAssertEqual(kind, .creditCard)
        } else {
            XCTFail("Expected denyPII(.creditCard), got \(drop)")
        }
    }

    func testPIICreditCardLuhnInvalid() async {
        let fw = firewall()
        // Same digits but last digit off by 1 — Luhn invalid
        let (token, drop) = await fw.admit(lane: "test",
            candidate(ocrText: "4532015112830367"))
        XCTAssertNotNil(token, "Luhn-invalid sequence should not be flagged")
        XCTAssertEqual(drop, .ok)
    }

    func testPIISSNWithDashes() async {
        let fw = firewall()
        let (token, drop) = await fw.admit(lane: "test",
            candidate(ocrText: "SSN: 123-45-6789"))
        XCTAssertNil(token)
        if case .denyPII(let kind) = drop {
            XCTAssertEqual(kind, .ssn)
        } else {
            XCTFail("Expected denyPII(.ssn), got \(drop)")
        }
    }

    func testPIIAPIKeyOpenAI() async {
        let fw = firewall()
        let key = "sk-" + String(repeating: "a", count: 20)
        let (token, drop) = await fw.admit(lane: "test", candidate(ocrText: key))
        XCTAssertNil(token)
        if case .denyPII(let kind) = drop {
            XCTAssertEqual(kind, .apiKey)
        } else {
            XCTFail("Expected denyPII(.apiKey), got \(drop)")
        }
    }

    func testPIIAPIKeyAWSAccessKey() async {
        let fw = firewall()
        let key = "AKIA" + String(repeating: "A", count: 16)
        let (token, drop) = await fw.admit(lane: "test", candidate(ocrText: key))
        XCTAssertNil(token)
        if case .denyPII(.apiKey) = drop { /* ok */ } else {
            XCTFail("Expected denyPII(.apiKey), got \(drop)")
        }
    }

    func testPIIAPIKeyGitHub() async {
        let fw = firewall()
        let key = "ghp_" + String(repeating: "x", count: 36)
        let (token, drop) = await fw.admit(lane: "test", candidate(ocrText: key))
        XCTAssertNil(token)
        if case .denyPII(.apiKey) = drop { /* ok */ } else {
            XCTFail("Expected denyPII(.apiKey), got \(drop)")
        }
    }

    func testCleanTextPasses() async {
        let fw = firewall()
        let texts = [
            "Hello, world!",
            "Meeting at 3pm tomorrow",
            "The quick brown fox",
        ]
        for text in texts {
            let (token, drop) = await fw.admit(lane: "test", candidate(ocrText: text))
            XCTAssertNotNil(token, "Clean text should pass: \(text)")
            XCTAssertEqual(drop, .ok)
        }
    }

    // MARK: - Content whitelist

    func testUnknownKindFailsClosed() async {
        let fw = firewall()
        let (token, drop) = await fw.admit(lane: "test", candidate(kind: "unknownSensorKind"))
        XCTAssertNil(token)
        if case .denyUnknownFailClosed = drop { /* ok */ } else {
            XCTFail("Expected denyUnknownFailClosed, got \(drop)")
        }
    }

    func testAllKnownKindsPass() async {
        let fw = firewall()
        let kinds = [
            "focusChanged", "inputIdle", "inputResumed", "urlVisited",
            "meetingStarted", "meetingEnded", "placeChanged", "cameraToggled",
            "microphoneToggled", "focusModeChanged", "clipboardCopied",
            "querySubmitted", "surfaceEngaged", "sessionClosed",
            "screenFrameIngested", "fileIndexed", "clipIndexed",
            "browserPageIndexed", "messageIndexed", "mailIndexed",
            "calendarIndexed", "agentTurnIndexed",
        ]
        for kind in kinds {
            let (token, drop) = await fw.admit(lane: "test", candidate(kind: kind))
            XCTAssertNotNil(token, "Known kind '\(kind)' should be admitted")
            XCTAssertEqual(drop, .ok, "Expected .ok for kind '\(kind)'")
        }
    }

    // MARK: - Drop log ring buffer

    func testRingBufferRetainsLast1000() async {
        let fw = firewall()
        // Each candidate with an unknown kind produces a deny
        for i in 0..<1500 {
            await fw.admit(lane: "test", candidate(kind: "badKind_\(i)"))
        }
        let count = await fw.dropCount()
        XCTAssertEqual(count, 1000, "Ring buffer must cap at 1000")
    }

    func testRecentDropsLimit() async {
        let fw = firewall()
        for _ in 0..<50 {
            await fw.admit(lane: "test", candidate(kind: "bad"))
        }
        let recent = await fw.recentDrops(limit: 10)
        XCTAssertEqual(recent.count, 10)
    }

    // MARK: - No raw content in serialized drop log

    func testDropLogContainsNoRawStrings() async throws {
        let fw = firewall()
        let sensitiveStrings = (0..<1000).map { "sensitive_ocr_content_\($0)_hunter2" }
        for (i, text) in sensitiveStrings.enumerated() {
            await fw.admit(lane: "lane\(i)", candidate(kind: "bad_\(i)", ocrText: text))
        }

        let drops = await fw.recentDrops(limit: 1000)
        let encoded = try JSONEncoder().encode(drops)
        let json = String(data: encoded, encoding: .utf8) ?? ""

        // None of the raw OCR strings should appear in the serialized log
        for text in sensitiveStrings {
            XCTAssertFalse(json.contains(text),
                "Raw OCR content leaked into drop log: \(text.prefix(30))")
        }
    }

    // MARK: - Shape signature

    func testShapeSignatureIdenticalForSameBucket() {
        // Two strings of the same length and digit ratio should produce identical signatures
        let a = "abc123"   // length 6, 3 digits (ratio 0.5), no colon, no dash
        let b = "xyz456"   // same shape
        let sigA = PrivacyFirewall.shapeSignature(a)
        let sigB = PrivacyFirewall.shapeSignature(b)
        XCTAssertEqual(sigA, sigB, "Same shape must yield same signature (collision is intentional)")
    }

    func testShapeSignatureDiffersForDifferentShape() {
        let short = "ab1"               // length 3
        let long  = String(repeating: "a1", count: 50) // length 100
        let sigShort = PrivacyFirewall.shapeSignature(short)
        let sigLong  = PrivacyFirewall.shapeSignature(long)
        XCTAssertNotEqual(sigShort, sigLong)
    }

    func testShapeSignatureColonAndDashFlags() {
        let withColon = "hello:world"
        let withDash  = "hello-world"
        let plain     = "helloworld "
        let sC = PrivacyFirewall.shapeSignature(withColon)
        let sD = PrivacyFirewall.shapeSignature(withDash)
        let sP = PrivacyFirewall.shapeSignature(plain)
        // Colon flag (bit 1) set
        XCTAssertEqual(sC & 0b10, 0b10, "Colon flag should be set")
        // Dash flag (bit 0) set
        XCTAssertEqual(sD & 0b01, 0b01, "Dash flag should be set")
        // Neither set for plain
        XCTAssertEqual(sP & 0b11, 0, "No flags for plain text")
    }

    func testShapeSignatureNilReturnsZero() {
        XCTAssertEqual(PrivacyFirewall.shapeSignature(nil), 0)
        XCTAssertEqual(PrivacyFirewall.shapeSignature(""), 0)
    }

    // MARK: - Token issuance

    func testTokenIssuedOnOk() async {
        let fw = firewall()
        let (token, drop) = await fw.admit(lane: "test", candidate())
        XCTAssertNotNil(token)
        XCTAssertEqual(drop, .ok)
    }

    func testNoTokenOnDeny() async {
        let fw = firewall()
        let (token, _) = await fw.admit(lane: "test", candidate(bundleID: "com.1password.1password"))
        XCTAssertNil(token)
    }
}
