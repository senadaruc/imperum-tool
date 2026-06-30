import Foundation
import ServiceManagement
import WSCore

@objc protocol HelperProtocol {
    func runPowerMetrics(withReply reply: @escaping (String) -> Void)
}

/// Manages the privileged powermetrics helper (SMAppService daemon) and talks
/// to it over XPC. The app is fully functional without it; this only adds
/// authoritative per-process GPU/energy at spike time.
final class PowerMetricsClient {
    static let shared = PowerMetricsClient()
    private let service = SMAppService.daemon(plistName: "io.imperum.wsmonitor.helper.plist")

    /// First raw capture is written here so the parser can be validated against
    /// the machine's actual powermetrics format.
    static let rawDumpPath = NSString(string: "~/WSMonitor-powermetrics-sample.txt").expandingTildeInPath

    enum State { case enabled, requiresApproval, notRegistered, error(String) }

    var state: State {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    var isEnabled: Bool { if case .enabled = state { return true }; return false }

    /// Register (installs the daemon; user approves in System Settings → Login Items).
    func install() -> Result<Void, Error> {
        do { try service.register(); return .success(()) }
        catch { return .failure(error) }
    }

    func uninstall() -> Result<Void, Error> {
        do { try service.unregister(); return .success(()) }
        catch { return .failure(error) }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Capture per-process GPU/energy via the helper. Calls back on an arbitrary
    /// queue with the parsed processes (empty on failure).
    private var dumpedRaw = false
    func capture(completion: @escaping ([PMProcess]) -> Void) {
        guard isEnabled else { completion([]); return }
        let conn = NSXPCConnection(machServiceName: "io.imperum.wsmonitor.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in completion([]) } as? HelperProtocol
        guard let proxy else { completion([]); conn.invalidate(); return }
        proxy.runPowerMetrics { [weak self] text in
            if let self, !self.dumpedRaw {
                self.dumpedRaw = true
                try? text.write(toFile: Self.rawDumpPath, atomically: true, encoding: .utf8)
            }
            completion(parsePowerMetrics(text))
            conn.invalidate()
        }
    }
}
