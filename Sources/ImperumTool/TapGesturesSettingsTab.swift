import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImperumCore

/// Tap Gestures settings: master switch, the two-column tap map (mirrors the
/// product page), calibration, sensitivity, and permissions. Custom cards
/// instead of a grouped Form so the six slots sit side by side and each
/// slot's parameter editor stays inside its own card.
struct TapGesturesSettingsTab: View {
    @ObservedObject var store: TapSettingsStore
    @ObservedObject var controller: TapGestureController
    @State private var accessibilityGranted = ActionRunner.isTrusted
    @State private var shortcutNames: [String] = []

    private var unavailable: Bool {
        if case .unavailable = controller.status { return true } else { return false }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                tapMapCard
                HStack(alignment: .top, spacing: 14) {
                    calibrationCard
                    sensitivityCard
                }
                .fixedSize(horizontal: false, vertical: true)
                permissionsCard
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            accessibilityGranted = ActionRunner.isTrusted
            ActionRunner.availableShortcuts { shortcutNames = $0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = ActionRunner.isTrusted
        }
    }

    // MARK: Header

    private var headerCard: some View {
        Card {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "hand.tap.fill").font(.system(size: 22)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tap gestures").font(.title3.weight(.semibold))
                    Text("Tap the palm rest of your MacBook to run an action.")
                        .font(.caption).foregroundStyle(.secondary)
                    statusLine
                }
                Spacer()
                Toggle("", isOn: Binding(get: { store.settings.enabled }, set: { store.settings.enabled = $0 }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(unavailable)
            }
            if store.settings.enabled || controller.lastTap != nil {
                Divider().padding(.vertical, 8)
                lastTapRow
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch controller.status {
        case .unavailable(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .on:
            Label("Motion sensor active", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .off:
            Label("Motion sensor idle", systemImage: "circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lastTapRow: some View {
        HStack(spacing: 8) {
            if let last = controller.lastTap {
                Image(systemName: "hand.tap.fill").foregroundStyle(Color.accentColor)
                Text(last).font(.callout.weight(.medium))
            } else {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("Waiting for taps — tap the palm rest to test.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Tap map

    private var tapMapCard: some View {
        Card(title: "The tap map", subtitle: "Choose a side, choose a tap count, choose what happens.") {
            HStack(alignment: .top, spacing: 12) {
                sideColumn(.left)
                sideColumn(.right)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sideColumn(_ side: TapSide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(side == .left ? "LEFT SIDE" : "RIGHT SIDE")
                .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ForEach(1...3, id: \.self) { count in
                let slot = TapSlot(side, count)
                SlotRow(slot: slot,
                        action: store.settings.map[slot],
                        shortcutNames: shortcutNames,
                        update: { store.settings.map[slot] = $0 })
                    .id(slot.key)
                if count < 3 { Divider().padding(.horizontal, 12) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    // MARK: Calibration

    private var calibrationCard: some View {
        Card(title: "Left / right calibration", subtitle: nil) {
            let n = TapGestureController.calibrationTapsPerSide
            switch controller.calibration {
            case .idle:
                VStack(alignment: .leading, spacing: 8) {
                    if let c = store.settings.calibration {
                        Label("Calibrated", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.medium))
                        Text("Sides are told apart by \(featureName(c.feature)).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Not calibrated", systemImage: "questionmark.circle").foregroundStyle(.orange).font(.callout.weight(.medium))
                        Text("Sides are guessed until you calibrate. Takes ten taps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(store.settings.calibration == nil ? "Calibrate…" : "Recalibrate…") { controller.startCalibration() }
                        .disabled(unavailable)
                }
            case .collectingLeft(let k):
                calibrationProgress(side: "LEFT", k, n)
            case .collectingRight(let k):
                calibrationProgress(side: "RIGHT", k, n)
            case .done(let c):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Calibrated", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.medium))
                    Text("Using \(featureName(c.feature)).").font(.caption).foregroundStyle(.secondary)
                    Button("Done") { controller.cancelCalibration() }
                }
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't tell the sides apart", systemImage: "xmark.circle.fill").foregroundStyle(.orange).font(.callout.weight(.medium))
                    Text("Tap firmly near each edge of the palm rest and try again.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") { controller.startCalibration() }
                        Button("Cancel") { controller.cancelCalibration() }
                    }
                }
            }
        }
    }

    private func calibrationProgress(side: String, _ k: Int, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap the \(side) palm rest").font(.callout.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(0..<n, id: \.self) { i in
                    Circle().fill(i < k ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 12, height: 12)
                }
                Text("\(k) of \(n)").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
            }
            Button("Cancel") { controller.cancelCalibration() }
        }
    }

    private func featureName(_ f: SideFeature) -> String {
        switch f {
        case .accelX: return "sideways acceleration"
        case .gyroX: return "gyro pitch"
        case .gyroY: return "gyro roll"
        case .gyroZ: return "gyro yaw"
        }
    }

    // MARK: Sensitivity

    /// Slider runs Firm → Light; threshold is the inverse.
    private var sensitivity: Binding<Double> {
        Binding(get: { 0.27 - store.settings.threshold }, set: { store.settings.threshold = 0.27 - $0 })
    }

    private var sensitivityCard: some View {
        Card(title: "Sensitivity", subtitle: nil) {
            VStack(alignment: .leading, spacing: 8) {
                Slider(value: sensitivity, in: 0.02...0.25)
                HStack {
                    Text("Firm").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Light").font(.caption).foregroundStyle(.secondary)
                }
                Text("Light catches gentle fingertip taps. Firm needs a solid knock and ignores desk bumps. Taps within ¼ s of a keypress or click are always ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(accessibilityGranted ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessibilityGranted ? "Accessibility access granted" : "Accessibility access needed")
                        .font(.callout.weight(.medium))
                    Text("Keystroke, media-key and window actions are sent through macOS Accessibility.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !accessibilityGranted {
                    Button("Grant…") {
                        ActionRunner.ensureAccessibility()
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Card container

private struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(.headline) }
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
        )
    }
}

// MARK: - One slot in the tap map

private struct SlotRow: View {
    let slot: TapSlot
    let action: TapAction
    let shortcutNames: [String]
    let update: (TapAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(slot.title).font(.callout).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                actionMenu
                Spacer(minLength: 0)
            }
            parameterEditor
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var actionMenu: some View {
        Menu {
            ForEach(ActionCategory.allCases, id: \.self) { cat in
                Menu {
                    ForEach(TapAction.Kind.inCategory(cat), id: \.self) { k in
                        Button {
                            if k != action.kind { update(TapAction(k)) }
                        } label: {
                            if k == action.kind { Label(k.displayName, systemImage: "checkmark") } else { Text(k.displayName) }
                        }
                    }
                } label: { Label(cat.rawValue, systemImage: icon(for: cat)) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon(for: action.kind.category)).foregroundStyle(action.kind == .none ? .secondary : Color.accentColor)
                Text(action.kind == .none ? "Choose action…" : action.kind.displayName)
                    .lineLimit(1)
                    .foregroundStyle(action.kind == .none ? .secondary : .primary)
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }

    @ViewBuilder private var parameterEditor: some View {
        switch action.kind.parameter {
        case .none:
            EmptyView()
        case .keyCombo:
            KeyComboRecorder(combo: action.keyCombo) { var a = action; a.keyCombo = $0; update(a) }
                .padding(.leading, 56)
        case .applicationPath:
            HStack(spacing: 8) {
                Text(action.isConfigured ? action.summary : "No app chosen")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Choose…") { chooseApplication() }.controlSize(.small)
            }
            .padding(.leading, 56)
        case .url:
            TextField("https://…", text: text)
                .textFieldStyle(.roundedBorder).controlSize(.small).font(.caption)
                .padding(.leading, 56)
        case .shortcutName:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    TextField(action.kind == .toggleFocus ? "Shortcut that sets a Focus" : "Shortcut name", text: text)
                        .textFieldStyle(.roundedBorder).controlSize(.small).font(.caption)
                    if !shortcutNames.isEmpty {
                        Menu {
                            ForEach(shortcutNames, id: \.self) { name in
                                Button(name) { var a = action; a.text = name; update(a) }
                            }
                        } label: { Image(systemName: "list.bullet") }
                        .menuStyle(.button).controlSize(.small).fixedSize()
                    }
                }
                if action.kind == .toggleFocus {
                    Text("Make a Shortcut with the “Set Focus” action and name it here.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 56)
        }
    }

    private var text: Binding<String> {
        Binding(get: { action.text }, set: { var a = action; a.text = $0; update(a) })
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { var a = action; a.text = url.path; update(a) }
    }

    private func icon(for cat: ActionCategory) -> String {
        switch cat {
        case .screenshotsClipboard: return "camera"
        case .mediaVolume: return "music.note"
        case .inputDisplayFocus: return "sun.max"
        case .customShortcuts: return "keyboard"
        case .windowWorkspace: return "macwindow"
        case .lockSleep: return "lock"
        case .connectivity: return "wifi"
        case .systemUtilities: return "bolt"
        case .other: return "flashlight.on.fill"
        }
    }
}
