import XCTest
@testable import WSCore

final class HeavyScoreTests: XCTestCase {
    func testFormulaMatchesScript() {
        // cpu*100 + area/100000 + windows*20 + rss/20
        let s = heavyScore(cpu: 12.5, area: 8_300_000, windows: 6, rss: 1024)
        // 1250 + 83 + 120 + 51.2 = 1504.2
        XCTAssertEqual(s, 1504.2, accuracy: 0.001)
    }
    func testZero() {
        XCTAssertEqual(heavyScore(cpu: 0, area: 0, windows: 0, rss: 0), 0, accuracy: 0.0001)
    }
}
