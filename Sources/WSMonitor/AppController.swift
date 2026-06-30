import AppKit
import WSCore

final class AppController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = Monitor()
    private let spikes = SpikeLog()
    private let correlator = Correlator()
    private var timer: Timer?
    private var latest: Snapshot?
    private let wsPID = windowServerPID()

    func start() {
        rebuildMenu(snapshot: nil)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let snap = monitor.tick()
        latest = snap
        correlator.record(snap)
        _ = spikes.observe(snap)
        let b = statusItem.button
        b?.title = formatTitle(wsCPU: snap.wsCPU, gpu: snap.gpu.utilization, top: snap.apps.first?.name)
        b?.contentTintColor = severityColor(snap)
        rebuildMenu(snapshot: snap)
    }

    private func severityColor(_ s: Snapshot) -> NSColor {
        let g = s.gpu.utilization ?? 0
        if s.wsCPU > 60 || g > 80 { return .systemRed }
        if s.wsCPU > 30 || g > 50 { return .systemYellow }
        return .systemGreen
    }

    // MARK: Menu

    private func rebuildMenu(snapshot: Snapshot?) {
        let menu = NSMenu()
        if let s = snapshot {
            menu.addItem(disabled(String(format: "WindowServer   CPU %.0f%%   RAM %.0f MB   GPU mem %.0f MB",
                                         s.wsCPU, s.wsRSS, s.gpu.memInUseMB ?? 0)))
            menu.addItem(.separator())
            menu.addItem(disabled("Top suspects (HEAVY)"))
            for a in s.apps.prefix(8) {
                let title = String(format: "%@   ·   HEAVY %d   ·   %dw  %.0f%% cpu  %dk px",
                                   a.name, Int(a.heavy), a.windows, a.cpu, a.area / 1000)
                let item = NSMenuItem(title: title, action: #selector(pauseSuspect(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: a.pid)
                menu.addItem(item)
            }
            let corr = correlator.ranking().prefix(3).filter { $0.score > 0.3 }
            if !corr.isEmpty {
                menu.addItem(.separator())
                menu.addItem(disabled("Most correlated with spikes"))
                for c in corr { menu.addItem(disabled(String(format: "%@   ·   r=%.2f", c.name, c.score))) }
            }
            if !spikes.events.isEmpty {
                menu.addItem(.separator())
                menu.addItem(disabled("Recent spikes"))
                for e in spikes.events.suffix(5).reversed() {
                    let when = DateFormatter.localizedString(from: e.ts, dateStyle: .none, timeStyle: .medium)
                    menu.addItem(disabled(String(format: "%@   WS %.0f%% · GPU %.0f%% — %@",
                                                 when, e.wsCPU, e.gpuUtil ?? 0, e.top.first?.name ?? "?")))
                }
            }
            menu.addItem(.separator())
            menu.addItem(disabled("Click a suspect to PAUSE it ~4s (proves cause), then it resumes"))
        } else {
            menu.addItem(disabled("Sampling…"))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WSMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func disabled(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: Quit-and-watch

    @objc private func pauseSuspect(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        let pid = num.int32Value
        let name = sender.title.components(separatedBy: "   ·").first ?? "process"
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

    /// Dedicated two-read WindowServer CPU measurement (doesn't disturb the periodic sampler).
    private func measureWSCPU() -> Double {
        guard let ws = wsPID else { return 0 }
        let s = CPUSampler()
        _ = s.sample(pids: [ws])
        Thread.sleep(forTimeInterval: 1.5)
        return s.sample(pids: [ws])[ws]?.cpu ?? 0
    }
}
