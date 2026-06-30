import XCTest
@testable import WSCore

final class WindowServerStatTests: XCTestCase {
    func testProcessNameOfSelf() {
        let me = Int32(ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(processName(pid: me))
    }
    func testWindowServerFound() {
        // WindowServer always runs in a logged-in GUI session.
        XCTAssertNotNil(windowServerPID())
    }
}
