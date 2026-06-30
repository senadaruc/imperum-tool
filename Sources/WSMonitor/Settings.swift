import SwiftUI
import ServiceManagement
import WSCore

/// User-configurable settings, persisted in UserDefaults. Changes fire `onChange`
/// so the AppController can re-apply them live (timer cadence, spike thresholds).
final class AppConfig: ObservableObject {
    @Published var intervalSeconds: Double { didSet { save(); onChange?() } }
    @Published var cpuThreshold: Double    { didSet { save(); onChange?() } }
    @Published var gpuThreshold: Double     { didSet { save(); onChange?() } }
    @Published var launchAtLogin: Bool      { didSet { applyLogin() } }

    /// Called after a persisted value changes (not for launchAtLogin, which is its own side-effect).
    var onChange: (() -> Void)?

    private static let kInterval = "intervalSeconds"
    private static let kCPU = "cpuThreshold"
    private static let kGPU = "gpuThreshold"

    init() {
        let d = UserDefaults.standard
        intervalSeconds = (d.object(forKey: Self.kInterval) as? Double).map { max(2, min(30, $0)) } ?? 5
        cpuThreshold    = (d.object(forKey: Self.kCPU) as? Double).map { max(20, min(100, $0)) } ?? 60
        gpuThreshold    = (d.object(forKey: Self.kGPU) as? Double).map { max(20, min(100, $0)) } ?? 80
        launchAtLogin   = SMAppService.mainApp.status == .enabled
        // didSet does not fire during init — no accidental login-item churn here.
    }

    var spikeConfig: SpikeConfig {
        SpikeConfig(cpuThreshold: cpuThreshold, gpuThreshold: gpuThreshold)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(intervalSeconds, forKey: Self.kInterval)
        d.set(cpuThreshold, forKey: Self.kCPU)
        d.set(gpuThreshold, forKey: Self.kGPU)
    }

    private func applyLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            // Registration can fail (e.g. app not in /Applications). Revert the toggle to reality.
            let actual = SMAppService.mainApp.status == .enabled
            if launchAtLogin != actual {
                DispatchQueue.main.async { self.launchAtLogin = actual }
            }
            NSLog("WSMonitor login-item change failed: \(error.localizedDescription)")
        }
    }
}

func appVersionString() -> String {
    let info = Bundle.main.infoDictionary
    let v = info?["CFBundleShortVersionString"] as? String ?? "?"
    let b = info?["CFBundleVersion"] as? String
    return b != nil && b != v ? "\(v) (\(b!))" : v
}

struct SettingsView: View {
    @ObservedObject var config: AppConfig

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $config.launchAtLogin)
                Text("Start WSMonitor automatically when you log in.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sampling") {
                Stepper(value: $config.intervalSeconds, in: 2...30, step: 1) {
                    Text("Refresh every \(Int(config.intervalSeconds)) s")
                }
                Text("How often WindowServer, displays and processes are sampled. Lower = more responsive, slightly more overhead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spike thresholds") {
                Stepper(value: $config.cpuThreshold, in: 20...100, step: 5) {
                    Text("Flag when WindowServer CPU > \(Int(config.cpuThreshold))%")
                }
                Stepper(value: $config.gpuThreshold, in: 20...100, step: 5) {
                    Text("Flag when global GPU > \(Int(config.gpuThreshold))%")
                }
                Text("Crossing either threshold turns the menu-bar gauge red and records a spike.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .font(.system(size: 26)).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("WSMonitor").font(.headline)
                            Text("Version \(appVersionString())").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Finds which app is driving WindowServer CPU / RAM / GPU spikes — sudoless detection, live correlation, a pause-and-test causation check, and (optionally) powermetrics Energy Impact.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Per-app GPU% isn't exposed on Apple Silicon; WSMonitor works around that with proxy ranking and causation tests.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Developer ID: Imperum B.V.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 540)
    }
}
