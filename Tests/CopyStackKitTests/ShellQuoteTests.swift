import XCTest
@testable import CopyStackKit

final class ShellQuoteTests: XCTestCase {
    func testPlainWordIsAlwaysQuoted() {
        XCTAssertEqual(ShellQuote.single("hello"), "'hello'")
    }

    func testPathWithSpaces() {
        XCTAssertEqual(ShellQuote.single("/tmp/my file.txt"), "'/tmp/my file.txt'")
    }

    func testPathWithSingleQuote() {
        XCTAssertEqual(ShellQuote.single("it's here"), "'it'\\''s here'")
    }

    func testEmptyString() {
        XCTAssertEqual(ShellQuote.single(""), "''")
    }
}
