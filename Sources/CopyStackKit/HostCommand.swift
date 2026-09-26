import Foundation

/// Builds the exact strings/arguments needed to open the `copystack` picker
/// in each supported terminal host, and to close a window it opened. Pure
/// and side-effect free: `TerminalHosts` (in `ImperumTool`) is what actually
/// runs AppleScript, launches apps, or shells out to a CLI.
public enum HostCommand {
    public struct Launch: Equatable {
        public let kind: Kind
        public init(kind: Kind) { self.kind = kind }

        public enum Kind: Equatable {
            case appleScript(source: String)
            case openApp(bundleURL: String, arguments: [String])
            case cli(executable: String, argv: [[String]])
        }
    }

    /// The picker command line every host runs; the app path is single-quoted.
    public static func pickerCommand(copystackPath: String, session: String) -> String {
        "exec \(ShellQuote.single(copystackPath)) --pick --session \(session)"
    }

    /// The picker sets this as its window title via OSC 2, so AX lookup by
    /// title can find the window this host just opened.
    public static func windowTitle(session: String) -> String {
        "Copy Stack · " + String(session.prefix(6))
    }

    /// Launches to try, in order; the first that succeeds wins.
    public static func launch(
        for app: TerminalApp,
        copystackPath: String,
        session: String,
        cols: Int = 100,
        rows: Int = 30,
        bundleURL: String,
        cmuxCLI: String? = nil
    ) -> [Launch] {
        let command = pickerCommand(copystackPath: copystackPath, session: session)
        switch app {
        case .ghostty:
            let bundleID = TerminalApp.ghostty.bundleIDPrefixes[0]
            let ascript = """
            tell application id "\(bundleID)"
                set cfg to new surface configuration
                set command of cfg to "shell:\(escapeForAppleScriptString(command))"
                set wait after command of cfg to false
                set w to new window with configuration cfg
                return id of w
            end tell
            """
            let fallbackArgs = [
                "--window-width=\(cols)", "--window-height=\(rows)",
                "--title=\(windowTitle(session: session))",
                "--window-save-state=never", "--confirm-close-surface=false",
                "-e", copystackPath, "--pick", "--session", session,
            ]
            return [
                Launch(kind: .appleScript(source: ascript)),
                Launch(kind: .openApp(bundleURL: bundleURL, arguments: fallbackArgs)),
            ]

        case .cmux:
            let bundleID = TerminalApp.cmux.bundleIDPrefixes[0]
            var launches: [Launch] = []
            if let cmuxCLI {
                launches.append(Launch(kind: .cli(executable: cmuxCLI, argv: [
                    ["new-window"],
                    ["send", "--window", "{WINDOW}", " \(command)\n"],
                ])))
            }
            let ascript = """
            tell application id "\(bundleID)"
                set w to new window
                perform action "text: \(escapeForAppleScriptString(command))" & return on focused terminal of selected tab of w
                return id of w
            end tell
            """
            launches.append(Launch(kind: .appleScript(source: ascript)))
            return launches

        case .iterm2:
            let bundleID = TerminalApp.iterm2.bundleIDPrefixes[0]
            let ascript = """
            tell application id "\(bundleID)"
                set w to create window with default profile command "\(escapeForAppleScriptString(command))"
                tell current session of w
                    set columns to \(cols)
                    set rows to \(rows)
                end tell
                return id of w
            end tell
            """
            return [Launch(kind: .appleScript(source: ascript))]

        case .kitty:
            let args = [
                "-o", "initial_window_width=\(cols)c",
                "-o", "initial_window_height=\(rows)c",
                "-o", "remember_window_size=no",
                "-o", "macos_quit_when_last_window_closed=yes",
                "-o", "confirm_os_window_close=0",
                "--title", windowTitle(session: session),
                copystackPath, "--pick", "--session", session,
            ]
            return [Launch(kind: .openApp(bundleURL: bundleURL, arguments: args))]

        case .terminal:
            let bundleID = TerminalApp.terminal.bundleIDPrefixes[0]
            let ascript = """
            tell application id "\(bundleID)"
                set t to do script "\(escapeForAppleScriptString(command))"
                set number of columns of t to \(cols)
                set number of rows of t to \(rows)
                return id of front window
            end tell
            """
            return [Launch(kind: .appleScript(source: ascript))]

        case .warp:
            return []
        }
    }

    /// AppleScript to close a window by id, where the host supports it.
    /// `kitty`/`warp` return nil (kitty has no scriptable close-by-id; the
    /// instance simply exits when the picker does).
    public static func closeScript(for app: TerminalApp, windowID: String) -> String? {
        switch app {
        case .kitty, .warp:
            return nil
        case .ghostty, .iterm2, .terminal, .cmux:
            let bundleID = app.bundleIDPrefixes[0]
            return "tell application id \"\(bundleID)\" to close (first window whose id is \(windowID))"
        }
    }

    /// Escapes backslashes and double quotes so an arbitrary string can be
    /// embedded inside an AppleScript double-quoted string literal.
    private static func escapeForAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
