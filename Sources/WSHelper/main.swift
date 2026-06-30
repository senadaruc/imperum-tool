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
