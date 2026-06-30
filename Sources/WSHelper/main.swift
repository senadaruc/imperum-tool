import Foundation

// Privileged LaunchDaemon (root). Sole capability: run powermetrics once and
// return its raw output over XPC. No arbitrary command execution.

@objc protocol HelperProtocol {
    func runPowerMetrics(withReply reply: @escaping (String) -> Void)
}

final class Helper: NSObject, HelperProtocol, NSXPCListenerDelegate {
    func runPowerMetrics(withReply reply: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        p.arguments = ["--samplers", "tasks,gpu_power",
                       "--show-process-gpu", "--show-process-energy",
                       "-n", "1", "-i", "200"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { reply("ERROR: \(error.localizedDescription)"); return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        reply(String(data: data, encoding: .utf8) ?? "")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // SECURITY: this helper runs as root. Only accept connections from a
        // process signed with OUR Developer ID identity + bundle id. Without
        // this, any local process could drive the root helper. setCodeSigningRequirement
        // (macOS 13+) validates the peer's audit token against the requirement
        // and rejects mismatches automatically.
        let requirement =
            "anchor apple generic and identifier \"io.imperum.wsmonitor\" " +
            "and certificate leaf[subject.OU] = \"9TZGSR8224\""
        // Enforced by the XPC runtime: peers not matching this requirement have
        // their messages rejected (the connection is treated as invalid).
        conn.setCodeSigningRequirement(requirement)
        conn.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }
}

let delegate = Helper()
let listener = NSXPCListener(machServiceName: "io.imperum.wsmonitor.helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
