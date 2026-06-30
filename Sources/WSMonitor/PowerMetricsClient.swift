import Foundation
import WSCore

/// Runs powermetrics as root in a hardened way:
///   - a ROOT-OWNED wrapper at `wrapperPath` execs powermetrics with a FIXED
///     argv (ignores all arguments), so no caller can pass -o/--output-file etc.
///   - the sudoers rule allows ONLY that wrapper with NO arguments (`""`).
/// This avoids the arbitrary-root-file-write escalation that a blanket
/// `NOPASSWD: /usr/bin/powermetrics` would allow. No XPC, no daemon.
final class PowerMetricsClient {
    static let shared = PowerMetricsClient()
    static let rawDumpPath = NSString(string: "~/WSMonitor-powermetrics-sample.txt").expandingTildeInPath

    private let wrapperPath = "/usr/local/libexec/wsmonitor-powermetrics"
    private let sudoersPath = "/etc/sudoers.d/wsmonitor"

    private static let wrapperContents = """
    #!/bin/sh
    # Installed by WSMonitor. Root-owned, fixed argv — ALL arguments are ignored.
    exec /usr/bin/powermetrics --samplers tasks,gpu_power --show-process-gpu --show-process-energy -n 1 -i 200
    """

    enum State { case enabled, notEnabled, error(String) }

    /// `sudo -n -l <wrapper>` exits 0 iff the NOPASSWD rule is active.
    var isEnabled: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l", wrapperPath]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    var state: State { isEnabled ? .enabled : .notEnabled }

    /// Install the wrapper + scoped sudoers rule (one admin-password prompt).
    func install() -> Result<Void, Error> {
        let user = NSUserName()
        // Defense-in-depth: refuse any username that isn't a plain account name.
        guard user.range(of: "^[a-zA-Z_][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil else {
            return .failure(mkErr("Unexpected username '\(user)'; refusing to modify sudoers."))
        }
        // Stage files in a private, user-only temp dir (UUID paths — no user content
        // in the privileged shell string; the username lives only inside the file).
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("wsmon-\(UUID().uuidString)")
        let wrapperTmp = (dir as NSString).appendingPathComponent("wrapper")
        let sudoersTmp = (dir as NSString).appendingPathComponent("sudoers")
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Self.wrapperContents.write(toFile: wrapperTmp, atomically: true, encoding: .utf8)
            let line = "\(user) ALL=(root) NOPASSWD: \(wrapperPath) \"\"\n"
            try line.write(toFile: sudoersTmp, atomically: true, encoding: .utf8)
        } catch { return .failure(error) }

        // Privileged step: install root-owned files; validate sudoers or roll back.
        // Only fixed/UUID paths appear in this string — no user-controlled content.
        let cmd = [
            "mkdir -p /usr/local/libexec",
            "chown root:wheel /usr/local/libexec",
            "chmod 755 /usr/local/libexec",
            "install -o root -g wheel -m 755 '\(wrapperTmp)' '\(wrapperPath)'",
            "install -o root -g wheel -m 440 '\(sudoersTmp)' '\(sudoersPath)'",
            "visudo -cf '\(sudoersPath)' || rm -f '\(sudoersPath)'",
        ].joined(separator: " && ")
        let result = runAdmin(cmd)
        try? FileManager.default.removeItem(atPath: dir)
        return result
    }

    func uninstall() -> Result<Void, Error> {
        runAdmin("rm -f '\(sudoersPath)' '\(wrapperPath)'")
    }

    private func runAdmin(_ shellCommand: String) -> Result<Void, Error> {
        // Escape backslashes and double quotes for the AppleScript string literal.
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else {
            return .failure(mkErr("Could not build admin script."))
        }
        script.executeAndReturnError(&err)
        if let err {
            return .failure(mkErr((err[NSAppleScript.errorMessage] as? String) ?? "Admin command failed."))
        }
        return .success(())
    }

    private func mkErr(_ msg: String) -> Error {
        NSError(domain: "WSMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private var inFlight = false

    /// Capture per-process GPU/energy via the wrapper. Off the main thread; back on main.
    func capture(completion: @escaping ([PMProcess]) -> Void) {
        guard !inFlight else { completion([]); return }
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let text = self.runWrapper()
            if !text.isEmpty, !FileManager.default.fileExists(atPath: Self.rawDumpPath) {
                try? text.write(toFile: Self.rawDumpPath, atomically: true, encoding: .utf8)
            }
            let procs = parsePowerMetrics(text)
            self.inFlight = false
            DispatchQueue.main.async { completion(procs) }
        }
    }

    private func runWrapper() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", wrapperPath]          // no extra args — matches the sudoers rule
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
