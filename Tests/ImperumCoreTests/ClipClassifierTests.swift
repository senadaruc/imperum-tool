// Tests/ImperumCoreTests/ClipClassifierTests.swift
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
    }

    func testTitleOfHugeTextIsFast() {
        let huge = String(repeating: "x", count: 5_000_000) + "\nrest"
        measure { _ = ClipClassifier.title(forText: huge) }
        XCTAssertEqual(ClipClassifier.title(forText: huge).count, 120)
    }
}
