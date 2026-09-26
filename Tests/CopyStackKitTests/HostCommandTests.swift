import XCTest
@testable import CopyStackKit

final class HostCommandTests: XCTestCase {
    let copystackPath = "/Applications/Imperum Tool.app/Contents/Resources/copystack"
    let session = "abc123def456"
    let bundleURL = "/Applications/Ghostty.app"

    func testPickerCommand() {
        XCTAssertEqual(
            HostCommand.pickerCommand(copystackPath: copystackPath, session: session),
            "exec '/Applications/Imperum Tool.app/Contents/Resources/copystack' --pick --session abc123def456"
        )
    }

    func testPickerCommandQuotesSpaceAndSingleQuote() {
        XCTAssertEqual(
            HostCommand.pickerCommand(copystackPath: "/tmp/o'reilly copystack", session: "xyz"),
            "exec '/tmp/o'\\''reilly copystack' --pick --session xyz"
        )
    }

    func testWindowTitle() {
        XCTAssertEqual(HostCommand.windowTitle(session: "abc123def456"), "Copy Stack · abc123")
    }

    func testWindowTitleShortSession() {
        XCTAssertEqual(HostCommand.windowTitle(session: "ab"), "Copy Stack · ab")
    }

    // MARK: Ghostty

    func testGhosttyLaunch() {
        let launches = HostCommand.launch(for: .ghostty, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/Ghostty.app")
        XCTAssertEqual(launches.count, 2)
        let cmd = HostCommand.pickerCommand(copystackPath: copystackPath, session: session)
        XCTAssertEqual(launches[0].kind, .appleScript(source: """
        tell application id "com.mitchellh.ghostty"
            set cfg to new surface configuration
            set command of cfg to "shell:\(cmd)"
            set wait after command of cfg to false
            set w to new window with configuration cfg
            return id of w
        end tell
        """))
        XCTAssertEqual(launches[1].kind, .openApp(bundleURL: "/Applications/Ghostty.app", arguments: [
            "--window-width=100", "--window-height=30",
            "--title=\(HostCommand.windowTitle(session: session))",
            "--window-save-state=never", "--confirm-close-surface=false",
            "-e", copystackPath, "--pick", "--session", session,
        ]))
        if case .openApp(_, let args) = launches[1].kind {
            XCTAssertEqual(args.last, session)
            XCTAssertEqual(args[args.count - 5], "-e")
        }
    }

    func testGhosttyLaunchEscapesInnerDoubleQuotes() {
        let launches = HostCommand.launch(for: .ghostty, copystackPath: "/tmp/\"weird\"/copystack", session: session,
                                           bundleURL: "/Applications/Ghostty.app")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains(#"\"weird\""#), "expected escaped inner double quotes, got: \(source)")
    }

    // MARK: cmux

    func testCmuxLaunchWithCLI() {
        let launches = HostCommand.launch(for: .cmux, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/cmux.app", cmuxCLI: "/path/to/cmux")
        let cmd = HostCommand.pickerCommand(copystackPath: copystackPath, session: session)
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches[0].kind, .cli(executable: "/path/to/cmux", argv: [
            ["new-window"],
            ["send", "--window", "{WINDOW}", " \(cmd)\n"],
        ]))
        XCTAssertEqual(launches[1].kind, .appleScript(source: """
        tell application id "com.cmuxterm.app"
            set w to new window
            perform action "text: \(cmd)" & return on focused terminal of selected tab of w
            return id of w
        end tell
        """))
    }

    func testCmuxLaunchEscapesInnerDoubleQuotesInAppleScriptFallback() {
        let launches = HostCommand.launch(for: .cmux, copystackPath: "/tmp/\"weird\"/copystack", session: session,
                                           bundleURL: "/Applications/cmux.app")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains(#"\"weird\""#), "expected escaped inner double quotes, got: \(source)")
    }

    func testCmuxLaunchWithoutCLIOnlyHasAppleScriptFallback() {
        let launches = HostCommand.launch(for: .cmux, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/cmux.app")
        XCTAssertEqual(launches.count, 1)
        if case .appleScript = launches[0].kind {} else { XCTFail("expected appleScript fallback") }
    }

    // MARK: iTerm2

    func testIterm2Launch() {
        let launches = HostCommand.launch(for: .iterm2, copystackPath: copystackPath, session: session,
                                           cols: 120, rows: 40, bundleURL: "/Applications/iTerm.app")
        let cmd = HostCommand.pickerCommand(copystackPath: copystackPath, session: session)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches[0].kind, .appleScript(source: """
        tell application id "com.googlecode.iterm2"
            set w to create window with default profile command "\(cmd)"
            tell current session of w
                set columns to 120
                set rows to 40
            end tell
            return id of w
        end tell
        """))
    }

    func testIterm2LaunchEscapesInnerDoubleQuotes() {
        let launches = HostCommand.launch(for: .iterm2, copystackPath: "/tmp/\"weird\"/copystack", session: session,
                                           bundleURL: "/Applications/iTerm.app")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains(#"\"weird\""#), "expected escaped inner double quotes, got: \(source)")
    }

    // MARK: kitty

    func testKittyLaunch() {
        let launches = HostCommand.launch(for: .kitty, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/kitty.app")
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches[0].kind, .openApp(bundleURL: "/Applications/kitty.app", arguments: [
            "-o", "initial_window_width=100c",
            "-o", "initial_window_height=30c",
            "-o", "remember_window_size=no",
            "-o", "macos_quit_when_last_window_closed=yes",
            "-o", "confirm_os_window_close=0",
            "--title", HostCommand.windowTitle(session: session),
            copystackPath, "--pick", "--session", session,
        ]))
    }

    // MARK: Terminal

    func testTerminalLaunch() {
        let launches = HostCommand.launch(for: .terminal, copystackPath: copystackPath, session: session,
                                           bundleURL: "/System/Applications/Utilities/Terminal.app")
        let cmd = HostCommand.pickerCommand(copystackPath: copystackPath, session: session)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches[0].kind, .appleScript(source: """
        tell application id "com.apple.Terminal"
            set t to do script "\(cmd)"
            set number of columns of t to 100
            set number of rows of t to 30
            return id of front window
        end tell
        """))
    }

    // MARK: Warp

    func testWarpLaunchIsEmpty() {
        XCTAssertEqual(HostCommand.launch(for: .warp, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/Warp.app"), [])
    }

    // MARK: closeScript

    func testCloseScriptGhostty() {
        XCTAssertEqual(HostCommand.closeScript(for: .ghostty, windowID: "42"),
                       "tell application id \"com.mitchellh.ghostty\" to close (first window whose id is 42)")
    }

    func testCloseScriptIterm2() {
        XCTAssertEqual(HostCommand.closeScript(for: .iterm2, windowID: "7"),
                       "tell application id \"com.googlecode.iterm2\" to close (first window whose id is 7)")
    }

    func testCloseScriptTerminal() {
        XCTAssertEqual(HostCommand.closeScript(for: .terminal, windowID: "1"),
                       "tell application id \"com.apple.Terminal\" to close (first window whose id is 1)")
    }

    func testCloseScriptCmux() {
        XCTAssertEqual(HostCommand.closeScript(for: .cmux, windowID: "9"),
                       "tell application id \"com.cmuxterm.app\" to close (first window whose id is 9)")
    }

    func testCloseScriptKittyIsNil() {
        XCTAssertNil(HostCommand.closeScript(for: .kitty, windowID: "1"))
    }

    func testCloseScriptWarpIsNil() {
        XCTAssertNil(HostCommand.closeScript(for: .warp, windowID: "1"))
    }
}
