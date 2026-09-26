import XCTest
@testable import CopyStackKit

final class KeyParserTests: XCTestCase {
    func testPrintableChar() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("a".utf8)), [.char("a")])
    }

    func testEnterCRAndLF() {
        var p = KeyParser()
        XCTAssertEqual(p.feed([0x0d]), [.enter])
        XCTAssertEqual(p.feed([0x0a]), [.enter])
    }

    func testBackspace() {
        var p = KeyParser()
        XCTAssertEqual(p.feed([0x7f]), [.backspace])
        XCTAssertEqual(p.feed([0x08]), [.backspace])
    }

    func testTab() {
        var p = KeyParser()
        XCTAssertEqual(p.feed([0x09]), [.tab])
    }

    func testArrowKeysCSI() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("\u{1B}[A".utf8)), [.up])
        XCTAssertEqual(p.feed(Array("\u{1B}[B".utf8)), [.down])
        XCTAssertEqual(p.feed(Array("\u{1B}[C".utf8)), [.right])
        XCTAssertEqual(p.feed(Array("\u{1B}[D".utf8)), [.left])
    }

    func testArrowKeysSS3() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("\u{1B}OA".utf8)), [.up])
        XCTAssertEqual(p.feed(Array("\u{1B}OB".utf8)), [.down])
        XCTAssertEqual(p.feed(Array("\u{1B}OC".utf8)), [.right])
        XCTAssertEqual(p.feed(Array("\u{1B}OD".utf8)), [.left])
    }

    func testPageUpDown() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("\u{1B}[5~".utf8)), [.pageUp])
        XCTAssertEqual(p.feed(Array("\u{1B}[6~".utf8)), [.pageDown])
    }

    func testHomeEnd() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("\u{1B}[H".utf8)), [.home])
        XCTAssertEqual(p.feed(Array("\u{1B}[F".utf8)), [.end])
        XCTAssertEqual(p.feed(Array("\u{1B}[1~".utf8)), [.home])
        XCTAssertEqual(p.feed(Array("\u{1B}[4~".utf8)), [.end])
    }

    func testCtrlLetters() {
        var p = KeyParser()
        XCTAssertEqual(p.feed([0x03]), [.ctrl("c")])
        XCTAssertEqual(p.feed([0x01]), [.ctrl("a")])
        XCTAssertEqual(p.feed([0x10]), [.ctrl("p")])
        XCTAssertEqual(p.feed([0x04]), [.ctrl("d")])
        XCTAssertEqual(p.feed([0x15]), [.ctrl("u")])
        XCTAssertEqual(p.feed([0x0e]), [.ctrl("n")])
        XCTAssertEqual(p.feed([0x0b]), [.ctrl("k")])
        // ctrl-j (0x0a) is indistinguishable from LF/enter; \n maps to .enter per spec.
    }

    func testAltPrintable() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("\u{1B}x".utf8)), [.alt("x")])
        XCTAssertEqual(p.feed(Array("\u{1B}1".utf8)), [.alt("1")])
    }

    func testAltAcrossFeeds() {
        var p = KeyParser()
        XCTAssertEqual(p.feed([0x1B]), [])
        XCTAssertTrue(p.hasPendingEscape)
        XCTAssertEqual(p.feed(Array("x".utf8)), [.alt("x")])
        XCTAssertFalse(p.hasPendingEscape)
    }

    func testLoneEscapeThenFlush() {
        var p = KeyParser()
        XCTAssertEqual(p.feed([0x1B]), [])
        XCTAssertTrue(p.hasPendingEscape)
        XCTAssertEqual(p.flushTimeout(), [.escape])
        XCTAssertFalse(p.hasPendingEscape)
    }

    func testSplitCSISequenceAcrossFeeds() {
        var p = KeyParser()
        XCTAssertEqual(p.feed([0x1B]), [])
        XCTAssertEqual(p.feed(Array("[A".utf8)), [.up])
    }

    func testSplitCSIMidSequence() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("\u{1B}[".utf8)), [])
        XCTAssertEqual(p.feed(Array("A".utf8)), [.up])
    }

    func testUnknownCSISequence() {
        var p = KeyParser()
        let bytes = Array("\u{1B}[?25h".utf8)
        XCTAssertEqual(p.feed(bytes), [.unknown(bytes)])
    }

    func testBracketedPasteSingleFeed() {
        var p = KeyParser()
        let seq = "\u{1B}[200~hello world\u{1B}[201~"
        XCTAssertEqual(p.feed(Array(seq.utf8)), [.paste("hello world")])
    }

    func testBracketedPasteSpanningThreeFeeds() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("\u{1B}[200~line1\n".utf8)), [])
        XCTAssertEqual(p.feed(Array("line2\n".utf8)), [])
        XCTAssertEqual(p.feed(Array("line3\u{1B}[201~".utf8)), [.paste("line1\nline2\nline3")])
    }

    func testUTF8ThreeByteCharSplit1Plus2() {
        var p = KeyParser()
        // "日" U+65E5 = E6 97 A5
        let bytes: [UInt8] = [0xE6, 0x97, 0xA5]
        XCTAssertEqual(p.feed([bytes[0]]), [])
        XCTAssertEqual(p.feed([bytes[1], bytes[2]]), [.char("日")])
    }

    func testMultipleCharsInOneFeed() {
        var p = KeyParser()
        XCTAssertEqual(p.feed(Array("ab".utf8)), [.char("a"), .char("b")])
    }
}
