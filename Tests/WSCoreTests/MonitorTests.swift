import XCTest
@testable import WSCore

final class MonitorTests: XCTestCase {
    func testRanksByHeavyDescAndExtractsWS() {
        let win: [Int32: WinAgg] = [
            10: WinAgg(name: "Chrome", windows: 6, area: 8_300_000, perDisplay: [1: 8_300_000]),
            99: WinAgg(name: "WindowServer", windows: 0, area: 0, perDisplay: [:]),
            20: WinAgg(name: "Notes", windows: 1, area: 200_000, perDisplay: [1: 200_000]),
        ]
        let cpu: [Int32: (cpu: Double, rss: Double)] = [
            10: (40, 1500), 99: (75, 900), 20: (2, 120),
        ]
        let snap = buildSnapshot(winAgg: win, cpu: cpu, wsPID: 99,
                                 gpu: GPUStats(utilization: 88), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snap.wsCPU, 75)
        XCTAssertEqual(snap.wsRSS, 900)
        XCTAssertEqual(snap.apps.first?.name, "Chrome")   // highest HEAVY
        XCTAssertFalse(snap.apps.contains { $0.name == "WindowServer" }) // WS excluded from suspects
    }
}
