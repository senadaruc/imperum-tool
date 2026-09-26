import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImperumCore
import CopyStackKit

struct ClipboardSettingsTab: View {
    @ObservedObject var store: ClipboardSettingsStore
    let onClearAll: () -> Void
    @State private var selectedExclusion: String?
    @State private var accessibilityGranted = ActionRunner.isTrusted
    @State private var confirmClear = false
    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var terminalStatuses: [TerminalApp: HostError?] = [:]

    var body: some View {
        Form {
            Section("Capture & trigger") {
                Toggle("Enable clipboard history", isOn: $store.settings.enabled)
                Picker("Open the copy stack with", selection: $store.settings.trigger) {
                    Text("Double-tap ⌘V").tag(ClipboardTrigger.doubleTap)
                    Text("⌘⇧V").tag(ClipboardTrigger.hotkey)
                    Text("Both").tag(ClipboardTrigger.both)
                }
                if store.settings.trigger.usesDoubleTap {
                    LabeledContent("Double-tap window: \(store.settings.doubleTapMs) ms") {
                        Slider(value: Binding(get: { Double(store.settings.doubleTapMs) },
                                              set: { store.settings.doubleTapMs = Int($0.rounded()) }),
                               in: 200...400, step: 10)
                            .frame(width: 180)
                    }
                    if !accessibilityGranted {
                        HStack {
                            Text("Double-tap ⌘V needs Accessibility access.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Accessibility Settings") { ActionRunner.ensureAccessibility() }
                        }
                    }
                }
                Stepper("Maximum stack size: \(store.settings.maxStack)", value: $store.settings.maxStack, in: 20...2000, step: 10)
                Stepper("Forget unpinned clips after \(store.settings.retentionDays) days", value: $store.settings.retentionDays, in: 1...365)
                Toggle("Clear stack when Imperum Tool quits", isOn: $store.settings.clearOnQuit)
                Text("Off by default: your clips are kept in a local encrypted file so your history is there next time. Turn on for session-only memory. Either way, nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show clip count in the menu bar", isOn: $store.settings.showBadge)
            }

            Section("Terminal") {
                Toggle("Use a terminal picker when a terminal app is in front", isOn: $store.settings.terminalPicker)
                Text("Double-tap ⌘V in Ghostty, cmux, iTerm2, kitty or Terminal opens the Copy Stack in a new window of that terminal. Warp uses the regular panel. macOS asks once per terminal to allow Imperum Tool to control it.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Allow command-line access (copystack)", isOn: $store.settings.allowCLI)
                Text("Runs a private socket so the copystack command can read your history. Only your own user account can connect. Turn off to keep the history reachable from this app alone.")
                    .font(.caption).foregroundStyle(.secondary)

                SecureField("cmux socket password", text: $store.settings.cmuxSocketPassword)
                Text("Only needed if cmux Settings has a socket password set.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("Terminal status").font(.headline).padding(.top, 6)
                ForEach(TerminalApp.allCases.filter(\.supportsPicker), id: \.self) { app in
                    HStack {
                        Text(app.displayName)
                        Spacer()
                        Text(statusText(for: app)).font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if cliInstalled {
                        Button("Installed") {}.disabled(true)
                    } else if let path = CLIInstaller.bundledExecutablePath {
                        Button("Install command-line tool…") { installCLI(from: path) }
                    } else {
                        Button("Install command-line tool…") {}
                            .disabled(true)
                        Text("Available after installing the app bundle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !cliInstalled, let path = CLIInstaller.bundledExecutablePath {
                    Text("ln -s \"\(path)\" /usr/local/bin/copystack")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Privacy") {
                Text("Clipboard content never leaves this Mac. Copies made in excluded applications are not captured.")
                    .font(.callout)
                Toggle("Show website icons for links", isOn: $store.settings.showFavicons)
                Text("Icons are fetched from the linked website itself, so the domain of a copied link is contacted. Turn off for strict privacy.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("Excluded Applications").font(.headline).padding(.top, 6)
                List(selection: $selectedExclusion) {
                    ForEach(store.settings.excludedBundleIDs, id: \.self) { id in
                        HStack(spacing: 8) {
                            Image(nsImage: Self.icon(for: id)).resizable().frame(width: 18, height: 18)
                            Text(Self.name(for: id))
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(id)
                    }
                }
                .frame(height: 160)
                HStack {
                    Button("Add Application…") { addApplication() }
                    Button("Remove") {
                        if let s = selectedExclusion { store.settings.excludedBundleIDs.removeAll { $0 == s }; selectedExclusion = nil }
                    }
                    .disabled(selectedExclusion == nil)
                    Spacer()
                    Button("Clear All Clipboard Data", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            accessibilityGranted = ActionRunner.isTrusted
            refreshTerminalState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = ActionRunner.isTrusted
            refreshTerminalState()
        }
        .confirmationDialog("Clear the copy stack?", isPresented: $confirmClear) {
            Button("Clear All Clipboard Data", role: .destructive) { onClearAll() }
        } message: {
            Text("This removes every clip from memory and deletes the local archive.")
        }
    }

    @MainActor
    private func refreshTerminalState() {
        cliInstalled = CLIInstaller.isInstalled
        for app in TerminalApp.allCases where app.supportsPicker {
            terminalStatuses[app] = TerminalHosts.lastFailure[app]
        }
    }

    @MainActor
    private func statusText(for app: TerminalApp) -> String {
        guard let failure = terminalStatuses[app] ?? nil else { return "Ready" }
        switch failure {
        case .unsupported: return "not supported"
        case .automationDenied: return "allow Imperum Tool in System Settings › Privacy & Security › Automation"
        case .notRunning: return "not running"
        case .launchFailed(let msg): return msg
        case .timeout: return "picker did not start"
        }
    }

    private func installCLI(from path: String) {
        switch CLIInstaller.install(bundledExecutablePath: path) {
        case .success:
            cliInstalled = CLIInstaller.isInstalled
        case .failure(let error):
            NSLog("Imperum Tool: copystack CLI install failed: \(error.localizedDescription)")
        }
    }

    private func addApplication() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !store.settings.excludedBundleIDs.contains(id) {
                store.settings.excludedBundleIDs.append(id)
            }
        }
    }

    static func url(for bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static func name(for bundleID: String) -> String {
        guard let u = url(for: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    static func icon(for bundleID: String) -> NSImage {
        if let u = url(for: bundleID) { return NSWorkspace.shared.icon(forFile: u.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

/// Installs the `/usr/local/bin/copystack` symlink pointing at this bundle's
/// `copystack` auxiliary executable, via the same NSAppleScript
/// "administrator privileges" pattern as `PowerMetricsClient.install`.
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/copystack"

    /// Nil in a dev build where the app isn't bundled with a `copystack` auxiliary executable.
    static var bundledExecutablePath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "copystack")?.path
    }

    /// True when the symlink exists and resolves to this bundle's `copystack` binary.
    static var isInstalled: Bool {
        guard let target = bundledExecutablePath else { return false }
        guard let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else { return false }
        // `destinationOfSymbolicLink` may return a relative path; resolve it against the link's directory.
        let resolvedAbsolute = resolved.hasPrefix("/") ? resolved
            : ((linkPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(resolved)
        return resolvedAbsolute == target
    }

    static func install(bundledExecutablePath path: String) -> Result<Void, Error> {
        // Single-quote the paths (shell level) so this needs no nested double-quote
        // escaping; a literal single quote in either path is escaped the POSIX way.
        func shellQuote(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }
        let cmd = "mkdir -p /usr/local/bin && ln -sf \(shellQuote(path)) \(shellQuote(linkPath))"
        // Escape once more for the AppleScript string literal that wraps the whole command.
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else {
            return .failure(NSError(domain: "ImperumTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build admin script."]))
        }
        script.executeAndReturnError(&err)
        if let err {
            return .failure(NSError(domain: "ImperumTool", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: (err[NSAppleScript.errorMessage] as? String) ?? "Admin command failed."]))
        }
        return .success(())
    }
}
