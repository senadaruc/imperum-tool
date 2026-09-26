import XCTest
@testable import ImperumCore

final class PanelStateTests: XCTestCase {
    private func clips(_ n: Int, kind: ClipKind = .text) -> [Clip] {
        (0..<n).map { Clip(kind: kind, capturedAt: Date(timeIntervalSince1970: TimeInterval(1000 - $0)),
                          sourceAppName: "A", sourceBundleID: nil, title: "c\($0)", payload: .text("c\($0)")) }
    }

    func testVisibleFlattensSectionsInOrderAndSelectionClamps() {
        var st = PanelState()
        var all = clips(3)
        all[2].isPinned = true
        let v = st.visible(from: all, now: Date(timeIntervalSince1970: 1000), calendar: .current)
        XCTAssertEqual(v.flat.map(\.title), ["c2", "c0", "c1"])       // pinned first, then newest
        st.selectedIndex = 10
        st.clampSelection(count: v.flat.count)
        XCTAssertEqual(st.selectedIndex, 2)
    }

    func testMoveSelectionDoesNotWrap() {
        var st = PanelState()
        st.moveSelection(by: -1, count: 3); XCTAssertEqual(st.selectedIndex, 0)
        st.moveSelection(by: 1, count: 3);  XCTAssertEqual(st.selectedIndex, 1)
        st.moveSelection(by: 5, count: 3);  XCTAssertEqual(st.selectedIndex, 2)
        st.moveSelection(by: 1, count: 0);  XCTAssertEqual(st.selectedIndex, 0)
    }

    func testCycleCategoryWrapsAndResetsSelection() {
        var st = PanelState()
        st.selectedIndex = 2
        st.cycleCategory(by: -1)
        XCTAssertEqual(st.category, .files)
        XCTAssertEqual(st.selectedIndex, 0)
        st.cycleCategory(by: 1)
        XCTAssertEqual(st.category, .all)
    }

    func testQueryChangeResetsSelection() {
        var st = PanelState()
        st.selectedIndex = 4
        st.setQuery("abc")
        XCTAssertEqual(st.query, "abc")
        XCTAssertEqual(st.selectedIndex, 0)
    }

    func testResetClearsEverything() {
        var st = PanelState(); st.setQuery("q"); st.cycleCategory(by: 1); st.selectedIndex = 3
        st.reset()
        XCTAssertEqual(st, PanelState())
    }
}
