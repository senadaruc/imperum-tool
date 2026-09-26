import XCTest
@testable import CopyStackKit

final class SanitizeTests: XCTestCase {
    func testPlainTextUnchanged() {
        XCTAssertEqual(Sanitize.line("hello world"), "hello world")
    }

    func testEscapeColorSequenceCollapses() {
        let s = "before\u{1B}[31mred\u{1B}[0mafter"
        let result = Sanitize.line(s)
        XCTAssertFalse(result.contains("\u{1B}"))
        XCTAssertFalse(result.contains("31"))
        XCTAssertTrue(result.contains("·"))
        XCTAssertEqual(result, "before·red·after")
    }

    func testBELCollapses() {
        let s = "a\u{07}b"
        XCTAssertEqual(Sanitize.line(s), "a·b")
    }

    func testC1CSICollapses() {
        // U+009B is the single-byte CSI introducer (C1 control).
        let s = "a\u{9B}31mb"
        let result = Sanitize.line(s)
        XCTAssertFalse(result.contains("\u{9B}"))
        XCTAssertTrue(result.contains("·"))
    }

    func testOSC52PayloadDoesNotLeak() {
        // OSC 52 clipboard-write: ESC ] 52 ; c ; <base64> BEL
        let s = "before\u{1B}]52;c;aGVsbG8=\u{07}after"
        let result = Sanitize.line(s)
        XCTAssertFalse(result.contains("aGVsbG8"))
        XCTAssertFalse(result.contains("52"))
        XCTAssertFalse(result.contains("\u{1B}"))
        XCTAssertEqual(result, "before·after")
    }

    func testNewlineBecomesSymbol() {
        XCTAssertEqual(Sanitize.line("a\nb"), "a⏎b")
    }

    func testCRLFBecomesSymbol() {
        XCTAssertEqual(Sanitize.line("a\r\nb"), "a⏎b")
    }

    func testTabBecomesFourSpaces() {
        XCTAssertEqual(Sanitize.line("a\tb"), "a    b")
    }

    func testLinesSplitsAndCapsAtMax() {
        XCTAssertEqual(Sanitize.lines("a\nb\nc", max: 2), ["a", "b"])
    }

    func testLinesDropsSingleTrailingEmptyLineFromTrailingNewline() {
        XCTAssertEqual(Sanitize.lines("a\nb\n", max: 10), ["a", "b"])
    }

    func testLinesKeepsInteriorEmptyLines() {
        XCTAssertEqual(Sanitize.lines("a\n\nb", max: 10), ["a", "", "b"])
    }

    func testLinesSanitizesEachLine() {
        let result = Sanitize.lines("a\u{1B}[31mb\nc\td", max: 10)
        XCTAssertEqual(result, ["a·b", "c    d"])
    }
}
