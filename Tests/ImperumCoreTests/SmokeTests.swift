import XCTest
@testable import ImperumCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(ImperumCore.version, "0.1.0")
    }
}
