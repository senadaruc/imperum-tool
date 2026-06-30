import AppKit
import SwiftUI
import WSCore

final class AppController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = Monitor()
    private let spikes = SpikeLog()
    private let correlator = Correlator()
    private let model = DashboardModel()
    private var window: NSWindow?
    private var timer: Timer?
    private var latest: Snapshot?
    private let wsPID = windowServerPID()

    func start() {
        model.onPause = { [weak self] pid, name in self?.pauseSuspect(pid: pid, name: name) }
        model.onToggleHelper = { [weak self] in self?.toggleHelper() }
        statusItem.button?.action = #selector(toggleWindow)
        statusItem.button?.target = self
        makeWindow()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        showWindow()   // show on launch so there is always a visible UI
    }

    private func makeWindow() {
        let host = NSHostingController(rootView: DashboardView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "WSMonitor — WindowServer load"
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

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func tick() {
        let snap = monitor.tick()
        latest = snap
        correlator.record(snap)
        _ = spikes.observe(snap)
        refreshHelperStatus()
        if model.pmEnabled { capturePower() }

        // Menu-bar item: compact so it fits a crowded / notched menu bar.
        let b = statusItem.button
        b?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                           accessibilityDescription: "WindowServer load")
        b?.imagePosition = .imageLeading
        b?.title = String(format: " %.0f", snap.wsCPU)
        b?.contentTintColor = severityColor(snap)

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
        let before = latest?.wsCPU ?? 0
        pause(pid: pid)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let after = self?.measureWSCPU() ?? before
            resume(pid: pid)
            let r = watchDrop(before: before, after: after)
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Quit-and-watch: \(name)"
                a.informativeText = String(format:
                    "WindowServer CPU %.0f%% → %.0f%% while %@ was paused (drop %.0f%%).\n\n%@",
                    r.before, r.after, name, r.drop,
                    r.drop > 15 ? "Large drop — this app is very likely your culprit."
                               : "Small drop — probably not the main cause.")
                a.runModal()
            }
        }
    }

    private func measureWSCPU() -> Double {
        guard let ws = wsPID else { return 0 }
        let s = CPUSampler()
        _ = s.sample(pids: [ws])
        Thread.sleep(forTimeInterval: 1.5)
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
