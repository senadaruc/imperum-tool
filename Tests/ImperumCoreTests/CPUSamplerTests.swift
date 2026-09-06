import XCTest
@testable import ImperumCore

final class CPUSamplerTests: XCTestCase {
    func testHalfCoreBusy() {
        let pct = cpuPercent(prevNs: 0, curNs: 500_000_000, elapsed: 1.0)
        XCTAssertEqual(pct, 50.0, accuracy: 0.001)
    }
    func testTwoCoresFull() {
        let pct = cpuPercent(prevNs: 1_000_000_000, curNs: 3_000_000_000, elapsed: 1.0)
        XCTAssertEqual(pct, 200.0, accuracy: 0.001)
    }
    func testZeroElapsedIsZero() {
        XCTAssertEqual(cpuPercent(prevNs: 0, curNs: 1, elapsed: 0), 0)
    }

    func testParseCpuTimeFormats() {
        XCTAssertEqual(parseCpuTime("2836:57.79"), 170217.79, accuracy: 0.001)   // 2836*60+57.79
        XCTAssertEqual(parseCpuTime("12:21.97"), 741.97, accuracy: 0.001)        // 12*60+21.97
        XCTAssertEqual(parseCpuTime("1:02:03.50"), 3723.5, accuracy: 0.001)      // 3600+120+3.5
        XCTAssertEqual(parseCpuTime("2-03:04:05.00"), 183845.0, accuracy: 0.001) // 2d+3h+4m+5s
    }

    func testParsePSRows() {
        let text = """
          431 2836:57.79 315776
        74734 12:21.97 421808
        bad line here
        """
        let rows = parsePSRows(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].pid, 431)
        XCTAssertEqual(rows[0].cpuSeconds, 170217.79, accuracy: 0.001)
        XCTAssertEqual(rows[0].rssMB, 315776.0 / 1024.0, accuracy: 0.001)
    }

    func testDeltaAcrossTwoSamples() {
        let s = CPUSampler()
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = Date(timeIntervalSince1970: 1)   // 1s later
        // First sample: establishes baseline (cpu% = 0).
        let r0 = s.sample(rows: [PSRow(pid: 431, cpuSeconds: 100.0, rssMB: 300)], wanted: [431], now: t0)
        XCTAssertEqual(r0[431]!.cpu, 0, accuracy: 0.001)
        // Second: +0.5s CPU over 1s wall = 50%.
        let r1 = s.sample(rows: [PSRow(pid: 431, cpuSeconds: 100.5, rssMB: 300)], wanted: [431], now: t1)
        XCTAssertEqual(r1[431]!.cpu, 50, accuracy: 0.5)
    }

    func testLiveSelfHasRSS() {
        let me = Int32(ProcessInfo.processInfo.processIdentifier)
        let s = CPUSampler().sample(pids: [me])
        XCTAssertNotNil(s[me])
        XCTAssertGreaterThan(s[me]!.rss, 0)
    }
}
