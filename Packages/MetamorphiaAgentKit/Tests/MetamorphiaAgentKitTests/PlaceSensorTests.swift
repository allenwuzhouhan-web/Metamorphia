/*
 * PlaceSensorTests
 *
 * Tests for PlaceSensor's cryptographic core. PlaceSensor itself lives in the
 * Metamorphia app target (it depends on Defaults, NSWorkspace, ActivityStream,
 * etc.), so this file tests the underlying hash logic by replicating the same
 * algorithm here. If a dedicated app test target is added in the future, tests
 * 4 (testLabelLookupUsed) and 6 (testDisabledGateIsNoOp) should migrate there
 * so they can exercise PlaceSensor end-to-end via @testable import Metamorphia.
 *
 * Salt storage: testSaltIsStableAcrossInstances writes a Keychain item under
 * "com.metamorphia.place-salt.test.v1" and deletes it in tearDown. This tag is
 * distinct from the production tag so tests never corrupt live data.
 */

import CryptoKit
import Foundation
import Security
import XCTest

// MARK: - Helpers mirroring PlaceSensor's internal logic

private enum PlaceHashTestHelper {

    static let testSaltTag = "com.metamorphia.place-salt.test.v1"
    static let saltAccount = "place-salt-test"

    // Mirror of PlaceSensor.hashSSID(_:salt:)
    static func hashSSID(_ ssid: String, salt: Data) -> String {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(ssid.utf8),
            using: SymmetricKey(data: salt)
        )
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // Mirror of PlaceSensor.resolveSalt() using an isolated test keychain tag.
    static func resolveTestSalt() -> Data? {
        if let existing = loadTestSalt() { return existing }
        return generateAndStoreTestSalt()
    }

    static func loadTestSalt() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testSaltTag,
            kSecAttrAccount as String: saltAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            return nil
        }
        return data
    }

    @discardableResult
    static func generateAndStoreTestSalt() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let saltData = Data(bytes)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testSaltTag,
            kSecAttrAccount as String: saltAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testSaltTag,
            kSecAttrAccount as String: saltAccount,
            kSecValueData as String: saltData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else { return nil }
        return saltData
    }

    static func deleteTestSalt() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testSaltTag,
            kSecAttrAccount as String: saltAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - PlaceSensorTests

final class PlaceSensorTests: XCTestCase {

    override func tearDown() {
        // Clean up any Keychain items written during tests.
        PlaceHashTestHelper.deleteTestSalt()
    }

    // MARK: - 1. Salt stability across instances

    /// Two separate calls to resolveTestSalt() must return identical bytes once
    /// the item is seeded. This mirrors what PlaceSensor.resolveSalt() does across
    /// app restarts — the same Keychain item is loaded each time.
    func testSaltIsStableAcrossInstances() throws {
        let first = try XCTUnwrap(PlaceHashTestHelper.resolveTestSalt(),
                                  "First salt resolution should succeed")
        let second = try XCTUnwrap(PlaceHashTestHelper.resolveTestSalt(),
                                   "Second salt resolution should succeed")
        XCTAssertEqual(first, second,
                       "Salt must be identical across resolutions (Keychain item reused)")
    }

    // MARK: - 2. Same SSID hashes to same value

    func testSameSSIDHashesToSameValue() throws {
        let salt = try XCTUnwrap(PlaceHashTestHelper.resolveTestSalt())
        let ssid = "HomeNetwork-5GHz"
        let hash1 = PlaceHashTestHelper.hashSSID(ssid, salt: salt)
        let hash2 = PlaceHashTestHelper.hashSSID(ssid, salt: salt)
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 16, "Hash must be exactly 16 hex characters")
    }

    // MARK: - 3. Different SSIDs produce different hashes

    func testDifferentSSIDsDifferentHashes() throws {
        let salt = try XCTUnwrap(PlaceHashTestHelper.resolveTestSalt())
        let hashA = PlaceHashTestHelper.hashSSID("CoffeeShop-WiFi", salt: salt)
        let hashB = PlaceHashTestHelper.hashSSID("HomeNetwork-5GHz", salt: salt)
        XCTAssertNotEqual(hashA, hashB)
    }

    // MARK: - 4. Label lookup (requires app test target)

    /// This test documents the expected behavior: when a PlaceLabelStore has a
    /// label for a hash, the emitted ActivityEvent must carry it.
    ///
    /// Full end-to-end verification requires @testable import Metamorphia, which
    /// is only possible from an app-level XCTest target. When that target is
    /// added, migrate the test there and replace this note with the real test.
    func testLabelLookupUsed_documentedBehavior() {
        // Intentionally left as a documentation stub. The expected contract:
        //   let store = MockLabelStore()
        //   store.assign(label: "Home", to: someHash)
        //   // sensor emits .placeChanged with label: "Home"
        //   XCTAssertEqual(capturedEvent.label, "Home")
        //
        // This is verified manually / by integration tests against the running app.
    }

    // MARK: - 5. SSID never appears in hash output

    /// The hash output is opaque hex. Assert that a known SSID string cannot be
    /// found in the resulting hash string (trivially true for any HMAC, but
    /// belt-and-suspenders check as a canary for accidental logging).
    func testSSIDNeverAppearsInHash() throws {
        let salt = try XCTUnwrap(PlaceHashTestHelper.resolveTestSalt())
        let ssid = "MySensitiveNetworkName"
        let hash = PlaceHashTestHelper.hashSSID(ssid, salt: salt)
        XCTAssertFalse(hash.contains(ssid),
                       "Hash output must not contain the raw SSID")
        // Also verify hash is lowercase hex only.
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hash.unicodeScalars.allSatisfy { hexChars.contains($0) },
                      "Hash must contain only lowercase hex characters")
    }

    // MARK: - 6. Feature gate is no-op (requires app test target)

    /// When Defaults[.observePlace] == false, PlaceSensor.start() must not emit.
    ///
    /// Requires @testable import Metamorphia to access PlaceSensor and Defaults.
    /// Migrate to an app test target when one is added.
    func testDisabledGateIsNoOp_documentedBehavior() {
        // Intentionally left as a documentation stub. The expected contract:
        //   Defaults[.observePlace] = false
        //   sensor.start()
        //   // wait for one poll cycle
        //   XCTAssertTrue(capturedEvents.isEmpty)
    }

    // MARK: - Salt invariant: non-empty

    /// Salt must be non-empty (32 bytes). An empty salt would mean any SSID hashes
    /// to the same value when keyed with an empty key — privacy failure.
    func testSaltIsNonEmpty() throws {
        let salt = try XCTUnwrap(PlaceHashTestHelper.resolveTestSalt())
        XCTAssertEqual(salt.count, 32, "Salt must be exactly 32 bytes")
        XCTAssertFalse(salt.allSatisfy { $0 == 0 }, "Salt must not be all-zero bytes")
    }

    // MARK: - Hash length is exactly 16 chars

    func testHashIsAlways16Chars() throws {
        let salt = try XCTUnwrap(PlaceHashTestHelper.resolveTestSalt())
        // Test with a variety of SSID inputs to ensure stable length.
        let ssids = ["A", "A longer network name with spaces 2.4GHz", "🏠", "x" + String(repeating: "y", count: 512)]
        for ssid in ssids {
            let hash = PlaceHashTestHelper.hashSSID(ssid, salt: salt)
            XCTAssertEqual(hash.count, 16, "Hash for SSID '\(ssid)' must be 16 chars, got \(hash.count)")
        }
    }
}
