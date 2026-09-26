import XCTest
@testable import CopyStackKit

final class TerminalAppTests: XCTestCase {
    func testEachVerifiedIDMaps() {
        XCTAssertEqual(TerminalApp.detect(bundleID: "com.mitchellh.ghostty"), .ghostty)
        XCTAssertEqual(TerminalApp.detect(bundleID: "com.cmuxterm.app"), .cmux)
        XCTAssertEqual(TerminalApp.detect(bundleID: "com.googlecode.iterm2"), .iterm2)
        XCTAssertEqual(TerminalApp.detect(bundleID: "net.kovidgoyal.kitty"), .kitty)
        XCTAssertEqual(TerminalApp.detect(bundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(TerminalApp.detect(bundleID: "dev.warp.Warp"), .warp)
    }

    func testCmuxDebugSuffix() {
        XCTAssertEqual(TerminalApp.detect(bundleID: "com.cmuxterm.app.debug.imperum"), .cmux)
    }

    func testWarpChannelSuffixes() {
        XCTAssertEqual(TerminalApp.detect(bundleID: "dev.warp.Warp-Stable"), .warp)
        XCTAssertEqual(TerminalApp.detect(bundleID: "dev.warp.Warp-Preview"), .warp)
    }

    func testTerminalExact() {
        XCTAssertEqual(TerminalApp.detect(bundleID: "com.apple.Terminal"), .terminal)
    }

    func testNonTerminalIsNil() {
        XCTAssertNil(TerminalApp.detect(bundleID: "com.apple.TextEdit"))
    }

    func testBoundaryCheckRejectsPartialMatch() {
        XCTAssertNil(TerminalApp.detect(bundleID: "com.mitchellh.ghosttyx"))
    }

    func testNilBundleIDIsNil() {
        XCTAssertNil(TerminalApp.detect(bundleID: nil))
    }

    func testSupportsPicker() {
        for app in TerminalApp.allCases {
            XCTAssertEqual(app.supportsPicker, app != .warp)
        }
    }

    func testDisplayNames() {
        XCTAssertEqual(TerminalApp.ghostty.displayName, "Ghostty")
        XCTAssertEqual(TerminalApp.cmux.displayName, "cmux")
        XCTAssertEqual(TerminalApp.iterm2.displayName, "iTerm2")
        XCTAssertEqual(TerminalApp.kitty.displayName, "Kitty")
        XCTAssertEqual(TerminalApp.terminal.displayName, "Terminal")
        XCTAssertEqual(TerminalApp.warp.displayName, "Warp")
    }
}
