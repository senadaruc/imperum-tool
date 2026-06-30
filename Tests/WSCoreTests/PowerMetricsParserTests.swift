import XCTest
@testable import WSCore

final class PowerMetricsParserTests: XCTestCase {
    // Representative powermetrics tasks table (column-aligned headers).
    let fixture = """
    *** Running tasks ***

    Name                          ID     CPU ms/s  User%   GPU ms/s  Energy Impact
    WindowServer                  431    45.32     30.10   12.45     88.20
    Google Chrome Helper (GPU)    74812  30.10     20.00   28.91     65.40
    kernel_task                   0      10.00     0.00    0.00      2.10
    """

    func testParsesRows() {
        let procs = parsePowerMetrics(fixture)
        XCTAssertEqual(procs.count, 3)
        XCTAssertTrue(procs.contains { $0.name == "WindowServer" && $0.pid == 431 })
    }

    func testNameWithSpacesAndParens() {
        let procs = parsePowerMetrics(fixture)
        let chrome = procs.first { $0.pid == 74812 }
        XCTAssertEqual(chrome?.name, "Google Chrome Helper (GPU)")
    }

    func testGpuColumnExtracted() throws {
        let procs = parsePowerMetrics(fixture)
        XCTAssertEqual(try XCTUnwrap(procs.first { $0.pid == 74812 }?.gpuMsPerS), 28.91, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(procs.first { $0.pid == 431 }?.gpuMsPerS), 12.45, accuracy: 0.001)
    }

    func testEnergyColumnExtracted() throws {
        let procs = parsePowerMetrics(fixture)
        XCTAssertEqual(try XCTUnwrap(procs.first { $0.pid == 431 }?.energyImpact), 88.20, accuracy: 0.001)
    }

    func testTopGpuRanking() {
        let procs = parsePowerMetrics(fixture)
        let top = procs.compactMap { p in p.gpuMsPerS.map { (p.name, $0) } }.max { $0.1 < $1.1 }
        XCTAssertEqual(top?.0, "Google Chrome Helper (GPU)")
    }

    func testEmptyOnGarbage() {
        XCTAssertTrue(parsePowerMetrics("no table here").isEmpty)
    }
}
