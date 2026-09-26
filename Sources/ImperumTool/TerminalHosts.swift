import AppKit
import ApplicationServices
import CopyStackKit
import Foundation
import ImperumCore

/// A window `TerminalHost.open` opened, and everything needed to find it
/// (via `position`) and close it again.
struct HostHandle {
    let app: TerminalApp
    let hostPID: pid_t
    /// The id AppleScript/the cmux CLI reported for the new window, when the
    /// host can report one. Nil for `openApp` launches (Ghostty fallback,
    /// kitty), which are found by title instead (see `position`).
    let windowID: String?
    /// Set when `open` launched a brand-new process instance (an `openApp`
    /// launch with `createsNewApplicationInstance = true`); `close` quits it.
    let newInstance: NSRunningApplication?
    /// Whether the `Launch` that succeeded already sized the window itself
    /// (iTerm2/Terminal's AppleScript `columns`/`rows`, kitty's and Ghostty's
    /// `openApp` fallback's `initial_window_width`/`--window-width` CLI
    /// args). False for the two paths with no window-size mechanism at all —
    /// Ghostty's primary AppleScript path (its `surface configuration`
    /// record has no width/height/columns/rows property, confirmed via
    /// `Ghostty.sdef`) and cmux (no window-size CLI flag or AppleScript verb)
    /// — which `position` then gives a fixed fallback size instead.
    let sizedNatively: Bool
}

enum HostError: Error {
    case unsupported
    case automationDenied
    case notRunning
    case launchFailed(String)
    case timeout
}

protocol TerminalHost {
    var app: TerminalApp { get }
    /// Opens a new window running the picker. Calls `completion` on main.
    func open(session: String, copystackPath: String, completion: @escaping (Result<HostHandle, HostError>) -> Void)
    /// Best effort. For a brand-new instance (kitty, Ghostty's `openApp`
    /// fallback) this terminates that instance outright — acceptable because
    /// `open` always launches those with `createsNewApplicationInstance =
    /// true` specifically so this process only ever hosts the one picker
    /// window and nothing else the user has open in that app.
    func close(_ handle: HostHandle)
    /// Finds the window `open` created by its title (polling up to 1.5s
    /// every 30ms, since AX may not see it the instant the host reports
    /// success), raises it, and centres it on the screen under the mouse.
    func position(_ handle: HostHandle, windowTitle: String)
}

enum TerminalHosts {
    /// The last real `HostError` seen per app (e.g. `.automationDenied`), for
    /// Settings to surface ("Ghostty: Automation access denied"). Only ever
    /// read/written on main (every `TerminalHost` completion callback runs on
    /// main; see `GenericTerminalHost`).
    @MainActor static var lastFailure: [TerminalApp: HostError] = [:]

    static func host(for app: TerminalApp, runningApp: NSRunningApplication) -> TerminalHost? {
        guard app.supportsPicker else { return nil }
        return GenericTerminalHost(app: app, runningApp: runningApp)
    }
}

/// Drives `HostCommand`'s launch strategies for any supported terminal:
/// tries each in order (AppleScript, then an `openApp`/CLI fallback) and the
/// first that succeeds wins.
private final class GenericTerminalHost: TerminalHost {
    let app: TerminalApp
    private let runningApp: NSRunningApplication

    /// `NSAppleScript` blocks, so every AppleScript call — across every host
    /// instance — runs off this one shared serial queue, never main.
    private static let appleScriptQueue = DispatchQueue(label: "com.imperum.terminalHosts.appleScript")

    init(app: TerminalApp, runningApp: NSRunningApplication) {
        self.app = app
        self.runningApp = runningApp
    }

    /// The bundle id of the *actual* running instance, not just one of
    /// `app`'s known prefixes — matters for cmux, whose cmux-imperum debug
    /// build has a different id than the regular build.
    private var bundleID: String { runningApp.bundleIdentifier ?? app.bundleIDPrefixes[0] }

    // MARK: open

    func open(session: String, copystackPath: String, completion: @escaping (Result<HostHandle, HostError>) -> Void) {
        guard app.supportsPicker else { return completion(.failure(.unsupported)) }
        let bundleURL = runningApp.bundleURL?.path ?? ""
        let cmuxCLI = app == .cmux ? cmuxCLIPath() : nil
        let launches = HostCommand.launch(for: app, copystackPath: copystackPath, session: session,
                                           bundleURL: bundleURL, bundleID: bundleID, cmuxCLI: cmuxCLI)
        attempt(launches: launches, index: 0, lastError: nil, completion: completion)
    }

    /// Tries `launches[index]`; on failure, tries the next one, remembering
    /// the most recent real error so that if every strategy fails, callers
    /// (and `TerminalHosts.lastFailure`) see e.g. `.automationDenied` rather
    /// than a generic "nothing worked" message. `self` is captured strongly
    /// throughout: nothing else retains a `GenericTerminalHost` while an
    /// `open` is in flight (the caller only gets one back via `completion`),
    /// so a `[weak self]` here would let it deallocate mid-launch and drop
    /// the completion (and, in `position`, stop polling after one attempt).
    private func attempt(launches: [HostCommand.Launch], index: Int, lastError: HostError?,
                          completion: @escaping (Result<HostHandle, HostError>) -> Void) {
        guard index < launches.count else {
            let err = lastError ?? .launchFailed("no launch strategy configured for \(app.displayName)")
            recordFailure(err)
            return completion(.failure(err))
        }
        run(launches[index].kind) { result in
            switch result {
            case .success(let handle):
                self.recordFailure(nil)
                completion(.success(handle))
            case .failure(let err):
                self.recordFailure(err)
                self.attempt(launches: launches, index: index + 1, lastError: err, completion: completion)
            }
        }
    }

    /// Always hops to main itself (rather than assuming the caller already
    /// is), so it's safe to call from anywhere, including the edge case in
    /// `attempt` where `launches` was empty from the start.
    private func recordFailure(_ err: HostError?) {
        let app = app
        DispatchQueue.main.async {
            TerminalHosts.lastFailure[app] = err
        }
    }

    private func run(_ kind: HostCommand.Launch.Kind, completion: @escaping (Result<HostHandle, HostError>) -> Void) {
        switch kind {
        case .appleScript(let source):
            runAppleScript(source) { result in
                switch result {
                case .success(let windowID):
                    completion(.success(HostHandle(app: self.app, hostPID: self.runningApp.processIdentifier, windowID: windowID,
                                                    newInstance: nil, sizedNatively: self.sizesNatively(kind))))
                case .failure(let err):
                    completion(.failure(err))
                }
            }

        case .openApp(let bundleURL, let arguments):
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            config.arguments = arguments
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundleURL), configuration: config) { newInstance, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(.launchFailed(error.localizedDescription)))
                    } else if let newInstance {
                        completion(.success(HostHandle(app: self.app, hostPID: newInstance.processIdentifier, windowID: nil,
                                                        newInstance: newInstance, sizedNatively: self.sizesNatively(kind))))
                    } else {
                        completion(.failure(.launchFailed("openApplication returned no running instance")))
                    }
                }
            }

        case .cli(let executable, let argv):
            runCLI(executable: executable, argv: argv, completion: completion)
        }
    }

    /// Whether the given `Launch.Kind`, for this host's `app`, already sizes
    /// the window itself. See the doc comment on `HostHandle.sizedNatively`.
    private func sizesNatively(_ kind: HostCommand.Launch.Kind) -> Bool {
        switch (app, kind) {
        case (.ghostty, .appleScript): return false   // no size property in Ghostty's surface configuration
        case (.cmux, _): return false                 // no window-size CLI flag or AppleScript verb at all
        default: return true                          // ghostty's openApp fallback, iTerm2, Terminal, kitty
        }
    }

    // MARK: AppleScript

    /// `completion` is called back on main.
    private func runAppleScript(_ source: String, completion: @escaping (Result<String?, HostError>) -> Void) {
        Self.appleScriptQueue.async {
            guard let script = NSAppleScript(source: source) else {
                return DispatchQueue.main.async { completion(.failure(.launchFailed("could not parse AppleScript"))) }
            }
            var errorDict: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorDict)
            if let errorDict {
                let code = (errorDict[NSAppleScript.errorNumber] as? Int) ?? 0
                let message = (errorDict[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)"
                let mapped: HostError
                switch code {
                case -1743: mapped = .automationDenied
                case -600: mapped = .notRunning
                default: mapped = .launchFailed(message)
                }
                return DispatchQueue.main.async { completion(.failure(mapped)) }
            }
            DispatchQueue.main.async { completion(.success(descriptor.stringValue)) }
        }
    }

    // MARK: cmux CLI

    private func cmuxCLIPath() -> String? {
        guard let bundleURL = runningApp.bundleURL else { return nil }
        let candidate = bundleURL.appendingPathComponent("Contents/Resources/bin/cmux")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate.path : nil
    }

    /// `argv[0]` is `new-window` (its stdout is the new window's id/ref);
    /// each subsequent entry has `{WINDOW}` substituted with that id and is
    /// run in turn (e.g. `send --window <id> "<pickerCommand>\n"`). If any
    /// of those later commands fails, the window is closed before this
    /// launch strategy reports failure, so the AppleScript fallback (or a
    /// retry) doesn't pile up empty cmux windows.
    private func runCLI(executable: String, argv: [[String]], completion: @escaping (Result<HostHandle, HostError>) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return completion(.failure(.launchFailed("cmux CLI not found at \(executable)")))
        }
        guard let newWindowArgs = argv.first else {
            return completion(.failure(.launchFailed("empty cmux argv")))
        }
        let env = cmuxEnvironment()
        DispatchQueue.global(qos: .userInitiated).async {
            let newWindowResult = Self.runProcess(executable, newWindowArgs, env: env)
            guard case .success(let newWindowOutput) = newWindowResult,
                  let windowID = Self.parseCmuxRef(newWindowOutput), !windowID.isEmpty else {
                let err: HostError = {
                    if case .failure(let e) = newWindowResult { return e }
                    return .launchFailed("cmux new-window returned no window id")
                }()
                return DispatchQueue.main.async { completion(.failure(err)) }
            }
            for remaining in argv.dropFirst() {
                let substituted = remaining.map { $0.replacingOccurrences(of: "{WINDOW}", with: windowID) }
                if case .failure(let sendErr) = Self.runProcess(executable, substituted, env: env) {
                    _ = Self.runProcess(executable, ["close-window", "--window", windowID], env: env)
                    return DispatchQueue.main.async { completion(.failure(sendErr)) }
                }
            }
            DispatchQueue.main.async {
                completion(.success(HostHandle(app: self.app, hostPID: self.runningApp.processIdentifier, windowID: windowID,
                                                newInstance: nil, sizedNatively: false)))
            }
        }
    }

    /// `~/.local/state/cmux/dev-last-socket-path`, which the cmux-imperum
    /// debug build writes its socket path to (there's no fixed socket name
    /// for that variant, unlike the regular build's `cmux.sock`).
    private static func devLastSocketPath() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/dev-last-socket-path")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cmuxEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Never trust an inherited CMUX_SOCKET_PATH (e.g. if Imperum Tool
        // itself were launched from inside a cmux shell) — only the
        // cmux-imperum debug build gets one, set explicitly below, so a
        // launch can't be silently redirected to some other socket.
        env.removeValue(forKey: "CMUX_SOCKET_PATH")
        let password = ClipboardSettingsStore(defaults: .standard).settings.cmuxSocketPassword
        if !password.isEmpty { env["CMUX_SOCKET_PASSWORD"] = password }
        if runningApp.bundleIdentifier?.hasSuffix(".debug.imperum") == true,
           let devSocketPath = Self.devLastSocketPath() {
            env["CMUX_SOCKET_PATH"] = devSocketPath
        }
        return env
    }

    /// The cmux CLI prints `OK <ref>` (e.g. `OK 5C52D185-...` for
    /// `new-window`, `OK surface:1 workspace:1` for `send`) rather than a
    /// bare id/ref, confirmed against a real install's `new-window` output.
    /// Falls back to the raw trimmed output if it's unprefixed.
    private static func parseCmuxRef(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("OK ") else { return trimmed.isEmpty ? nil : trimmed }
        return String(trimmed.dropFirst("OK ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Runs `executable argv` synchronously (this always happens on a
    /// background queue) with a hard timeout, since a hung or unresponsive
    /// CLI must not hang `open`/`close` forever. Terminates the process and
    /// returns `.timeout` if it hasn't exited within `timeout` seconds.
    private static func runProcess(_ executable: String, _ argv: [String], env: [String: String],
                                    timeout: TimeInterval = 3.0) -> Result<String, HostError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = argv
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        // Never read, so route straight to /dev/null: an unread stderr pipe
        // that fills up would block the child from ever writing more (and so
        // from ever exiting), which could then block this call regardless of
        // the timeout below.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            return .failure(.launchFailed("failed to start \(executable): \(error.localizedDescription)"))
        }

        // Read stdout on its own queue, independent of the wait below, so a
        // child that (for whatever reason) doesn't close its stdout promptly
        // can't itself become the thing that blocks this call past `timeout`.
        let output = OutputBox()
        DispatchQueue(label: "com.imperum.terminalHosts.runProcess.read").async {
            output.set(out.fileHandleForReading.readDataToEndOfFile())
        }

        let timedOut = TimeoutFlag()
        let killQueue = DispatchQueue.global(qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: killQueue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            guard p.isRunning else { return }
            timedOut.set()
            p.terminate()   // SIGTERM
            // A CLI that ignores SIGTERM (or is stuck) must not be able to
            // hang this indefinitely: escalate shortly after.
            killQueue.asyncAfter(deadline: .now() + 0.5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()

        p.waitUntilExit()
        timer.cancel()
        // The process (and so the pipe's write end) is gone by now, so this
        // can only block briefly even in the worst case; `timeout` doubled
        // is a last-resort bound, not the expected wait.
        let data = output.wait(timeout: .now() + timeout * 2)

        if timedOut.value {
            return .failure(.timeout)
        }
        guard p.terminationStatus == 0 else {
            return .failure(.launchFailed("\(executable) \(argv.first ?? "") exited with status \(p.terminationStatus)"))
        }
        return .success(String(data: data, encoding: .utf8) ?? "")
    }

    /// A tiny lock-protected flag `runProcess`'s timer (background queue) and
    /// caller (also a background queue, but a different one) both touch.
    private final class TimeoutFlag {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
        func set() { lock.lock(); _value = true; lock.unlock() }
    }

    /// Hands stdout data from `runProcess`'s dedicated read queue back to its
    /// caller, with a bounded wait rather than an unconditional block.
    private final class OutputBox {
        private let semaphore = DispatchSemaphore(value: 0)
        private var data = Data()
        func set(_ d: Data) { data = d; semaphore.signal() }
        func wait(timeout: DispatchTime) -> Data {
            _ = semaphore.wait(timeout: timeout)
            return data
        }
    }

    // MARK: close

    func close(_ handle: HostHandle) {
        if let newInstance = handle.newInstance {
            newInstance.terminate()
            return
        }
        guard let windowID = handle.windowID else { return }
        // cmux's windows don't understand the standard "close" Apple event
        // (HostCommand.closeScript returns nil for cmux for exactly this
        // reason), so close it through the CLI's own close-window instead.
        if app == .cmux, let cli = cmuxCLIPath() {
            let env = cmuxEnvironment()
            DispatchQueue.global(qos: .utility).async {
                _ = Self.runProcess(cli, ["close-window", "--window", windowID], env: env)
            }
            return
        }
        guard let script = HostCommand.closeScript(for: app, bundleID: bundleID, windowID: windowID) else { return }
        runAppleScript(script) { _ in }
    }

    // MARK: position

    func position(_ handle: HostHandle, windowTitle: String) {
        poll(handle: handle, windowTitle: windowTitle, deadline: Date().addingTimeInterval(1.5))
    }

    private func poll(handle: HostHandle, windowTitle: String, deadline: Date) {
        if let window = AXWindow.find(pid: handle.hostPID, titleContains: windowTitle) {
            AXWindow.raise(window)
            AXWindow.setFrontmost(pid: handle.hostPID)
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let visible = Self.screenUnderMouse()
            // The launch that actually succeeded (see HostHandle.sizedNatively)
            // decides this, not just `app`: Ghostty's primary AppleScript path
            // has no sizing option but its openApp fallback does, so the same
            // app needs different treatment depending on which one won.
            let size = handle.sizedNatively ? (AXWindow.frame(of: window)?.size ?? CGSize(width: 900, height: 560)) : CGSize(width: 900, height: 560)
            let cocoaOrigin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            let axOrigin = CGPoint(x: cocoaOrigin.x, y: primaryH - cocoaOrigin.y - size.height)
            AXWindow.setFrame(window, CGRect(origin: axOrigin, size: size))
            return
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.poll(handle: handle, windowTitle: windowTitle, deadline: deadline)
        }
    }

    private static func screenUnderMouse() -> NSRect {
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
