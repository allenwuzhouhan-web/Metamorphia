/*
 * BrowserDomainAllowlistTests
 *
 * NOTE: This file requires a macOS XCTest target that includes Metamorphia's
 * application sources. No such target exists yet in Metamorphia.xcodeproj.
 * Wire it up when a MetamorphiaTests target is added to the project.
 *
 * Tests cover:
 *   - Domain normalization (scheme + www stripping, lowercasing)
 *   - allows(host:) semantics: empty-list, exact match, subdomain, non-match
 */

import XCTest
@testable import Metamorphia   // adjust module name once a test target exists

@MainActor
final class BrowserDomainAllowlistTests: XCTestCase {

    // Use an in-memory store for each test via a temp URL.
    private var store: BrowserDomainAllowlist!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        store = BrowserDomainAllowlist(storageURL: tmp)
    }

    // MARK: - testAddNormalizesDomain

    /// add("https://WWW.Example.COM/path") → entries contains exactly "example.com".
    func testAddNormalizesDomain() {
        store.add(domain: "https://WWW.Example.COM/path")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.domain, "example.com")
    }

    // MARK: - testAllowsEmptyReturnsTrue

    /// Empty allowlist → allows any host.
    func testAllowsEmptyReturnsTrue() {
        XCTAssertTrue(store.allows(host: "any.example.com"))
    }

    // MARK: - testAllowsExactAndSubdomain

    /// add("example.com") → exact and subdomain match, but not an unrelated host.
    func testAllowsExactAndSubdomain() {
        store.add(domain: "example.com")
        XCTAssertTrue(store.allows(host: "example.com"),
                      "exact match must be allowed")
        XCTAssertTrue(store.allows(host: "api.example.com"),
                      "subdomain must be allowed")
        XCTAssertFalse(store.allows(host: "malicious-example.com"),
                       "host that merely ends with 'example.com' but without a dot separator must be rejected")
    }

    // MARK: - testAllowsNotMatchSiblingDomain

    /// add("github.com") → github.io must be rejected.
    func testAllowsNotMatchSiblingDomain() {
        store.add(domain: "github.com")
        XCTAssertFalse(store.allows(host: "github.io"),
                       "sibling TLD must not be allowed")
    }
}
