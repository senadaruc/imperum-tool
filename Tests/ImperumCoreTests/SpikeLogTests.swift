import XCTest
@testable import ImperumCore

final class SpikeLogTests: XCTestCase {
    private func snap(_ t: TimeInterval, wsCPU: Double, gpu: Double, top: String = "Chrome") -> Snapshot {
        Snapshot(ts: Date(timeIntervalSince1970: t), wsCPU: wsCPU, wsRSS: 0,
                 gpu: GPUStats(utilization: gpu),
                 apps: [AppSample(pid: 1, name: top, windows: 1, area: 1, heavy: 1)])
    }
    func testCapturesAboveThresholdThenCooldown() {
        let log = SpikeLog(config: SpikeConfig(cpuThreshold: 60, gpuThreshold: 80, cooldown: 30, topN: 5))
        XCTAssertNil(log.observe(snap(0, wsCPU: 10, gpu: 10)))     // calm
        XCTAssertNotNil(log.observe(snap(1, wsCPU: 70, gpu: 10)))  // CPU spike
        XCTAssertNil(log.observe(snap(5, wsCPU: 72, gpu: 10)))     // within cooldown, same suspect
        XCTAssertNotNil(log.observe(snap(40, wsCPU: 72, gpu: 10))) // cooldown elapsed
        XCTAssertNotNil(log.observe(snap(41, wsCPU: 72, gpu: 10, top: "Other"))) // suspect changed → capture
        XCTAssertEqual(log.events.count, 3)
    }
    func testGpuThreshold() {
        let log = SpikeLog(config: SpikeConfig())
        XCTAssertNotNil(log.observe(snap(0, wsCPU: 5, gpu: 90)))
    }
}
