import XCTest
@testable import WSCore

final class FormattersTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(formatTitle(wsCPU: 42.4, gpu: 88.0, top: "Chrome"),
                       "WS 42% · GPU 88% · Chrome")
    }
    func testTitleNoTop() {
        XCTAssertEqual(formatTitle(wsCPU: 5, gpu: nil, top: nil),
                       "WS 5% · GPU —% · …")
    }
}
