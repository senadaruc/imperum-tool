import XCTest
@testable import WSCore

final class CPUSamplerTests: XCTestCase {
    func testHalfCoreBusy() {
        // 0.5s of CPU time over 1.0s wall = 50%
        let pct = cpuPercent(prevNs: 0, curNs: 500_000_000, elapsed: 1.0)
        XCTAssertEqual(pct, 50.0, accuracy: 0.001)
    }
    func testTwoCoresFull() {
        // 2.0s CPU over 1.0s wall = 200%
        let pct = cpuPercent(prevNs: 1_000_000_000, curNs: 3_000_000_000, elapsed: 1.0)
        XCTAssertEqual(pct, 200.0, accuracy: 0.001)
    }
    func testZeroElapsedIsZero() {
        XCTAssertEqual(cpuPercent(prevNs: 0, curNs: 1, elapsed: 0), 0)
    }
    func testLiveSelfHasRSS() {
        let me = Int32(ProcessInfo.processInfo.processIdentifier)
        let s = CPUSampler().sample(pids: [me])
        XCTAssertNotNil(s[me])
        XCTAssertGreaterThan(s[me]!.rss, 0)
    }
}
