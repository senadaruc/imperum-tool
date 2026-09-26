import XCTest
@testable import CopyStackKit

final class SmokeTests: XCTestCase {
    func testProtocolVersion() {
        XCTAssertEqual(CopyStackKit.protocolVersion, 1)
    }
}
