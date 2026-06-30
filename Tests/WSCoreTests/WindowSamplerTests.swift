import XCTest
@testable import WSCore

final class WindowSamplerTests: XCTestCase {
    func testFiltersAndAggregates() {
        let ws = [
            RawWindow(pid: 10, owner: "Chrome", layer: 0, width: 1000, height: 1000, displayID: 1), // 1,000,000
            RawWindow(pid: 10, owner: "Chrome", layer: 0, width: 50, height: 50, displayID: 1),       // 2500 < 5000 → dropped
            RawWindow(pid: 10, owner: "Chrome", layer: 0, width: 2000, height: 1000, displayID: 2),  // 2,000,000 other display
            RawWindow(pid: 20, owner: "Dock", layer: 25, width: 4000, height: 100, displayID: 1),    // layer != 0 → dropped
        ]
        let agg = aggregate(windows: ws)
        XCTAssertNil(agg[20])                       // dock filtered by layer
        XCTAssertEqual(agg[10]?.windows, 2)         // two surviving windows
        XCTAssertEqual(agg[10]?.area, 3_000_000)
        XCTAssertEqual(agg[10]?.perDisplay[1], 1_000_000)
        XCTAssertEqual(agg[10]?.perDisplay[2], 2_000_000)
        XCTAssertEqual(agg[10]?.name, "Chrome")
    }
}
