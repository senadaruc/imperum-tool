import XCTest
@testable import ImperumCore

final class PanelPlacementTests: XCTestCase {
    // A 1440×900 main display with a 25 pt menu bar: visibleFrame in Cocoa coords.
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 520, height: 380)

    func testCaretMidScreenOpensBelowWithArrowOnTop() throws {
        let caret = CGRect(x: 700, y: 600, width: 1, height: 18)
        let p = try XCTUnwrap(PanelPlacement.place(caret: caret, panelSize: size, screen: screen))
        XCTAssertEqual(p.arrowEdge, .top)
        XCTAssertEqual(p.frame.size, CGSize(width: 520, height: 390))   // +10 arrow strip
        XCTAssertEqual(p.frame.maxY, 600 - 6, accuracy: 0.01)           // gap below the caret
        XCTAssertEqual(p.frame.midX, caret.midX, accuracy: 0.01)
        XCTAssertEqual(p.arrowX, 260, accuracy: 0.01)
    }

    func testCaretNearBottomFlipsAboveWithArrowAtBottom() throws {
        // The chat-box case: caret 60 pt from the bottom of the screen.
        let caret = CGRect(x: 700, y: 60, width: 1, height: 18)
        let p = try XCTUnwrap(PanelPlacement.place(caret: caret, panelSize: size, screen: screen))
        XCTAssertEqual(p.arrowEdge, .bottom)
        XCTAssertEqual(p.frame.minY, caret.maxY + 6, accuracy: 0.01)
        XCTAssertTrue(screen.contains(p.frame))
    }

    func testClampsToLeftEdgeAndArrowStillPointsAtCaret() throws {
        let caret = CGRect(x: 40, y: 600, width: 1, height: 18)
        let p = try XCTUnwrap(PanelPlacement.place(caret: caret, panelSize: size, screen: screen))
        XCTAssertEqual(p.frame.minX, screen.minX)
        XCTAssertEqual(p.arrowX, 40.5, accuracy: 0.01)
    }

    func testClampsToRightEdge() throws {
        let caret = CGRect(x: 1400, y: 600, width: 1, height: 18)
        let p = try XCTUnwrap(PanelPlacement.place(caret: caret, panelSize: size, screen: screen))
        XCTAssertEqual(p.frame.maxX, screen.maxX)
        XCTAssertEqual(p.frame.minX + p.arrowX, 1400.5, accuracy: 0.01)
    }

    func testArrowNeverEntersTheRoundedCorners() throws {
        let caret = CGRect(x: 2, y: 600, width: 1, height: 18)
        let p = try XCTUnwrap(PanelPlacement.place(caret: caret, panelSize: size, screen: screen))
        XCTAssertEqual(p.arrowX, 12 + 10, accuracy: 0.01)     // cornerRadius + arrowHalfWidth
        let far = CGRect(x: 1439, y: 600, width: 1, height: 18)
        let q = try XCTUnwrap(PanelPlacement.place(caret: far, panelSize: size, screen: screen))
        XCTAssertEqual(q.arrowX, 520 - 22, accuracy: 0.01)
    }

    func testNeitherSideFitsPicksTheRoomierOneAndStaysOnScreen() throws {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 400)
        let caret = CGRect(x: 400, y: 150, width: 1, height: 18)   // 150 below, 232 above
        let p = try XCTUnwrap(PanelPlacement.place(caret: caret, panelSize: size, screen: tiny))
        XCTAssertEqual(p.arrowEdge, .bottom)
        XCTAssertTrue(tiny.contains(p.frame))
    }

    func testCaretOffScreenReturnsNil() {
        XCTAssertNil(PanelPlacement.place(caret: CGRect(x: 2000, y: 100, width: 1, height: 18), panelSize: size, screen: screen))
        XCTAssertNil(PanelPlacement.place(caret: CGRect(x: 100, y: -50, width: 1, height: 18), panelSize: size, screen: screen))
    }

    func testZeroWidthCaretIsStillPlaced() {
        XCTAssertNotNil(PanelPlacement.place(caret: CGRect(x: 100, y: 100, width: 0, height: 18), panelSize: size, screen: screen))
    }

    // MARK: AX → Cocoa

    func testAXRectFlipsAgainstThePrimaryScreen() {
        // AX: 20 pt below the top of a 900 pt primary screen, 18 tall → Cocoa y = 900 - 38.
        let r = AXCoordinates.cocoaRect(CGRect(x: 10, y: 20, width: 1, height: 18), primaryScreenHeight: 900)
        XCTAssertEqual(r, CGRect(x: 10, y: 862, width: 1, height: 18))
    }

    // MARK: Range candidates

    func testEmptySelectionMidTextTriesCaretThenPreviousThenEmpty() {
        XCTAssertEqual(PanelPlacement.caretRangeCandidates(location: 5, length: 0, textLength: 10),
                       [NSRange(location: 5, length: 1), NSRange(location: 4, length: 1), NSRange(location: 5, length: 0)])
    }

    func testEmptySelectionAtStartSkipsThePreviousChar() {
        XCTAssertEqual(PanelPlacement.caretRangeCandidates(location: 0, length: 0, textLength: 10),
                       [NSRange(location: 0, length: 1), NSRange(location: 0, length: 0)])
    }

    func testEmptySelectionAtEndSkipsTheCaretChar() {
        XCTAssertEqual(PanelPlacement.caretRangeCandidates(location: 10, length: 0, textLength: 10),
                       [NSRange(location: 9, length: 1), NSRange(location: 10, length: 0)])
    }

    func testUnknownTextLengthTriesEverything() {
        XCTAssertEqual(PanelPlacement.caretRangeCandidates(location: 3, length: 0, textLength: nil),
                       [NSRange(location: 3, length: 1), NSRange(location: 2, length: 1), NSRange(location: 3, length: 0)])
    }

    func testRealSelectionComesFirst() {
        XCTAssertEqual(PanelPlacement.caretRangeCandidates(location: 2, length: 4, textLength: 10).first,
                       NSRange(location: 2, length: 4))
    }
}
