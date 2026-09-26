import XCTest
@testable import CopyStackKit

final class CLIArgsTests: XCTestCase {
    func testNoArgsIsStdout() {
        let result = CLIArgs.parse([])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .stdout))
    }

    func testPaste() {
        let result = CLIArgs.parse(["--paste"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .paste))
    }

    func testCopy() {
        let result = CLIArgs.parse(["--copy"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .copy))
    }

    func testPickWithSession() {
        let result = CLIArgs.parse(["--pick", "--session", "deadbeef"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .pick(session: "deadbeef")))
    }

    func testPickWithSessionOrderIndependent() {
        let result = CLIArgs.parse(["--session", "deadbeef", "--pick"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .pick(session: "deadbeef")))
    }

    func testPickWithoutSessionIsError() {
        let result = CLIArgs.parse(["--pick"])
        XCTAssertThrowsResultError(result)
    }

    func testSessionWithoutPickIsError() {
        let result = CLIArgs.parse(["--session", "deadbeef"])
        XCTAssertThrowsResultError(result)
    }

    func testListBare() {
        let result = CLIArgs.parse(["list"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .list(json: false, limit: nil)))
    }

    func testListJSON() {
        let result = CLIArgs.parse(["list", "--json"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .list(json: true, limit: nil)))
    }

    func testListLimit() {
        let result = CLIArgs.parse(["list", "--limit", "10"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .list(json: false, limit: 10)))
    }

    func testListJSONAndLimit() {
        let result = CLIArgs.parse(["list", "--json", "--limit", "5"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .list(json: true, limit: 5)))
    }

    func testListInvalidLimitIsError() {
        let result = CLIArgs.parse(["list", "--limit", "notanumber"])
        XCTAssertThrowsResultError(result)
    }

    func testVersion() {
        let result = CLIArgs.parse(["--version"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .version))
    }

    func testHelpLong() {
        let result = CLIArgs.parse(["--help"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .help))
    }

    func testHelpShort() {
        let result = CLIArgs.parse(["-h"])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .help))
    }

    func testUnknownFlagIsError() {
        let result = CLIArgs.parse(["--bogus"])
        XCTAssertThrowsResultError(result)
    }

    func testUnknownListFlagIsError() {
        let result = CLIArgs.parse(["list", "--bogus"])
        XCTAssertThrowsResultError(result)
    }

    func testListLimitZeroIsError() {
        let result = CLIArgs.parse(["list", "--limit", "0"])
        XCTAssertThrowsResultError(result)
    }

    func testListLimitNegativeIsError() {
        let result = CLIArgs.parse(["list", "--limit", "-1"])
        XCTAssertThrowsResultError(result)
    }

    func testPasteAndCopyTogetherIsError() {
        let result = CLIArgs.parse(["--paste", "--copy"])
        XCTAssertThrowsResultError(result)
    }

    func testSessionTooShortIsError() {
        let result = CLIArgs.parse(["--pick", "--session", "beef"])
        XCTAssertThrowsResultError(result)
    }

    func testSessionTooLongIsError() {
        let result = CLIArgs.parse(["--pick", "--session", String(repeating: "a", count: 65)])
        XCTAssertThrowsResultError(result)
    }

    func testSessionNonHexIsError() {
        let result = CLIArgs.parse(["--pick", "--session", "not-hex!"])
        XCTAssertThrowsResultError(result)
    }

    func testSessionExactly64HexIsValid() {
        let session = String(repeating: "a", count: 64)
        let result = CLIArgs.parse(["--pick", "--session", session])
        XCTAssertEqual(try? result.get(), CLIArgs(mode: .pick(session: session)))
    }
}

private func XCTAssertThrowsResultError(
    _ result: Result<CLIArgs, String>, file: StaticString = #filePath, line: UInt = #line
) {
    switch result {
    case .success:
        XCTFail("expected an error", file: file, line: line)
    case .failure(let message):
        XCTAssertFalse(message.isEmpty, "expected a non-empty error message", file: file, line: line)
    }
}
