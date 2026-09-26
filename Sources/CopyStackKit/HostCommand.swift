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
        // `TerminalApp.detect` matches a running app's bundle id by prefix,
        // so a hostile or malformed running instance could in principle
        // report an id outside the normal reverse-DNS charset (e.g.
        // containing a `"`). Every strategy below interpolates `bundleID`
        // into a `tell application id "..."` AppleScript literal, so refuse
        // to build anything at all for an id that doesn't look like a
        // bundle id, rather than risk AppleScript injection.
        guard isValidBundleID(bundleID) else { return [] }
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
            tell application id "\(escapeForAppleScriptString(bundleID))"
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
            // cmux's "perform action" (unlike its CLI's `send`, and unlike
            // Ghostty's real "perform action", which takes a plain Ghostty
            // action string) runs its `text: <content>` action through its
            // own escape processing — confirmed live: a *single* backslash
            // in the AppleScript runtime string (i.e. `command` escaped only
            // for AppleScript's own string-literal syntax, same as every
            // other host) made the whole `perform action` silently type
            // nothing at all, while doubling it first (so cmux's own
            // unescaping halves it back to one) typed and ran correctly. A
            // literal `"` needed no such doubling (tested separately: it
            // passed through untouched). `command` only ever contains a
            // backslash via `ShellQuote.single`'s `'\''` escaping of an
            // embedded single quote in `copystackPath` (e.g. a path with an
            // apostrophe) — an edge case, but this is exactly the case that
            // would otherwise silently fail here.
            let cmuxActionText = command.replacingOccurrences(of: "\\", with: "\\\\")
            let ascript = """
            tell application id "\(escapeForAppleScriptString(bundleID))"
                set w to new window
                perform action "text: \(escapeForAppleScriptString(cmuxActionText))" & return on focused terminal of selected tab of w
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
            tell application id "\(escapeForAppleScriptString(bundleID))"
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
            tell application id "\(escapeForAppleScriptString(bundleID))"
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
    /// work, which is what this returns for `.ghostty`. Ghostty.sdef types a
    /// window's `id` as `text` (real ids look like `tab-group-7c05f73c00`,
    /// confirmed live), unlike iTerm2/Terminal's numeric-looking ids, so it's
    /// quoted as an AppleScript string literal here (and escaped, in case it
    /// ever contained a `"` or `\`).
    public static func closeScript(for app: TerminalApp, bundleID: String, windowID: String) -> String? {
        guard isValidBundleID(bundleID) else { return nil }
        switch app {
        case .kitty, .warp, .cmux:
            return nil
        case .ghostty:
            return "tell application id \"\(escapeForAppleScriptString(bundleID))\" to close window (first window whose id is \"\(escapeForAppleScriptString(windowID))\")"
        case .iterm2, .terminal:
            // Unlike Ghostty's `id`, iTerm2/Terminal's is interpolated
            // unquoted (it's a small integer, e.g. `7`, printed bare so
            // AppleScript compares it numerically) — so, unlike Ghostty,
            // escaping alone isn't enough to make an arbitrary windowID
            // safe here; require it to be all ASCII digits or emit nothing.
            guard isAllDigits(windowID) else { return nil }
            return "tell application id \"\(escapeForAppleScriptString(bundleID))\" to close (first window whose id is \(windowID))"
        }
    }

    /// How to close a window `launch` opened, given what the successful
    /// launch reported back.
    public enum CloseStrategy: Equatable {
        /// `open` launched a dedicated instance for the picker: quit it.
        case terminateInstance
        /// cmux: its CLI's `close-window --window <id>`.
        case cmuxCLI(windowID: String)
        /// The host's own AppleScript close-by-id (`closeScript`).
        case appleScript(String)
        /// No host mechanism applies: find the window by title over AX and
        /// press its close button (last resort only; see below).
        case accessibility
    }

    /// Picks exactly one close mechanism. The AX close button is only a
    /// last resort when the host offers nothing else, never an extra step
    /// on top of a host mechanism: on Ghostty, pressing it shows a
    /// "Close Window?" confirmation sheet (the surface has a running
    /// process), and if the AppleScript `close window` then lands while
    /// that sheet is up, Ghostty removes the window but never tears down its
    /// surface, so `login`, the picker and the pty live on indefinitely
    /// (reproduced live).
    public static func closeStrategy(for app: TerminalApp, bundleID: String, windowID: String?,
                                     launchedNewInstance: Bool, cmuxCLIAvailable: Bool) -> CloseStrategy {
        if launchedNewInstance { return .terminateInstance }
        guard let windowID else { return .accessibility }
        if app == .cmux {
            return cmuxCLIAvailable ? .cmuxCLI(windowID: windowID) : .accessibility
        }
        guard let script = closeScript(for: app, bundleID: bundleID, windowID: windowID) else { return .accessibility }
        return .appleScript(script)
    }

    /// Whether `path` (from `proc_pidpath`) is a `copystack` executable:
    /// the guard the app applies before ever signalling a picker pid, so a
    /// pid reused by some unrelated process is never signalled.
    public static func isPickerExecutable(path: String) -> Bool {
        (path as NSString).lastPathComponent == "copystack"
    }

    /// A bundle id must look like a reverse-DNS identifier
    /// (`^[A-Za-z0-9.\-]+$`) before it's trusted to build any AppleScript,
    /// openApp launch, or CLI launch — see the doc comment on `launch`.
    private static func isValidBundleID(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    private static func isAllDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Escapes backslashes and double quotes so an arbitrary string can be
    /// embedded inside an AppleScript double-quoted string literal.
    private static func escapeForAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
