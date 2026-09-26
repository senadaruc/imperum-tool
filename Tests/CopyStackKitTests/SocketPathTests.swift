import XCTest
@testable import CopyStackKit

final class SocketPathTests: XCTestCase {
    func testDefaultPath() {
        let path = SocketPath.resolve(home: "/Users/alice", tmp: "/tmp", environment: [:])
        XCTAssertEqual(path, "/Users/alice/Library/Application Support/Imperum Tool/copystack.sock")
    }

    func testEnvOverrideWins() {
        let path = SocketPath.resolve(
            home: "/Users/alice", tmp: "/tmp",
            environment: [SocketPath.envOverride: "/custom/path.sock"]
        )
        XCTAssertEqual(path, "/custom/path.sock")
    }

    func testLongHomeFallsBackToTmp() {
        let longHome = "/Users/" + String(repeating: "a", count: 200)
        let path = SocketPath.resolve(home: longHome, tmp: "/tmp", environment: [:])
        XCTAssertEqual(path, "/tmp/io.imperum.tool.copystack.sock")
    }

    func testResultNeverExceedsMaxLength() {
        let longHome = "/Users/" + String(repeating: "b", count: 500)
        let path = SocketPath.resolve(home: longHome, tmp: "/tmp", environment: [:])
        XCTAssertLessThanOrEqual(path.utf8.count, SocketPath.maxLength)

        let defaultPath = SocketPath.resolve(home: "/Users/alice", tmp: "/tmp", environment: [:])
        XCTAssertLessThanOrEqual(defaultPath.utf8.count, SocketPath.maxLength)
    }
}
