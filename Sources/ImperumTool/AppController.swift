import AppKit
import SwiftUI
import ImperumCore

final class AppController: NSObject, NSWindowDelegate, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = Monitor()
    private let spikes = SpikeLog()
    private let correlator = Correlator()
    private let model = DashboardModel()
    private let config = AppConfig()
    private let volumeBlockStore = VolumeBlockStore()
    private lazy var volumeAutoMountBlocker = VolumeAutoMountBlocker(store: volumeBlockStore)
    private let tapStore = TapSettingsStore()
    private lazy var tapGestures = TapGestureController(store: tapStore)
    private let clipboardSettings = ClipboardSettingsStore()
    private lazy var clipboard = ClipboardController(settings: clipboardSettings)
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var latest: Snapshot?
    private let wsPID = windowServerPID()
    private let sampleQueue = DispatchQueue(label: "io.imperum.tool.sample")

    func start() {
        model.onPause = { [weak self] pid, name in self?.pauseSuspect(pid: pid, name: name) }
        model.onToggleHelper = { [weak self] in self?.toggleHelper() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        config.onChange = { [weak self] in self?.applyConfig() }
        spikes.config = config.spikeConfig
        _ = volumeAutoMountBlocker   // force the DiskArbitration session to start now, not on first Settings open
        _ = tapGestures              // likewise: the motion sensor must run whether or not Settings is ever opened
        _ = clipboard                // pasteboard watcher + ⌘V tap must run whether or not Settings is ever opened
        buildMainMenu()
        statusItem.button?.action = #selector(toggleWindow)
        statusItem.button?.target = self
        makeWindow()
        tick()
        startTimer()
        showWindow()   // show on launch so there is always a visible UI
        snapshotSettingsIfRequested()
    }

    /// Dev hook: `ImperumTool --snapshot-settings <png> [tab]` renders the Settings
    /// window to a PNG (no Screen Recording permission needed) and quits.
    private func snapshotSettingsIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count else { return }
        let path = args[i + 1]
        if i + 2 < args.count, !args[i + 2].hasPrefix("--") { SettingsTabs.initialTab = args[i + 2] }
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            // Whole window incl. title bar + toolbar (own-process windows need no Screen Recording permission).
            if let win = self?.settingsWindow,
               let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.intervalSeconds, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Re-apply live settings (called when the user changes config in Settings).
    private func applyConfig() {
        spikes.config = config.spikeConfig
        startTimer()
    }

    // MARK: App menu + Settings

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Imperum Tool", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(withTitle: "Show Window", action: #selector(showWindowMenu), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Imperum Tool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in appMenu.items where item.target == nil { item.target = self }
        NSApp.mainMenu = mainMenu
    }

    @objc private func showWindowMenu() { showWindow() }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Imperum Tool",
            .applicationVersion: appVersionString(),
            .credits: NSAttributedString(
                string: "Finds which app drives WindowServer CPU / RAM / GPU spikes.\n\nSudoless detection · live correlation · pause-and-test causation · optional powermetrics Energy Impact.\n\nDeveloper ID: Imperum B.V.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        ])
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let tabs = SettingsTabs.makeController(config: config, blockStore: volumeBlockStore,
                                                   tapStore: tapStore, tapController: tapGestures,
                                                   clipboardStore: clipboardSettings,
                                                   onClearClipboard: { [weak self] in self?.clipboard.clearAll() })
            let win = NSWindow(contentViewController: tabs)
            win.styleMask = [.titled, .closable]
            win.toolbarStyle = .preference
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        if let id = SettingsTabs.requestedTab, let tabs = settingsWindow?.contentViewController as? NSTabViewController,
           let i = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == id }) {
            tabs.selectedTabViewItemIndex = i
        }
        SettingsTabs.requestedTab = nil
        // NSWindow(contentViewController:) keeps window.title synchronized (via KVO)
        // with the content view controller's `title` property. Switching the
        // NSTabViewController's selected tab (just above, for a requested tab jump)
        // clears its `title` back to empty, which clobbers whatever we set on window
        // creation — so (re-)apply it here, on every call, after any tab switch.
        settingsWindow?.title = "Imperum Tool Settings"
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.makeFirstResponder(nil)   // don't auto-focus the first text field
    }

    private func makeWindow() {
        let host = NSHostingController(rootView: DashboardView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "Imperum Tool — WindowServer load"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 600, height: 560))
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        window = win
    }

    @objc private func toggleWindow() {
        if let w = window, w.isVisible { w.orderOut(nil) } else { showWindow() }
    }

    // Clicking the Dock icon (with no open window) reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboard.willTerminate()
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func tick() {
        // Heavy work (ps subprocess, IOKit, sudo capability check) off the main
        // thread so the window stays responsive.
        sampleQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.monitor.tick()
            let displays = sampleDisplays()
            let enabled = PowerMetricsClient.shared.isEnabled
            DispatchQueue.main.async {
                self.model.displays = displays
                self.apply(snap: snap, enabled: enabled)
            }
        }
    }

    private func apply(snap: Snapshot, enabled: Bool) {
        latest = snap
        correlator.record(snap)
        _ = spikes.observe(snap)
        model.pmEnabled = enabled
        model.pmStatus = enabled
            ? "Deep GPU capture: ON (live per-process Energy Impact via powermetrics)"
            : "Deep GPU capture: off"
        if enabled { capturePower() }

        // Menu-bar item: compact so it fits a crowded / notched menu bar.
        // Normal state: a TEMPLATE image + plain title, so macOS draws both in
        // the menu bar's own contrast colour (white on dark, black on light).
        // Spike state: contentTintColor is unreliable on status-bar buttons
        // (it renders near-black on macOS 26), so pre-render the symbol in red
        // via a palette symbol configuration and colour the title to match.
        let b = statusItem.button
        let symbol = "gauge.with.dots.needle.bottom.50percent"
        let spiking = snap.wsCPU > config.cpuThreshold || (snap.gpu.utilization ?? 0) > config.gpuThreshold
        let title = String(format: " %.0f", snap.wsCPU)
        b?.imagePosition = .imageLeading
        b?.contentTintColor = nil
        if spiking, let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "WindowServer load (spiking)"),
           let red = base.withSymbolConfiguration(.init(paletteColors: [.systemRed])) {
            red.isTemplate = false
            b?.image = red
            b?.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.systemRed, .font: NSFont.menuBarFont(ofSize: 0)])
        } else {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "WindowServer load")
            img?.isTemplate = true
            b?.image = img
            b?.title = title
        }

        // Window model.
        model.snapshot = snap
        let ranked = correlator.ranking()
        model.correlation = ranked.prefix(3).filter { $0.score > 0.3 }
            .map { CorrRow(id: $0.name, score: $0.score) }
        // Promote the top correlated app to a prominent culprit once we have
        // enough samples (~30s) and a meaningful link.
        if correlator.count >= 6, let top = ranked.first, top.score > 0.5 {
            let pid = snap.apps.first { $0.name == top.name }?.pid
            model.culprit = Culprit(name: top.name, pid: pid, score: top.score)
        } else {
            model.culprit = nil
        }
        model.spikes = spikes.events.suffix(6).reversed().enumerated().map { idx, e in
            SpikeRow(id: idx,
                     when: DateFormatter.localizedString(from: e.ts, dateStyle: .none, timeStyle: .medium),
                     wsCPU: e.wsCPU, gpu: e.gpuUtil ?? 0, top: e.top.first?.name ?? "?")
        }
    }

    private func severityColor(_ s: Snapshot) -> NSColor {
        let g = s.gpu.utilization ?? 0
        if s.wsCPU > 60 || g > 80 { return .systemRed }
        if s.wsCPU > 30 || g > 50 { return .systemYellow }
        return .systemGreen
    }

    // MARK: Quit-and-watch

    private func pauseSuspect(pid: Int32, name: String) {
        guard !model.testing else { return }   // one test at a time
        let before = latest?.wsCPU ?? 0
        NSLog("Imperum Tool pause-test: \(name) pid \(pid), WS before \(before)%")
        // Immediate, visible feedback so the click is never a no-op.
        model.testing = true
        model.testStatus = String(format: "Pausing %@ for ~2s, watching WindowServer (was %.0f%%)…", name, before)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let froze = pause(pid: pid)
            let after = self.measureWSCPU()
            resume(pid: pid)
            let r = watchDrop(before: before, after: after)
            NSLog("Imperum Tool pause-test result: \(name) froze=\(froze) WS \(before)→\(after) drop \(r.drop)")
            DispatchQueue.main.async {
                self.model.testing = false
                if !froze {
                    self.model.testStatus = "Couldn't pause \(name) — pid \(pid) may have quit. Try another suspect."
                } else {
                    let verdict = r.drop > 15 ? "big drop — \(name) is very likely your culprit."
                                : r.drop > 6  ? "moderate drop — \(name) contributes."
                                              : "no real drop — \(name) is probably not the cause."
                    self.model.testStatus = String(format: "%@ frozen: WindowServer %.0f%% → %.0f%% (−%.0f). %@",
                                                    name, r.before, r.after, max(0, r.drop), verdict)
                }
                self.clearTestStatusLater()
            }
        }
    }

    private var clearWork: DispatchWorkItem?
    private func clearTestStatusLater() {
        clearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.model.testStatus = nil }
        clearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: w)
    }

    private func measureWSCPU() -> Double {
        guard let ws = wsPID else { return 0 }
        let s = CPUSampler()
        _ = s.sample(pids: [ws])      // prime baseline
        Thread.sleep(forTimeInterval: 2.0)
        return s.sample(pids: [ws])[ws]?.cpu ?? 0
    }

    // MARK: Privileged powermetrics helper

    private func refreshHelperStatus() {
        switch PowerMetricsClient.shared.state {
        case .enabled:
            model.pmEnabled = true
            model.pmStatus = "Deep GPU capture: ON (live per-process GPU via powermetrics)"
        case .notEnabled:
            model.pmEnabled = false
            model.pmStatus = "Deep GPU capture: off"
        case .error(let m):
            model.pmEnabled = false
            model.pmStatus = "Deep GPU capture error: \(m)"
        }
    }

    private func toggleHelper() {
        let c = PowerMetricsClient.shared
        let result = c.isEnabled ? c.uninstall() : c.install()
        if case .failure(let err) = result {
            let a = NSAlert()
            a.messageText = "Couldn't change deep GPU capture"
            a.informativeText = err.localizedDescription
            a.runModal()
        }
        refreshHelperStatus()
    }

    private func capturePower() {
        PowerMetricsClient.shared.capture { [weak self] procs in
            let rows = procs.compactMap { p -> PowerRow? in
                guard let e = p.energyImpact, e > 0 else { return nil }
                return PowerRow(id: p.pid, name: p.name, energy: e)
            }.sorted { $0.energy > $1.energy }.prefix(8)
            self?.model.powerProcs = Array(rows)
        }
    }
}
