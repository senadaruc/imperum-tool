import SwiftUI
import ServiceManagement
import ImperumCore

/// User-configurable settings, persisted in UserDefaults. Changes fire `onChange`
/// so the AppController can re-apply them live (timer cadence, spike thresholds).
final class AppConfig: ObservableObject {
    @Published var intervalSeconds: Double { didSet { save(); onChange?() } }
    @Published var cpuThreshold: Double    { didSet { save(); onChange?() } }
    @Published var gpuThreshold: Double     { didSet { save(); onChange?() } }
    @Published var launchAtLogin: Bool      { didSet { applyLogin() } }
    /// Non-nil when the login item exists but macOS needs the user to approve it
    /// in System Settings → Login Items (SMAppService `.requiresApproval`).
    @Published var loginNeedsApproval = false

    /// Called after a persisted value changes (not for launchAtLogin, which is its own side-effect).
    var onChange: (() -> Void)?
    /// Guards against the programmatic re-sync of `launchAtLogin` re-triggering applyLogin().
    private var syncing = false

    private static let kInterval = "intervalSeconds"
    private static let kCPU = "cpuThreshold"
    private static let kGPU = "gpuThreshold"

    init() {
        let d = UserDefaults.standard
        intervalSeconds = (d.object(forKey: Self.kInterval) as? Double).map { max(2, min(30, $0)) } ?? 5
        cpuThreshold    = (d.object(forKey: Self.kCPU) as? Double).map { max(20, min(100, $0)) } ?? 60
        gpuThreshold    = (d.object(forKey: Self.kGPU) as? Double).map { max(20, min(100, $0)) } ?? 80
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled || status == .requiresApproval)
        loginNeedsApproval = (status == .requiresApproval)
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

    /// Re-read the OS truth and reconcile the toggle (call when Settings appears).
    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        let on = (status == .enabled || status == .requiresApproval)
        loginNeedsApproval = (status == .requiresApproval)
        if launchAtLogin != on { setLaunchSilently(on) }
    }

    private func setLaunchSilently(_ value: Bool) {
        syncing = true
        launchAtLogin = value
        syncing = false
    }

    private func applyLogin() {
        guard !syncing else { return }   // ignore programmatic re-sync
        let svc = SMAppService.mainApp
        do {
            if launchAtLogin {
                if svc.status != .enabled { try svc.register() }
            } else {
                if svc.status != .notRegistered { try svc.unregister() }
            }
        } catch {
            NSLog("Imperum Tool login-item change failed: \(error.localizedDescription)")
        }
        // `.requiresApproval` is NOT a failure — the item is registered, macOS just
        // wants the user to approve it. Keep the toggle on and surface the hint.
        let status = svc.status
        let on = (status == .enabled || status == .requiresApproval)
        loginNeedsApproval = (status == .requiresApproval)
        if launchAtLogin != on {
            DispatchQueue.main.async { self.setLaunchSilently(on) }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

func appVersionString() -> String {
    let info = Bundle.main.infoDictionary
    let v = info?["CFBundleShortVersionString"] as? String ?? "?"
    let b = info?["CFBundleVersion"] as? String
    return b != nil && b != v ? "\(v) (\(b!))" : v
}

/// Builds the Settings window content: a native preferences-style toolbar
/// (icon + label per tab, like System Settings) hosting the SwiftUI tabs.
/// NSTabViewController in `.toolbar` style resizes the window to each tab's
/// `preferredContentSize` when switching.
enum SettingsTabs {
    /// Tab shown when the window opens ("general" | "taps" | "volumes" | "clipboard").
    static var initialTab = "general"
    /// One-shot: set to switch an already-open Settings window to this tab
    /// the next time `showSettings()` runs; cleared right after.
    static var requestedTab: String?

    static func makeController(config: AppConfig, blockStore: VolumeBlockStore,
                               tapStore: TapSettingsStore, tapController: TapGestureController,
                               clipboardStore: ClipboardSettingsStore, onClearClipboard: @escaping () -> Void) -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func add<V: View>(_ id: String, _ label: String, _ symbol: String, size: NSSize, _ view: V) {
            let host = NSHostingController(rootView: view)
            host.preferredContentSize = size
            let item = NSTabViewItem(viewController: host)
            item.identifier = id
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }
        add("general", "General", "gearshape", size: NSSize(width: 600, height: 640),
            GeneralSettingsTab(config: config))
        add("taps", "Tap Gestures", "hand.tap", size: NSSize(width: 600, height: 720),
            TapGesturesSettingsTab(store: tapStore, controller: tapController))
        add("clipboard", "Clipboard", "doc.on.clipboard", size: NSSize(width: 600, height: 720),
            ClipboardSettingsTab(store: clipboardStore, onClearAll: onClearClipboard))
        add("volumes", "External Volumes", "externaldrive", size: NSSize(width: 600, height: 420),
            Form { ExternalVolumesSettingsSection(blockStore: blockStore) }.formStyle(.grouped))
        if let i = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == initialTab }) {
            tabs.selectedTabViewItemIndex = i
        }
        return tabs
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var config: AppConfig

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $config.launchAtLogin)
                if config.loginNeedsApproval {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("macOS needs you to approve this. Enable “Imperum Tool” under Allow in the Background / Open at Login.")
                                .font(.caption)
                            Button("Open Login Items settings…") { config.openLoginItemsSettings() }
                                .controlSize(.small)
                        }
                    }
                } else {
                    Text("Start Imperum Tool automatically when you log in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                            Text("Imperum Tool").font(.headline)
                            Text("Version \(appVersionString())").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Finds which app is driving WindowServer CPU / RAM / GPU spikes — sudoless detection, live correlation, a pause-and-test causation check, and (optionally) powermetrics Energy Impact.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Per-app GPU% isn't exposed on Apple Silicon; Imperum Tool works around that with proxy ranking and causation tests.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Developer ID: Imperum B.V.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { config.refreshLoginStatus() }
    }
}
