import XCTest
@testable import WSCore

final class CorrelatorTests: XCTestCase {
    func testPerfectPositive() {
        XCTAssertEqual(pearson([1,2,3,4], [2,4,6,8]), 1.0, accuracy: 1e-9)
    }
    func testPerfectNegative() {
        XCTAssertEqual(pearson([1,2,3,4], [4,3,2,1]), -1.0, accuracy: 1e-9)
    }
    func testRankingFlagsCorrelatedApp() {
        let c = Correlator(window: 10)
        // WS rises with "Bad"; "Good" is flat.
        for i in 0..<6 {
            let ws = Double(i * 10)
            let snap = Snapshot(ts: Date(timeIntervalSince1970: Double(i)), wsCPU: ws, wsRSS: 0,
                gpu: GPUStats(utilization: ws),
                apps: [AppSample(pid: 1, name: "Bad", windows: 1, area: 1, cpu: ws, rss: 0, heavy: 1),
                       AppSample(pid: 2, name: "Good", windows: 1, area: 1, cpu: 5, rss: 0, heavy: 1)])
            c.record(snap)
        }
        let r = c.ranking()
        XCTAssertEqual(r.first?.name, "Bad")
        XCTAssertGreaterThan(r.first!.score, 0.9)
    }
}
