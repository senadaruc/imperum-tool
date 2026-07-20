import AppKit
import SwiftUI
import WSCore

final class AppController: NSObject, NSWindowDelegate, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = Monitor()
    private let spikes = SpikeLog()
    private let correlator = Correlator()
    private let model = DashboardModel()
    private let config = AppConfig()
    private let volumeBlockStore = VolumeBlockStore()
    private lazy var volumeAutoMountBlocker = VolumeAutoMountBlocker(store: volumeBlockStore)
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var latest: Snapshot?
    private let wsPID = windowServerPID()
    private let sampleQueue = DispatchQueue(label: "io.imperum.wsmonitor.sample")

    func start() {
        model.onPause = { [weak self] pid, name in self?.pauseSuspect(pid: pid, name: name) }
        model.onToggleHelper = { [weak self] in self?.toggleHelper() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        config.onChange = { [weak self] in self?.applyConfig() }
        spikes.config = config.spikeConfig
        _ = volumeAutoMountBlocker   // force the DiskArbitration session to start now, not on first Settings open
        buildMainMenu()
        statusItem.button?.action = #selector(toggleWindow)
        statusItem.button?.target = self
        makeWindow()
        tick()
        startTimer()
        showWindow()   // show on launch so there is always a visible UI
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

    @objc private func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(config: config, blockStore: volumeBlockStore))
            let win = NSWindow(contentViewController: host)
            win.title = "Imperum Tool Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        // Render as a TEMPLATE so macOS draws it with correct contrast (crisp
        // white on a dark menu bar) — always clearly visible. Tint RED only
        // during an actual spike, so colour means "problem now", not constant dim.
        let b = statusItem.button
        let img = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                          accessibilityDescription: "WindowServer load")
        let spiking = snap.wsCPU > config.cpuThreshold || (snap.gpu.utilization ?? 0) > config.gpuThreshold
        img?.isTemplate = !spiking          // template = auto-contrast; non-template lets red show
        b?.image = img
        b?.imagePosition = .imageLeading
        b?.title = String(format: " %.0f", snap.wsCPU)
        b?.contentTintColor = spiking ? .systemRed : nil

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
        NSLog("WSMonitor pause-test: \(name) pid \(pid), WS before \(before)%")
        // Immediate, visible feedback so the click is never a no-op.
        model.testing = true
        model.testStatus = String(format: "Pausing %@ for ~2s, watching WindowServer (was %.0f%%)…", name, before)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let froze = pause(pid: pid)
            let after = self.measureWSCPU()
            resume(pid: pid)
            let r = watchDrop(before: before, after: after)
            NSLog("WSMonitor pause-test result: \(name) froze=\(froze) WS \(before)→\(after) drop \(r.drop)")
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
