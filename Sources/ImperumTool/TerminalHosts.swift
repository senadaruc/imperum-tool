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
    /// Best effort; a no-op for hosts opened as a brand-new instance whose
    /// process simply exits when the picker does.
    func close(_ handle: HostHandle)
    /// Finds the window `open` created by its title (polling up to 1.5s
    /// every 30ms, since AX may not see it the instant the host reports
    /// success), raises it, and centres it on the screen under the mouse.
    func position(_ handle: HostHandle, windowTitle: String)
}

enum TerminalHosts {
    /// The last `HostError` seen per app, for Settings to surface (e.g.
    /// "Ghostty: Automation access denied").
    static var lastFailure: [TerminalApp: HostError] = [:]

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
    private let appleScriptQueue = DispatchQueue(label: "com.imperum.terminalHosts.appleScript")

    init(app: TerminalApp, runningApp: NSRunningApplication) {
        self.app = app
        self.runningApp = runningApp
    }

    // MARK: open

    func open(session: String, copystackPath: String, completion: @escaping (Result<HostHandle, HostError>) -> Void) {
        guard app.supportsPicker else { return completion(.failure(.unsupported)) }
        let bundleURL = runningApp.bundleURL?.path ?? ""
        let cmuxCLI = app == .cmux ? cmuxCLIPath() : nil
        let launches = HostCommand.launch(for: app, copystackPath: copystackPath, session: session,
                                           bundleURL: bundleURL, cmuxCLI: cmuxCLI)
        attempt(launches: launches, index: 0, completion: completion)
    }

    private func attempt(launches: [HostCommand.Launch], index: Int,
                          completion: @escaping (Result<HostHandle, HostError>) -> Void) {
        guard index < launches.count else {
            let err = HostError.launchFailed("no launch strategy succeeded for \(app.displayName)")
            TerminalHosts.lastFailure[app] = err
            return completion(.failure(err))
        }
        run(launches[index].kind) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let handle):
                TerminalHosts.lastFailure[self.app] = nil
                completion(.success(handle))
            case .failure(let err):
                TerminalHosts.lastFailure[self.app] = err
                self.attempt(launches: launches, index: index + 1, completion: completion)
            }
        }
    }

    private func run(_ kind: HostCommand.Launch.Kind, completion: @escaping (Result<HostHandle, HostError>) -> Void) {
        switch kind {
        case .appleScript(let source):
            runAppleScript(source) { [runningApp, app] result in
                switch result {
                case .success(let windowID):
                    completion(.success(HostHandle(app: app, hostPID: runningApp.processIdentifier, windowID: windowID, newInstance: nil)))
                case .failure(let err):
                    completion(.failure(err))
                }
            }

        case .openApp(let bundleURL, let arguments):
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            config.arguments = arguments
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundleURL), configuration: config) { [app] newInstance, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(.launchFailed(error.localizedDescription)))
                    } else if let newInstance {
                        completion(.success(HostHandle(app: app, hostPID: newInstance.processIdentifier, windowID: nil, newInstance: newInstance)))
                    } else {
                        completion(.failure(.launchFailed("openApplication returned no running instance")))
                    }
                }
            }

        case .cli(let executable, let argv):
            runCLI(executable: executable, argv: argv, completion: completion)
        }
    }

    // MARK: AppleScript

    /// `NSAppleScript` blocks, so it always runs off a private serial queue;
    /// `completion` is called back on main.
    private func runAppleScript(_ source: String, completion: @escaping (Result<String?, HostError>) -> Void) {
        appleScriptQueue.async {
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
        let app = app
        let runningApp = runningApp
        DispatchQueue.global(qos: .userInitiated).async {
            guard let newWindowOutput = Self.runProcess(executable, newWindowArgs, env: env),
                  let windowID = Self.parseCmuxRef(newWindowOutput), !windowID.isEmpty else {
                return DispatchQueue.main.async { completion(.failure(.launchFailed("cmux new-window failed"))) }
            }
            for remaining in argv.dropFirst() {
                let substituted = remaining.map { $0.replacingOccurrences(of: "{WINDOW}", with: windowID) }
                if Self.runProcess(executable, substituted, env: env) == nil {
                    _ = Self.runProcess(executable, ["close-window", "--window", windowID], env: env)
                    return DispatchQueue.main.async { completion(.failure(.launchFailed("cmux send failed"))) }
                }
            }
            DispatchQueue.main.async {
                completion(.success(HostHandle(app: app, hostPID: runningApp.processIdentifier, windowID: windowID, newInstance: nil)))
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
    /// background queue); returns stdout on exit code 0, nil otherwise.
    private static func runProcess(_ executable: String, _ argv: [String], env: [String: String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = argv
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: close

    func close(_ handle: HostHandle) {
        if let newInstance = handle.newInstance {
            newInstance.terminate()
            return
        }
        guard let windowID = handle.windowID else { return }
        // cmux's windows don't understand the standard "close" Apple event
        // HostCommand.closeScript's generic template sends (confirmed
        // against a real install: "doesn't understand the close message"),
        // so close it through the CLI's own close-window command instead.
        if app == .cmux, let cli = cmuxCLIPath() {
            let env = cmuxEnvironment()
            DispatchQueue.global(qos: .utility).async {
                _ = Self.runProcess(cli, ["close-window", "--window", windowID], env: env)
            }
            return
        }
        guard let script = HostCommand.closeScript(for: app, windowID: windowID) else { return }
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
            // Hosts that can't set their own window size natively (currently
            // only cmux, which has no window-size CLI/AppleScript option)
            // get a fixed ~100x30 terminal cell size; everyone else already
            // sized itself via HostCommand's launch, so only re-centre it.
            let size = app == .cmux ? CGSize(width: 900, height: 560) : (AXWindow.frame(of: window)?.size ?? CGSize(width: 900, height: 560))
            let cocoaOrigin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            let axOrigin = CGPoint(x: cocoaOrigin.x, y: primaryH - cocoaOrigin.y - size.height)
            AXWindow.setFrame(window, CGRect(origin: axOrigin, size: size))
            return
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.poll(handle: handle, windowTitle: windowTitle, deadline: deadline)
        }
    }

    private static func screenUnderMouse() -> NSRect {
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
