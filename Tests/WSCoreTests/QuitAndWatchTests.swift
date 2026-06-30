import XCTest
@testable import WSCore

final class QuitAndWatchTests: XCTestCase {
    func testDropMath() {
        let r = watchDrop(before: 180, after: 40)
        XCTAssertEqual(r.drop, 140, accuracy: 0.001)
    }
}
