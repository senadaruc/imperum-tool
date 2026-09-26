import XCTest
@testable import CopyStackKit

final class HostCommandTests: XCTestCase {
    let copystackPath = "/Applications/Imperum Tool.app/Contents/Resources/copystack"
    let session = "abc123def456"
    let bundleURL = "/Applications/Ghostty.app"

    /// Mirrors `HostCommand`'s private AppleScript string-literal escaping,
    /// so goldens that embed an already-escaped inner command (e.g. iTerm2's
    /// shell-wrapped command) can be built the same way the implementation
    /// builds them, rather than hand-transcribing backslash runs.
    private func escAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

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
                                           bundleURL: "/Applications/Ghostty.app", bundleID: "com.mitchellh.ghostty")
        XCTAssertEqual(launches.count, 2)
        // Ghostty's own surface configuration already runs its "command" as
        // `bash -c "exec -l <command>"`, so this must NOT have pickerCommand's
        // usual leading "exec" (that made bash's `exec -l` builtin look for
        // an external program literally named "exec" and fail — confirmed
        // live) and must NOT have a "shell:" prefix (Ghostty.sdef's
        // "command" property is a plain command line, not a DSL string —
        // also confirmed live, a literal "shell:" prefix made it try to run
        // a program named "shell:exec").
        let argv = "'/Applications/Imperum Tool.app/Contents/Resources/copystack' --pick --session \(session)"
        XCTAssertEqual(launches[0].kind, .appleScript(source: """
        tell application id "com.mitchellh.ghostty"
            set cfg to new surface configuration
            set command of cfg to "\(argv)"
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

    func testGhosttyLaunchUsesGivenBundleID() {
        let launches = HostCommand.launch(for: .ghostty, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/Ghostty.app", bundleID: "com.mitchellh.ghostty.debug")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.hasPrefix("tell application id \"com.mitchellh.ghostty.debug\""))
    }

    func testGhosttyLaunchEscapesInnerDoubleQuotes() {
        let launches = HostCommand.launch(for: .ghostty, copystackPath: "/tmp/\"weird\"/copystack", session: session,
                                           bundleURL: "/Applications/Ghostty.app", bundleID: "com.mitchellh.ghostty")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains(#"\"weird\""#), "expected escaped inner double quotes, got: \(source)")
    }

    func testGhosttyLaunchEscapesBackslashes() {
        let launches = HostCommand.launch(for: .ghostty, copystackPath: "/tmp/weird\\path/copystack", session: session,
                                           bundleURL: "/Applications/Ghostty.app", bundleID: "com.mitchellh.ghostty")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains("weird\\\\path"), "expected escaped backslash, got: \(source)")
    }

    // MARK: cmux

    func testCmuxLaunchWithCLI() {
        let launches = HostCommand.launch(for: .cmux, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/cmux.app", bundleID: "com.cmuxterm.app", cmuxCLI: "/path/to/cmux")
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

    func testCmuxLaunchUsesGivenBundleIDForDebugImperumBuild() {
        let launches = HostCommand.launch(for: .cmux, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/cmux-imperum.app", bundleID: "com.cmuxterm.app.debug.imperum")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.hasPrefix("tell application id \"com.cmuxterm.app.debug.imperum\""))
    }

    func testCmuxLaunchEscapesInnerDoubleQuotesInAppleScriptFallback() {
        let launches = HostCommand.launch(for: .cmux, copystackPath: "/tmp/\"weird\"/copystack", session: session,
                                           bundleURL: "/Applications/cmux.app", bundleID: "com.cmuxterm.app")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains(#"\"weird\""#), "expected escaped inner double quotes, got: \(source)")
    }

    /// cmux's own `perform action "text: ..."` does its own escape
    /// processing on top of AppleScript's (confirmed live: one backslash in
    /// the AppleScript runtime string made the whole `perform action` type
    /// nothing at all), so one real backslash in `copystackPath` must appear
    /// as *four* backslash characters in the generated source: doubled once
    /// so cmux's own unescaping halves it back to one, then doubled again by
    /// the usual AppleScript string-literal escaping.
    func testCmuxLaunchQuadrupleEscapesBackslashesForActionTextParsing() {
        let launches = HostCommand.launch(for: .cmux, copystackPath: "/tmp/weird\\path/copystack", session: session,
                                           bundleURL: "/Applications/cmux.app", bundleID: "com.cmuxterm.app")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains("weird\\\\\\\\path"), "expected quadrupled backslash, got: \(source)")
    }

    func testCmuxLaunchWithoutCLIOnlyHasAppleScriptFallback() {
        let launches = HostCommand.launch(for: .cmux, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/cmux.app", bundleID: "com.cmuxterm.app")
        XCTAssertEqual(launches.count, 1)
        if case .appleScript = launches[0].kind {} else { XCTFail("expected appleScript fallback") }
    }

    // MARK: iTerm2

    /// iTerm2's `create window with default profile command "<text>"` execs
    /// `<text>` directly (no shell), so `exec` — a shell builtin — fails and
    /// the window dies almost immediately (confirmed live: the window closed
    /// within ~1s). The command is wrapped as `/bin/sh -c '<pickerCommand>'`
    /// (single-quoted via `ShellQuote.single`) so there's an actual shell to
    /// run `exec` in; that whole wrapped string then goes through the same
    /// AppleScript string-literal escaping as every other host's command.
    func testIterm2Launch() {
        let launches = HostCommand.launch(for: .iterm2, copystackPath: copystackPath, session: session,
                                           cols: 120, rows: 40, bundleURL: "/Applications/iTerm.app", bundleID: "com.googlecode.iterm2")
        let cmd = HostCommand.pickerCommand(copystackPath: copystackPath, session: session)
        let shellCmd = "/bin/sh -c " + ShellQuote.single(cmd)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches[0].kind, .appleScript(source: """
        tell application id "com.googlecode.iterm2"
            set w to create window with default profile command "\(escAS(shellCmd))"
            tell current session of w
                set columns to 120
                set rows to 40
            end tell
            return id of w
        end tell
        """))
    }

    func testIterm2LaunchUsesGivenBundleID() {
        let launches = HostCommand.launch(for: .iterm2, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/iTerm.app", bundleID: "com.googlecode.iterm2.nightly")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.hasPrefix("tell application id \"com.googlecode.iterm2.nightly\""))
    }

    func testIterm2LaunchEscapesInnerDoubleQuotes() {
        let launches = HostCommand.launch(for: .iterm2, copystackPath: "/tmp/\"weird\"/copystack", session: session,
                                           bundleURL: "/Applications/iTerm.app", bundleID: "com.googlecode.iterm2")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains(#"\"weird\""#), "expected escaped inner double quotes, got: \(source)")
    }

    func testIterm2LaunchEscapesBackslashes() {
        let launches = HostCommand.launch(for: .iterm2, copystackPath: "/tmp/weird\\path/copystack", session: session,
                                           bundleURL: "/Applications/iTerm.app", bundleID: "com.googlecode.iterm2")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains("weird\\\\path"), "expected escaped backslash, got: \(source)")
    }

    // MARK: kitty

    func testKittyLaunch() {
        let launches = HostCommand.launch(for: .kitty, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/kitty.app", bundleID: "net.kovidgoyal.kitty")
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
                                           bundleURL: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal")
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

    func testTerminalLaunchUsesGivenBundleID() {
        let launches = HostCommand.launch(for: .terminal, copystackPath: copystackPath, session: session,
                                           bundleURL: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.hasPrefix("tell application id \"com.apple.Terminal\""))
    }

    func testTerminalLaunchEscapesBackslashes() {
        let launches = HostCommand.launch(for: .terminal, copystackPath: "/tmp/weird\\path/copystack", session: session,
                                           bundleURL: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal")
        guard case .appleScript(let source) = launches[0].kind else { return XCTFail("expected appleScript") }
        XCTAssertTrue(source.contains("weird\\\\path"), "expected escaped backslash, got: \(source)")
    }

    // MARK: Warp

    func testWarpLaunchIsEmpty() {
        XCTAssertEqual(HostCommand.launch(for: .warp, copystackPath: copystackPath, session: session,
                                           bundleURL: "/Applications/Warp.app", bundleID: "dev.warp.Warp-Stable"), [])
    }

    // MARK: closeScript

    /// Ghostty's windows reject the standard AppleScript "close" Apple event
    /// too (confirmed live, same -1708 error as cmux) — but Ghostty.sdef
    /// defines its own "close window <specifier>" command, confirmed live to
    /// work, which is what this must use instead of the generic template.
    /// Ghostty.sdef types a window's `id` as `text` (confirmed live: real ids
    /// look like `tab-group-7c05f73c00`, not a small integer), so unlike
    /// iTerm2/Terminal's numeric-looking ids, it must be quoted as an
    /// AppleScript string literal.
    func testCloseScriptGhostty() {
        XCTAssertEqual(HostCommand.closeScript(for: .ghostty, bundleID: "com.mitchellh.ghostty", windowID: "tab-group-7c05f73c00"),
                       "tell application id \"com.mitchellh.ghostty\" to close window (first window whose id is \"tab-group-7c05f73c00\")")
    }

    func testCloseScriptGhosttyEscapesDoubleQuoteInID() {
        XCTAssertEqual(HostCommand.closeScript(for: .ghostty, bundleID: "com.mitchellh.ghostty", windowID: "weird\"id"),
                       "tell application id \"com.mitchellh.ghostty\" to close window (first window whose id is \"weird\\\"id\")")
    }

    func testCloseScriptIterm2() {
        XCTAssertEqual(HostCommand.closeScript(for: .iterm2, bundleID: "com.googlecode.iterm2", windowID: "7"),
                       "tell application id \"com.googlecode.iterm2\" to close (first window whose id is 7)")
    }

    func testCloseScriptTerminal() {
        XCTAssertEqual(HostCommand.closeScript(for: .terminal, bundleID: "com.apple.Terminal", windowID: "1"),
                       "tell application id \"com.apple.Terminal\" to close (first window whose id is 1)")
    }

    /// cmux's windows reject the standard AppleScript "close" Apple event
    /// (confirmed live: "doesn't understand the "close" message", -1708), so
    /// unlike the other three AppleScript-scriptable hosts, cmux has no
    /// working `closeScript`; `TerminalHosts` closes cmux windows through the
    /// CLI's own `close-window` command instead.
    func testCloseScriptCmuxIsNil() {
        XCTAssertNil(HostCommand.closeScript(for: .cmux, bundleID: "com.cmuxterm.app", windowID: "9"))
    }

    func testCloseScriptKittyIsNil() {
        XCTAssertNil(HostCommand.closeScript(for: .kitty, bundleID: "net.kovidgoyal.kitty", windowID: "1"))
    }

    func testCloseScriptWarpIsNil() {
        XCTAssertNil(HostCommand.closeScript(for: .warp, bundleID: "dev.warp.Warp-Stable", windowID: "1"))
    }
}
