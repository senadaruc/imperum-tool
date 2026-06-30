import XCTest
@testable import WSCore

final class PowerMetricsParserTests: XCTestCase {
    // Real M3 Max / macOS 26 format: multi-value Deadlines/Wakeups columns,
    // per-process GPU ms/s is 0 (Apple Silicon), Energy Impact carries the signal,
    // and a trailing "**** GPU usage ****" footer that must NOT be parsed as rows.
    let fixture = """
    *** Running tasks ***

    Name                               ID     CPU ms/s  User%  Deadlines (<2 ms, 2-5 ms)  Wakeups (Intr, Pkg idle)  GPU ms/s  Energy Impact
    Firefox GPU Helper                 67117  561.77    95.41  0.00    0.00               8.61    0.00              0.00      2053.47
    WindowServer                       431    400.63    72.68  215.33  0.00               641.70  8.61              0.00      1139.30
    powermetrics                       3767   184.37    23.60  0.00    0.00               4.31    0.00              0.00      254.11
    ALL_TASKS                          -2     1146.77   77.23  215.33  0.00               654.62  17.22             0.00      3446.88

    **** GPU usage ****

    GPU HW active frequency: 338 MHz
    GPU HW active residency:  27.95% (338 MHz:  28% 618 MHz:   0%)
    GPU Power: 1043 mW
    """

    func testStopsAtTableEnd() {
        let procs = parsePowerMetrics(fixture)
        // 3 real rows only — ALL_TASKS and the GPU-usage footer excluded.
        XCTAssertEqual(procs.count, 3)
        XCTAssertFalse(procs.contains { $0.name.contains("GPU HW") || $0.name.contains("GPU Power") })
        XCTAssertFalse(procs.contains { $0.pid == -2 })   // ALL_TASKS excluded
    }

    func testNameWithSpaces() {
        let procs = parsePowerMetrics(fixture)
        XCTAssertTrue(procs.contains { $0.name == "Firefox GPU Helper" && $0.pid == 67117 })
        XCTAssertTrue(procs.contains { $0.name == "WindowServer" && $0.pid == 431 })
    }

    func testEnergyImpactExtracted() throws {
        let procs = parsePowerMetrics(fixture)
        XCTAssertEqual(try XCTUnwrap(procs.first { $0.pid == 67117 }?.energyImpact), 2053.47, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(procs.first { $0.pid == 431 }?.energyImpact), 1139.30, accuracy: 0.5)
    }

    func testTopByEnergy() {
        let procs = parsePowerMetrics(fixture)
        let top = procs.max { ($0.energyImpact ?? 0) < ($1.energyImpact ?? 0) }
        XCTAssertEqual(top?.name, "Firefox GPU Helper")
    }

    func testEmptyOnGarbage() {
        XCTAssertTrue(parsePowerMetrics("no table here").isEmpty)
    }
}
