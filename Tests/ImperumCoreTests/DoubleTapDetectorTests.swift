import XCTest
@testable import ImperumCore

final class DoubleTapDetectorTests: XCTestCase {
    func testSingleTapHoldsThenPastesOnTimer() {
        var d = DoubleTapDetector(window: 0.3)
        XCTAssertEqual(d.feed(.cmdV(at: 0, isRepeat: false)), .hold)
        XCTAssertEqual(d.feed(.timerFired), .pasteNow)
        XCTAssertEqual(d.feed(.cmdV(at: 1, isRepeat: false)), .hold)      // back to idle, holds again
    }

    func testSecondTapInsideWindowOpensPanel() {
        var d = DoubleTapDetector(window: 0.3)
        XCTAssertEqual(d.feed(.cmdV(at: 0, isRepeat: false)), .hold)
        XCTAssertEqual(d.feed(.cmdV(at: 0.2, isRepeat: false)), .openPanel)
        XCTAssertEqual(d.feed(.timerFired), .passThrough)                    // stale timer is ignored
    }

    func testOtherKeyWhileHoldingFlushesPaste() {
        var d = DoubleTapDetector(window: 0.3)
        _ = d.feed(.cmdV(at: 0, isRepeat: false))
        XCTAssertEqual(d.feed(.other), .pasteNow)
        XCTAssertEqual(d.feed(.other), .passThrough)
    }

    func testAutoRepeatIsSwallowedAndNeverOpensPanel() {
        var d = DoubleTapDetector(window: 0.3)
        _ = d.feed(.cmdV(at: 0, isRepeat: false))
        XCTAssertEqual(d.feed(.cmdV(at: 0.05, isRepeat: true)), .swallow)
        XCTAssertEqual(d.feed(.cmdV(at: 0.10, isRepeat: true)), .swallow)
        XCTAssertEqual(d.feed(.timerFired), .pasteNow)
    }

    func testRepeatWhileIdlePassesThrough() {
        var d = DoubleTapDetector(window: 0.3)
        XCTAssertEqual(d.feed(.cmdV(at: 0, isRepeat: true)), .passThrough)
    }

    func testIdleNonCmdVPassesThroughAndTimerIsNoop() {
        var d = DoubleTapDetector(window: 0.3)
        XCTAssertEqual(d.feed(.other), .passThrough)
        XCTAssertEqual(d.feed(.timerFired), .passThrough)
    }
}
