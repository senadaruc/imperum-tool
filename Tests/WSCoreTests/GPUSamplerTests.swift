import XCTest
@testable import WSCore

final class GPUSamplerTests: XCTestCase {
    func testParseKnownKeys() {
        let perf: [String: Any] = [
            "Device Utilization %": 30,
            "Renderer Utilization %": 28,
            "Tiler Utilization %": 12,
            "In use system memory": 3_083_403_264, // bytes
        ]
        let s = parseAcceleratorStats(perf)
        XCTAssertEqual(s.utilization, 30)
        XCTAssertEqual(s.rendererUtil, 28)
        XCTAssertEqual(s.tilerUtil, 12)
        XCTAssertEqual(s.memInUseMB!, 2940.5, accuracy: 1.0)
    }
    func testMissingKeysAreNil() {
        let s = parseAcceleratorStats([:])
        XCTAssertNil(s.utilization)
        XCTAssertNil(s.memInUseMB)
    }
    func testLiveGPUReadsUtilization() {
        // On this M3 Max IOAccelerator exposes Device Utilization %.
        let s = sampleGPU()
        XCTAssertNotNil(s.utilization)
    }
}
