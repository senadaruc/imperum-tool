import XCTest
@testable import ImperumCore

final class DisplaySamplerTests: XCTestCase {
    func testGpxPerSec() {
        // 7680×3240 @ 60 = 1,492,992,000 px/s
        XCTAssertEqual(displayGpxPerSec(pixelW: 7680, pixelH: 3240, refresh: 60), 1_492_992_000, accuracy: 1)
        // 120 Hz doubles it
        XCTAssertEqual(displayGpxPerSec(pixelW: 7680, pixelH: 3240, refresh: 120), 2_985_984_000, accuracy: 1)
    }
    func testUnknownRefreshAssumes60() {
        XCTAssertEqual(displayGpxPerSec(pixelW: 1000, pixelH: 1000, refresh: 0), 60_000_000, accuracy: 1)
    }
    func testScaledDetection() {
        // clean 2× HiDPI → not "scaled"
        let retina = DisplayInfo(displayID: 1, isMain: true, pointW: 3840, pointH: 1620,
                                 pixelW: 7680, pixelH: 3240, refresh: 60)
        XCTAssertFalse(retina.isScaled)
        XCTAssertEqual(retina.megapixels, 24.8832, accuracy: 0.01)
        // fractional scaling (renders oversized) → scaled
        let scaled = DisplayInfo(displayID: 2, isMain: false, pointW: 3008, pointH: 1692,
                                 pixelW: 6016, pixelH: 3384, refresh: 60)
        XCTAssertFalse(scaled.isScaled)   // exactly 2× → not scaled
        let frac = DisplayInfo(displayID: 3, isMain: false, pointW: 2048, pointH: 1152,
                               pixelW: 5120, pixelH: 2880, refresh: 60)
        XCTAssertTrue(frac.isScaled)      // 5120 != 2048 and != 4096 → scaled
    }
}
