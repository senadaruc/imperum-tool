import Foundation
import WSCore

/// Runs `powermetrics` as root via a scoped, passwordless sudoers rule
/// (/etc/sudoers.d/wsmonitor, NOPASSWD for /usr/bin/powermetrics only). The
/// user authorizes installation once through a native admin-password prompt.
/// No XPC, no daemon — the privileged command is read-only diagnostic.
final class PowerMetricsClient {
    static let shared = PowerMetricsClient()
    static let rawDumpPath = NSString(string: "~/WSMonitor-powermetrics-sample.txt").expandingTildeInPath
    private let sudoersPath = "/etc/sudoers.d/wsmonitor"

    enum State { case enabled, notEnabled, error(String) }

    /// `sudo -n -l /usr/bin/powermetrics` exits 0 iff the NOPASSWD rule is active.
    var isEnabled: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l", "/usr/bin/powermetrics"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    var state: State { isEnabled ? .enabled : .notEnabled }

    /// Install the scoped sudoers rule (prompts for admin password once).
    func install() -> Result<Void, Error> {
        let user = NSUserName()
        let cmd = "echo '\(user) ALL=(root) NOPASSWD: /usr/bin/powermetrics' > \(sudoersPath) && chmod 440 \(sudoersPath) && visudo -cf \(sudoersPath)"
        return runAdmin(cmd)
    }

    func uninstall() -> Result<Void, Error> {
        runAdmin("rm -f \(sudoersPath)")
    }

    private func runAdmin(_ shellCommand: String) -> Result<Void, Error> {
        // shellCommand uses only single quotes/&&/>, so it needs no escaping
        // inside the AppleScript double-quoted string.
        let src = "do shell script \"\(shellCommand)\" with administrator privileges"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else {
            return .failure(NSError(domain: "WSMonitor", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not build admin script"]))
        }
        script.executeAndReturnError(&err)
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "admin command failed"
            return .failure(NSError(domain: "WSMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        return .success(())
    }

    private var inFlight = false

    /// Capture per-process GPU/energy. Runs off the main thread; calls back on main.
    func capture(completion: @escaping ([PMProcess]) -> Void) {
        guard !inFlight else { completion([]); return }
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let text = self.runPowerMetrics()
            if !text.isEmpty, !FileManager.default.fileExists(atPath: Self.rawDumpPath) {
                try? text.write(toFile: Self.rawDumpPath, atomically: true, encoding: .utf8)
            }
            let procs = parsePowerMetrics(text)
            self.inFlight = false
            DispatchQueue.main.async { completion(procs) }
        }
    }

    private func runPowerMetrics() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/powermetrics", "--samplers", "tasks,gpu_power",
                       "--show-process-gpu", "--show-process-energy", "-n", "1", "-i", "200"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
