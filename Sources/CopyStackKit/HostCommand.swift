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
        "exec " + pickerArgv(copystackPath: copystackPath, session: session)
    }

    /// Same as `pickerCommand` but without the leading `exec` — needed for
    /// Ghostty, which (per its `Ghostty.sdef`) already runs a surface
    /// configuration's `command` as `bash -c "exec -l <command>"` itself.
    /// Giving it `pickerCommand`'s own leading `exec` on top makes bash's
    /// `exec -l` builtin treat the word "exec" as the program to look up on
    /// $PATH (there is no such external binary), so the surface's command
    /// fails immediately and the window/tab closes right away (confirmed
    /// live: `command of cfg` set to `pickerCommand` closed within ~1s, the
    /// same string without the leading `exec` ran and stayed open).
    private static func pickerArgv(copystackPath: String, session: String) -> String {
        "\(ShellQuote.single(copystackPath)) --pick --session \(session)"
    }

    /// The picker sets this as its window title via OSC 2, so AX lookup by
    /// title can find the window this host just opened.
    public static func windowTitle(session: String) -> String {
        "Copy Stack · " + String(session.prefix(6))
    }

    /// Launches to try, in order; the first that succeeds wins.
    ///
    /// - Parameter bundleID: the *actual* bundle id of the running instance
    ///   (e.g. `runningApp.bundleIdentifier`), used verbatim in `tell
    ///   application id "..."`. This matters for `cmux`, which has two
    ///   installable variants with different ids (`com.cmuxterm.app` and the
    ///   cmux-imperum debug build's `com.cmuxterm.app.debug.imperum`); using
    ///   the wrong one would target a different (or non-running) app.
    public static func launch(
        for app: TerminalApp,
        copystackPath: String,
        session: String,
        cols: Int = 100,
        rows: Int = 30,
        bundleURL: String,
        bundleID: String,
        cmuxCLI: String? = nil
    ) -> [Launch] {
        let command = pickerCommand(copystackPath: copystackPath, session: session)
        switch app {
        case .ghostty:
            // No "shell:" prefix — Ghostty.sdef's "command" property is "the
            // command to execute instead of the configured shell", a plain
            // command line, not a DSL string; a literal "shell:" prefix made
            // Ghostty try (and fail) to look up a program named
            // "shell:exec" (confirmed live). And `pickerArgv`, not
            // `pickerCommand`, per the comment on `pickerArgv`.
            let ghosttyCommand = pickerArgv(copystackPath: copystackPath, session: session)
            let ascript = """
            tell application id "\(bundleID)"
                set cfg to new surface configuration
                set command of cfg to "\(escapeForAppleScriptString(ghosttyCommand))"
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
            // iTerm2's "command" property execs the string directly, with no
            // shell in between — `exec` is a shell builtin, so without a
            // shell to run it in, the command fails immediately and the
            // window closes within ~1s (confirmed live). Wrapping in
            // `/bin/sh -c '<command>'` gives it a shell to run `exec` in;
            // ShellQuote.single handles the command's own embedded single
            // quotes (from pickerCommand's ShellQuote.single(copystackPath)),
            // and the whole wrapped string then gets the usual AppleScript
            // string-literal escaping on top (applied once, not twice).
            let shellCommand = "/bin/sh -c " + ShellQuote.single(command)
            let ascript = """
            tell application id "\(bundleID)"
                set w to create window with default profile command "\(escapeForAppleScriptString(shellCommand))"
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
    /// instance simply exits when the picker does). `cmux` also returns nil:
    /// its windows reject the standard AppleScript "close" Apple event this
    /// template sends (confirmed live: `"doesn't understand the "close"
    /// message"`, error -1708) — `TerminalHosts` closes cmux windows through
    /// the CLI's own `close-window` command instead.
    ///
    /// Ghostty's windows reject that same standard "close" event too (same
    /// -1708 error, confirmed live) — but unlike cmux, Ghostty.sdef defines
    /// its own custom `close window <specifier>` command, confirmed live to
    /// work, which is what this returns for `.ghostty`.
    public static func closeScript(for app: TerminalApp, bundleID: String, windowID: String) -> String? {
        switch app {
        case .kitty, .warp, .cmux:
            return nil
        case .ghostty:
            return "tell application id \"\(bundleID)\" to close window (first window whose id is \(windowID))"
        case .iterm2, .terminal:
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
