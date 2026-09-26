import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImperumCore

struct ClipboardSettingsTab: View {
    @ObservedObject var store: ClipboardSettingsStore
    let onClearAll: () -> Void
    @State private var selectedExclusion: String?
    @State private var accessibilityGranted = ActionRunner.isTrusted
    @State private var confirmClear = false

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
        .onAppear { accessibilityGranted = ActionRunner.isTrusted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = ActionRunner.isTrusted
        }
        .confirmationDialog("Clear the copy stack?", isPresented: $confirmClear) {
            Button("Clear All Clipboard Data", role: .destructive) { onClearAll() }
        } message: {
            Text("This removes every clip from memory and deletes the local archive.")
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
