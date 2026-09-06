import SwiftUI
import ImperumCore

/// Settings section listing currently-connected external volumes with a
/// block-auto-mount toggle each, plus any blocked volumes that aren't
/// currently connected (so they remain manageable/removable).
struct ExternalVolumesSettingsSection: View {
    @ObservedObject var blockStore: VolumeBlockStore

    @State private var connected: [ExternalVolume] = []
    @State private var isRefreshing = false
    @State private var refreshWorkItem: DispatchWorkItem?

    private var disconnectedBlocked: [BlockedVolume] {
        blockStore.blocked.filter { blocked in
            !connected.contains { $0.compositeID == blocked.compositeID }
        }
    }

    var body: some View {
        Section("External Volumes") {
            HStack {
                Text("Connected").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(action: refresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
            }

            if connected.isEmpty {
                Text(isRefreshing ? "Scanning…" : "No external volumes found.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(connected) { volume in
                    Toggle(volume.name, isOn: Binding(
                        get: { blockStore.isBlocked(volume.compositeID) },
                        set: { isOn in
                            if isOn { blockStore.block(volume) } else { blockStore.unblock(volume.compositeID) }
                        }
                    ))
                }
            }

            if !disconnectedBlocked.isEmpty {
                Text("Blocked (not currently connected)").font(.subheadline).foregroundStyle(.secondary)
                ForEach(disconnectedBlocked) { blocked in
                    HStack {
                        Text(blocked.name)
                        Spacer()
                        Button(role: .destructive) {
                            blockStore.unblock(blocked.compositeID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Text("Blocked volumes won't auto-mount when connected. Untoggle here, or use Disk Utility, to mount them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didMountNotification)) { _ in scheduleRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didUnmountNotification)) { _ in scheduleRefresh() }
    }

    private func refresh() {
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = fetchExternalVolumes()
            DispatchQueue.main.async {
                self.connected = volumes
                self.isRefreshing = false
            }
        }
    }

    /// Debounces bursts of mount/unmount notifications (e.g. a
    /// multi-partition dock connecting fires one per volume) into a single
    /// refresh.
    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem(block: refresh)
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
