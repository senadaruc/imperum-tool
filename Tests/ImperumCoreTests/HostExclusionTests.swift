// Tests/ImperumCoreTests/HostExclusionTests.swift
import XCTest
@testable import ImperumCore

final class HostExclusionTests: XCTestCase {
    func testNormalizeStripsSchemeUserinfoPortPathQuery() {
        XCTAssertEqual(HostExclusion.normalize("https://Login.MyBank.com:443/accounts?x=1"), "login.mybank.com")
    }

    func testNormalizeStripsLeadingWildcardAndWww() {
        XCTAssertEqual(HostExclusion.normalize("*.mybank.com"), "mybank.com")
        XCTAssertEqual(HostExclusion.normalize("www.mybank.com"), "mybank.com")
    }

    func testNormalizeStripsTrailingDot() {
        XCTAssertEqual(HostExclusion.normalize("mybank.com."), "mybank.com")
    }

    func testNormalizeRejectsInvalidInput() {
        XCTAssertNil(HostExclusion.normalize("localhost"))
        XCTAssertNil(HostExclusion.normalize("my bank.com"))
        XCTAssertNil(HostExclusion.normalize(""))
        XCTAssertNil(HostExclusion.normalize("   "))
    }

    func testNormalizeRejectsEmptyLabels() {
        XCTAssertNil(HostExclusion.normalize(".mybank.com"))
        XCTAssertNil(HostExclusion.normalize("a..b.com"))
        XCTAssertNil(HostExclusion.normalize("mybank..com"))
    }

    func testNormalizeOnlyStripsALeadingScheme() {
        // A scheme embedded further in, e.g. inside a query string, must not
        // be treated as the start of the host.
        XCTAssertEqual(HostExclusion.normalize("example.com/r?u=http://x.org"), "example.com")
    }

    func testDisplayPrefixesWildcard() {
        XCTAssertEqual(HostExclusion.display("mybank.com"), "*.mybank.com")
    }

    func testMatchesHostAndSubdomains() {
        XCTAssertTrue(HostExclusion.matches(host: "login.mybank.com", entries: ["mybank.com"]))
        XCTAssertTrue(HostExclusion.matches(host: "mybank.com", entries: ["mybank.com"]))
    }

    func testMatchesRejectsLookalikeAndUnrelatedHosts() {
        XCTAssertFalse(HostExclusion.matches(host: "mybank.com.evil.com", entries: ["mybank.com"]))
        XCTAssertFalse(HostExclusion.matches(host: "notmybank.com", entries: ["mybank.com"]))
    }

    func testMatchesIsCaseInsensitiveAndIgnoresTrailingDot() {
        XCTAssertTrue(HostExclusion.matches(host: "MYBANK.COM.", entries: ["mybank.com"]))
    }

    func testMatchesIgnoresEmptyEntries() {
        XCTAssertFalse(HostExclusion.matches(host: "mybank.com", entries: [""]))
        XCTAssertTrue(HostExclusion.matches(host: "mybank.com", entries: ["", "mybank.com"]))
    }
}
