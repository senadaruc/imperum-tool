// Tests/ImperumCoreTests/ClipClassifierTests.swift
import Foundation
import XCTest
@testable import ImperumCore

final class ClipClassifierTests: XCTestCase {
    func testEmptyOrWhitespaceIsDropped() {
        XCTAssertNil(ClipClassifier.classifyText(""))
        XCTAssertNil(ClipClassifier.classifyText("  \n\t "))
    }

    func testLinks() {
        XCTAssertEqual(ClipClassifier.classifyText("https://imperum.ai/x?y=1"), .link)
        XCTAssertEqual(ClipClassifier.classifyText("http://localhost:3000"), .link)
        XCTAssertEqual(ClipClassifier.classifyText("https://a b.com"), .text)      // whitespace → not a link
        XCTAssertEqual(ClipClassifier.classifyText("ftp://x.com/f"), .text)       // only http(s)
        XCTAssertEqual(ClipClassifier.classifyText("imperum.ai"), .text)          // no scheme
    }

    func testEmails() {
        XCTAssertEqual(ClipClassifier.classifyText("senad@imperum.io"), .email)
        XCTAssertEqual(ClipClassifier.classifyText("a@b"), .text)
        XCTAssertEqual(ClipClassifier.classifyText("mail me: a@b.co"), .text)
    }

    func testColors() {
        XCTAssertEqual(ClipClassifier.classifyText("#fff"), .color)
        XCTAssertEqual(ClipClassifier.classifyText("#FF00AA80"), .color)
        XCTAssertEqual(ClipClassifier.classifyText("rgb(1, 2, 3)"), .color)
        XCTAssertEqual(ClipClassifier.classifyText("hsla(1,2%,3%,0.5)"), .color)
        XCTAssertEqual(ClipClassifier.classifyText("#ggg"), .text)
        XCTAssertEqual(ClipClassifier.normalizedColorHex("#fff"), "#FFFFFF")
        XCTAssertEqual(ClipClassifier.normalizedColorHex("rgb(255, 0, 128)"), "#FF0080")
        XCTAssertNil(ClipClassifier.normalizedColorHex("hello"))
    }

    func testPlainText() {
        XCTAssertEqual(ClipClassifier.classifyText("hello world"), .text)
    }

    func testFilesAndVideos() {
        XCTAssertEqual(ClipClassifier.kindForFile(URL(fileURLWithPath: "/tmp/movie.mov")), .video)
        XCTAssertEqual(ClipClassifier.kindForFile(URL(fileURLWithPath: "/tmp/clip.mp4")), .video)
        XCTAssertEqual(ClipClassifier.kindForFile(URL(fileURLWithPath: "/tmp/package.json")), .file)
        XCTAssertEqual(ClipClassifier.kindForFile(URL(fileURLWithPath: "/tmp/noext")), .file)
    }

    func testTitles() {
        XCTAssertEqual(ClipClassifier.title(forText: "  first line \nsecond"), "first line")
        XCTAssertEqual(ClipClassifier.title(forText: String(repeating: "a", count: 500)).count, 120)
        XCTAssertEqual(ClipClassifier.title(forText: "\n\n  x"), "x")
        XCTAssertEqual(ClipClassifier.title(forFiles: [URL(fileURLWithPath: "/a/package.json")]), "package.json")
        XCTAssertEqual(ClipClassifier.title(forFiles: [URL(fileURLWithPath: "/a/one"), URL(fileURLWithPath: "/a/two")]), "one +1 more")
        XCTAssertEqual(ClipClassifier.title(imageWidth: 256, height: 256), "Image 256×256")
        // CRLF (and lone CR) must be recognised as a line break, not just "\n".
        XCTAssertEqual(ClipClassifier.title(forText: "first\r\nsecond"), "first")
        // 9 whitespace-only lines, then the real content.
        let manyBlankLines = String(repeating: "   \n", count: 9) + "a\nb"
        XCTAssertEqual(ClipClassifier.title(forText: manyBlankLines), "a")
    }

    /// Regression test: must fail before the fix (unbounded scan of the
    /// first line) and pass after it (bounded to `maxTitleLength`).
    /// `measure` alone can't fail without a stored baseline, so this uses a
    /// hard wall-clock bound instead.
    func testTitleOfHugeSingleLineIsFast() {
        let huge = String(repeating: "x", count: 50_000_000) // no newline at all
        let start = DispatchTime.now()
        let result = ClipClassifier.title(forText: huge)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        XCTAssertEqual(result.count, 120)
        XCTAssertLessThan(elapsedSeconds, 0.010, "title(forText:) must not scan the whole input")
    }

    func testClassifyHugeStringsAreFast() {
        let hugeLink = "https://x.io/" + String(repeating: "a", count: 5_000_000)
        XCTAssertEqual(ClipClassifier.classifyText(hugeLink), .text)
        let hugeWhitespace = String(repeating: " ", count: 5_000_000)
        XCTAssertNil(ClipClassifier.classifyText(hugeWhitespace))
    }

    /// A modest run of leading whitespace must still be skipped correctly.
    func testTitleSkipsLeadingWhitespaceOnly() {
        let text = String(repeating: " ", count: 100) + "content\nrest"
        XCTAssertEqual(ClipClassifier.title(forText: text), "content")
    }

    /// Regression test: must fail before the fix (unbounded leading-whitespace
    /// skip) and pass after it (bounded to maxLeadingWhitespaceScan). 5 MB of
    /// whitespace/blank lines with no real content within the scan cap must
    /// return "" almost instantly, not walk the whole 5 MB looking for content
    /// that is never found.
    func testTitleOfHugeLeadingWhitespaceIsFast() {
        let leading = String(repeating: " \n", count: 2_500_000) // 5,000,000 whitespace Characters
        let huge = leading + "content"
        let start = DispatchTime.now()
        let result = ClipClassifier.title(forText: huge)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        XCTAssertEqual(result, "")
        XCTAssertLessThan(elapsedSeconds, 0.010, "title(forText:) must not scan the whole leading whitespace run")
    }
}
