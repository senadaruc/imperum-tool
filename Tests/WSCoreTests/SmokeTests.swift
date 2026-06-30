import XCTest
@testable import WSCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(WSCore.version, "0.1.0")
    }
}
