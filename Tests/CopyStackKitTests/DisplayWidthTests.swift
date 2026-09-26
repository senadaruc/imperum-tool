import XCTest
@testable import CopyStackKit

final class DisplayWidthTests: XCTestCase {
    func testASCIIWidthOne() {
        XCTAssertEqual(DisplayWidth.of("a"), 1)
        XCTAssertEqual(DisplayWidth.of("hello"), 5)
        XCTAssertEqual(DisplayWidth.of(" "), 1)
    }

    func testWideCJK() {
        XCTAssertEqual(DisplayWidth.of("日本"), 4)
    }

    func testCombiningMarkZeroWidth() {
        // "é" built as e + combining acute accent (U+0301)
        let s = "e\u{0301}"
        XCTAssertEqual(DisplayWidth.of(s), 1)
    }

    func testZWJFamilyEmoji() {
        // man + ZWJ + woman + ZWJ + girl
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(DisplayWidth.of(family), 2)
    }

    func testControlCharsZeroWidth() {
        XCTAssertEqual(DisplayWidth.of(Unicode.Scalar(0x01)!), 0)
        XCTAssertEqual(DisplayWidth.of(Unicode.Scalar(0x7f)!), 0)
    }

    func testTruncateCJK() {
        XCTAssertEqual(DisplayWidth.truncate("日本語テキスト", to: 5), "日本…")
    }

    func testTruncateNeverExceedsColumns() {
        let result = DisplayWidth.truncate("日本語テキスト", to: 5)
        XCTAssertLessThanOrEqual(DisplayWidth.of(result), 5)
    }

    func testTruncateNeverSplitsGrapheme() {
        // family emoji is a single grapheme cluster of width 2; truncating to 1
        // column must not emit a broken half of it.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let result = DisplayWidth.truncate(family, to: 1)
        XCTAssertEqual(result, "…")
    }

    func testTruncateZeroOrNegativeColumns() {
        XCTAssertEqual(DisplayWidth.truncate("hello", to: 0), "")
        XCTAssertEqual(DisplayWidth.truncate("hello", to: -1), "")
    }

    func testTruncateFitsExactlyNoEllipsis() {
        XCTAssertEqual(DisplayWidth.truncate("hello", to: 5), "hello")
    }

    func testPadExactness() {
        let padded = DisplayWidth.pad("hi", to: 5)
        XCTAssertEqual(padded, "hi   ")
        XCTAssertEqual(DisplayWidth.of(padded), 5)
    }

    func testPadTruncatesFirstIfTooLong() {
        let padded = DisplayWidth.pad("hello world", to: 5)
        XCTAssertEqual(DisplayWidth.of(padded), 5)
    }
}
