import XCTest
import ImperumCore
@testable import CopyStackKit

final class PickerModelTests: XCTestCase {
    // MARK: - Fixtures

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000) // fixed instant

    private func textSummary(
        _ title: String, source: String = "TextEdit", pinned: Bool = false,
        secondsAgo: TimeInterval = 10, id: UUID = UUID()
    ) -> ClipSummary {
        let clip = Clip(
            id: id, kind: .text, capturedAt: now.addingTimeInterval(-secondsAgo),
            sourceAppName: source, sourceBundleID: nil, isPinned: pinned,
            title: title, payload: .text(title)
        )
        return ClipSummary(clip: clip)
    }

    private func manySummaries(_ count: Int) -> [ClipSummary] {
        (0..<count).map { i in
            textSummary("clip \(i)", secondsAgo: TimeInterval(count - i))
        }
    }

    private func makeModel(_ summaries: [ClipSummary], mode: PickerModel.Mode = .paste) -> PickerModel {
        PickerModel(summaries: summaries, mode: mode, now: now, calendar: calendar)
    }

    // MARK: - Typing / query

    func testTypingFiltersAndResetsSelection() {
        var m = makeModel([
            textSummary("apple"), textSummary("banana"), textSummary("cherry"),
        ])
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 1)

        let effect = m.reduce(.char("a"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .redraw)
        XCTAssertEqual(m.state.query, "a")
        XCTAssertEqual(m.flat.count, 2) // apple, banana ('a' present; cherry has none)
        XCTAssertEqual(m.state.selectedIndex, 0)

        _ = m.reduce(.char("p"), listHeight: 10, now: now, calendar: calendar)
        _ = m.reduce(.char("p"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.query, "app")
        XCTAssertEqual(m.flat.map(\.title), ["apple"])
    }

    func testBackspaceRemovesLastCharacter() {
        var m = makeModel([textSummary("apple")])
        _ = m.reduce(.char("a"), listHeight: 10, now: now, calendar: calendar)
        _ = m.reduce(.char("b"), listHeight: 10, now: now, calendar: calendar)
        let effect = m.reduce(.backspace, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .redraw)
        XCTAssertEqual(m.state.query, "a")
    }

    func testBackspaceOnEmptyQueryReturnsNone() {
        var m = makeModel([textSummary("apple")])
        let effect = m.reduce(.backspace, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .none)
        XCTAssertEqual(m.state.query, "")
    }

    func testCtrlUClearsQuery() {
        var m = makeModel([textSummary("apple")])
        _ = m.reduce(.char("a"), listHeight: 10, now: now, calendar: calendar)
        _ = m.reduce(.char("b"), listHeight: 10, now: now, calendar: calendar)
        let effect = m.reduce(.ctrl("u"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .redraw)
        XCTAssertEqual(m.state.query, "")
    }

    func testPasteKeyAppendsWithNewlinesRemoved() {
        var m = makeModel([textSummary("apple")])
        let effect = m.reduce(.paste("ab\ncd\r\n"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .redraw)
        XCTAssertEqual(m.state.query, "abcd")
    }

    // MARK: - Movement

    func testUpDownClampAtEdges() {
        var m = makeModel([textSummary("a"), textSummary("b"), textSummary("c")])
        _ = m.reduce(.up, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 0) // clamped, can't go below 0

        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar)
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar)
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 2) // clamped at last index
    }

    func testCtrlKAndCtrlNMoveLikeArrows() {
        var m = makeModel([textSummary("a"), textSummary("b"), textSummary("c")])
        _ = m.reduce(.ctrl("n"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 1)
        _ = m.reduce(.ctrl("j"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 2)
        _ = m.reduce(.ctrl("k"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 1)
    }

    func testPageUpPageDownMoveByListHeightMinusOne() {
        var m = makeModel(manySummaries(20))
        _ = m.reduce(.pageDown, listHeight: 5, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 4)
        _ = m.reduce(.pageDown, listHeight: 5, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 8)
        _ = m.reduce(.pageUp, listHeight: 5, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 4)
    }

    func testHomeAndEnd() {
        var m = makeModel(manySummaries(20))
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar)
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar)
        _ = m.reduce(.end, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 19)
        _ = m.reduce(.home, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.selectedIndex, 0)
    }

    // MARK: - Category cycling

    func testLeftRightCycleCategory() {
        var m = makeModel([textSummary("a")])
        XCTAssertEqual(m.state.category, .all)
        _ = m.reduce(.right, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.category, .text)
        _ = m.reduce(.left, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.state.category, .all)
        let effect = m.reduce(.left, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .redraw)
        XCTAssertEqual(m.state.category, .files) // wraps around
    }

    // MARK: - Enter / alt digits / pin / delete / cancel

    func testEnterYieldsPasteOfSelectedClip() {
        let a = textSummary("a")
        var m = makeModel([a, textSummary("b")])
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar)
        let effect = m.reduce(.enter, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(m.flat[1].id, m.selected?.id)
        XCTAssertEqual(effect, .paste(m.flat[1].id))
    }

    func testEnterInCopyModeYieldsCopy() {
        var m = makeModel([textSummary("a")], mode: .copy)
        let effect = m.reduce(.enter, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .copy(m.flat[0].id))
    }

    func testEnterWithNoSelectionYieldsNone() {
        var m = makeModel([])
        let effect = m.reduce(.enter, listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .none)
    }

    func testAltDigitsSelectNthVisibleClip() {
        var m = makeModel(manySummaries(5))
        let effect = m.reduce(.alt("3"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .paste(m.flat[2].id))
    }

    func testAltDigitOutOfRangeYieldsNone() {
        var m = makeModel([textSummary("a")])
        let effect = m.reduce(.alt("9"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .none)
    }

    func testCtrlPYieldsPin() {
        var m = makeModel([textSummary("a")])
        let effect = m.reduce(.ctrl("p"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .pin(m.flat[0].id))
    }

    func testCtrlDYieldsDelete() {
        var m = makeModel([textSummary("a")])
        let effect = m.reduce(.ctrl("d"), listHeight: 10, now: now, calendar: calendar)
        XCTAssertEqual(effect, .delete(m.flat[0].id))
    }

    func testEscapeAndCtrlCYieldCancel() {
        var m = makeModel([textSummary("a")])
        XCTAssertEqual(m.reduce(.escape, listHeight: 10, now: now, calendar: calendar), .cancel)
        XCTAssertEqual(m.reduce(.ctrl("c"), listHeight: 10, now: now, calendar: calendar), .cancel)
    }

    func testTabAndUnknownYieldNone() {
        var m = makeModel([textSummary("a")])
        XCTAssertEqual(m.reduce(.tab, listHeight: 10, now: now, calendar: calendar), .none)
        XCTAssertEqual(m.reduce(.unknown([0x1B]), listHeight: 10, now: now, calendar: calendar), .none)
    }

    // MARK: - Scroll

    func testScrollOffsetKeepsSelectionVisibleAcrossListHeight() {
        // All 20 clips land in a single "Today" section, so the section
        // header consumes one of the 5 available rows: only 4 clip rows
        // (flat indices 0...3) fit in the first window.
        var m = makeModel(manySummaries(20))
        XCTAssertEqual(m.scrollOffset, 0)

        for _ in 0..<3 {
            _ = m.reduce(.down, listHeight: 5, now: now, calendar: calendar)
        }
        XCTAssertEqual(m.state.selectedIndex, 3)
        XCTAssertEqual(m.scrollOffset, 0)

        _ = m.reduce(.down, listHeight: 5, now: now, calendar: calendar)
        // Selected index 4 no longer fits under the header in the window
        // that starts at flat index 0, so the view must scroll down.
        XCTAssertEqual(m.state.selectedIndex, 4)
        XCTAssertGreaterThan(m.scrollOffset, 0)
    }

    // MARK: - Replace

    func testReplaceKeepsSelectionOnSameIDAfterDeletingAnotherClip() {
        let a = textSummary("a", id: UUID())
        let b = textSummary("b", id: UUID())
        let c = textSummary("c", id: UUID())
        var m = makeModel([a, b, c])
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar) // select b
        XCTAssertEqual(m.selected?.id, b.id)

        m.replace(summaries: [a, c], now: now, calendar: calendar) // b deleted
        XCTAssertEqual(m.selected?.id, c.id)
    }

    func testReplaceClampsAfterDeletingSelectedClip() {
        let a = textSummary("a", id: UUID())
        let b = textSummary("b", id: UUID())
        var m = makeModel([a, b])
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar) // select b
        XCTAssertEqual(m.selected?.id, b.id)

        m.replace(summaries: [a], now: now, calendar: calendar) // b deleted
        XCTAssertEqual(m.selected?.id, a.id)
    }

    // MARK: - Status

    func testStatusClearedOnNextKey() {
        var m = makeModel([textSummary("a")])
        m.status = "That image is no longer in the archive"
        _ = m.reduce(.down, listHeight: 10, now: now, calendar: calendar)
        XCTAssertNil(m.status)
    }
}
