import XCTest
@testable import CopyStackKit

final class FocusWaitTests: XCTestCase {
    private func ready(_ ms: Int) -> FocusWait.Observation {
        FocusWait.Observation(originIsFrontmost: true, originWindowFocused: true, pickerWindowGone: true, elapsedMs: ms)
    }
    private func notReady(_ ms: Int) -> FocusWait.Observation {
        FocusWait.Observation(originIsFrontmost: false, originWindowFocused: true, pickerWindowGone: true, elapsedMs: ms)
    }

    func test_immediateReadiness_postsOnSecondTick() {
        var fw = FocusWait()
        XCTAssertEqual(fw.step(ready(0)), .wait)
        XCTAssertEqual(fw.step(ready(20)), .post)
    }

    func test_flap_postsOnFourthTick() {
        var fw = FocusWait()
        // ready, not ready, ready, ready -> stable count resets on the flap,
        // so .post only after two consecutive ready observations following it.
        XCTAssertEqual(fw.step(ready(0)), .wait)      // ready streak = 1
        XCTAssertEqual(fw.step(notReady(20)), .wait)  // streak resets to 0
        XCTAssertEqual(fw.step(ready(40)), .wait)     // streak = 1
        XCTAssertEqual(fw.step(ready(60)), .post)     // streak = 2 -> post
    }

    func test_nudge_firesOnceAt150ms_andNeverAgain() {
        var fw = FocusWait()
        XCTAssertEqual(fw.step(notReady(0)), .wait)
        XCTAssertEqual(fw.step(notReady(100)), .wait)
        XCTAssertEqual(fw.step(notReady(150)), .nudge)
        XCTAssertEqual(fw.step(notReady(170)), .wait)
        XCTAssertEqual(fw.step(notReady(300)), .wait)
    }

    func test_timeout_at1500ms() {
        var fw = FocusWait()
        XCTAssertEqual(fw.step(notReady(0)), .wait)
        XCTAssertEqual(fw.step(notReady(150)), .nudge)
        XCTAssertEqual(fw.step(notReady(1499)), .wait)
        XCTAssertEqual(fw.step(notReady(1500)), .timeout)
    }

    func test_noPostAfterTimeout() {
        var fw = FocusWait()
        XCTAssertEqual(fw.step(notReady(1500)), .timeout)
        // Even if it becomes ready after timing out, no more .post should fire.
        XCTAssertEqual(fw.step(ready(1520)), .wait)
        XCTAssertEqual(fw.step(ready(1540)), .wait)
    }

    func test_customParameters() {
        var fw = FocusWait(nudgeAfterMs: 50, timeoutMs: 200, stableTicks: 1)
        XCTAssertEqual(fw.step(ready(0)), .post)
    }

    func test_readyButNotYetStableAtTimeoutDeadline_timesOutRatherThanWaiting() {
        var fw = FocusWait()
        // First ready tick lands exactly at the timeout deadline: stableCount
        // is only 1 (< stableTicks == 2), so it must not silently .wait —
        // the deadline has already passed, so it times out instead.
        XCTAssertEqual(fw.step(ready(1500)), .timeout)
    }

    func test_readyAndStableExactlyAtTimeoutDeadline_stillPosts() {
        var fw = FocusWait(stableTicks: 1)
        // With stableTicks == 1, a single ready tick is enough to post even
        // when that tick's elapsedMs has already reached the timeout.
        XCTAssertEqual(fw.step(ready(1500)), .post)
    }
}
