import SwiftUI
import ImperumCore

extension AppSample: Identifiable { public var id: Int32 { pid } }

struct CorrRow: Identifiable { let id: String; let score: Double }
struct SpikeRow: Identifiable { let id: Int; let when: String; let wsCPU: Double; let gpu: Double; let top: String }
struct PowerRow: Identifiable { let id: Int32; let name: String; let energy: Double }  // Energy Impact
extension DisplayInfo: Identifiable { public var id: UInt32 { displayID } }

/// The app most statistically tied to WindowServer spikes, once enough data exists.
struct Culprit {
    let name: String
    let pid: Int32?      // nil if it currently owns no window (can't Pause-test)
    let score: Double
    var confidence: String {
        if score >= 0.8 { return "Strong" }
        if score >= 0.6 { return "Likely" }
        return "Possible"
    }
    var color: Color {
        if score >= 0.8 { return .red }
        if score >= 0.6 { return .orange }
        return .yellow
    }
}

final class DashboardModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var culprit: Culprit?
    @Published var correlation: [CorrRow] = []
    @Published var spikes: [SpikeRow] = []
    @Published var pmStatus: String = "Deep GPU capture: off"
    @Published var pmEnabled: Bool = false
    @Published var powerProcs: [PowerRow] = []  // live per-process Energy Impact (powermetrics)
    @Published var displays: [DisplayInfo] = []
    @Published var testStatus: String?          // live pause-and-test feedback
    @Published var testing = false              // a pause-test is in progress
    var onPause: (Int32, String) -> Void = { _, _ in }
    var onToggleHelper: () -> Void = {}
    var onOpenSettings: () -> Void = {}
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            // Pinned header — always visible while scrolling.
            VStack(alignment: .leading, spacing: 10) {
                header
                if let t = model.testStatus { testBanner(t) }
                if let c = model.culprit { culpritCard(c) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.displays.isEmpty { displaySection; Divider() }
                    suspects
                    if !model.correlation.isEmpty {
                        Divider(); correlationSection
                    }
                    if model.pmEnabled {
                        Divider(); gpuSection
                    }
                    if !model.spikes.isEmpty {
                        Divider(); spikesSection
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.pmStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Click Pause on a suspect to freeze it ~4s and watch if WindowServer drops — that proves the culprit.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.pmEnabled ? "Disable deep GPU capture" : "Enable deep GPU capture (powermetrics)") {
                    model.onToggleHelper()
                }.controlSize(.small)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private var header: some View {
        let s = model.snapshot
        let ws = s?.wsCPU ?? 0
        let gpu = s?.gpu.utilization
        let color: Color = (ws > 60 || (gpu ?? 0) > 80) ? .red : (ws > 30 || (gpu ?? 0) > 50) ? .yellow : .green
        return HStack(spacing: 16) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 28)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("WindowServer").font(.headline)
                Text(String(format: "CPU %.0f%%   ·   RAM %.0f MB", ws, s?.wsRSS ?? 0))
                    .foregroundStyle(.secondary)
                Text(String(format: "GPU %@   ·   GPU mem %.0f MB",
                            gpu.map { "\(Int($0))%" } ?? "—", s?.gpu.memInUseMB ?? 0))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.onOpenSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("Settings — launch at login, refresh interval, thresholds")
        }
    }

    private func testBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            if model.testing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
            }
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue.opacity(0.4), lineWidth: 1))
    }

    private func culpritCard(_ c: Culprit) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26)).foregroundStyle(c.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("LIKELY CULPRIT · \(c.confidence.uppercased()) CONFIDENCE")
                    .font(.caption.bold()).foregroundStyle(c.color)
                Text(c.name).font(.title2.bold())
                Text(String(format: "correlation with WindowServer spikes:  r = %.2f", c.score))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let pid = c.pid {
                Button { model.onPause(pid, c.name) } label: {
                    Text("Pause & test").bold()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(c.color)
            } else {
                Text("no window\nto test").font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(c.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.color.opacity(0.5), lineWidth: 1))
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display load (the fixed per-frame compositing cost)").font(.subheadline.bold())
            ForEach(model.displays) { d in
                HStack(spacing: 10) {
                    Text(d.isMain ? "Main" : "Ext.").frame(width: 40, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text("looks like \(d.pointW)×\(d.pointH)").frame(width: 170, alignment: .leading)
                    Text(d.refresh > 0 ? "@ \(Int(d.refresh)) Hz" : "@ — Hz")
                        .frame(width: 64, alignment: .leading)
                        .foregroundStyle(d.refresh > 60 ? .orange : .secondary)
                    Text(String(format: "renders %d×%d (%.1f MP)", d.pixelW, d.pixelH, d.megapixels))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f Gpx/s", d.pixelsPerSecond / 1e9))
                        .foregroundStyle(d.refresh > 60 ? .orange : .secondary)
                }.font(.callout)
            }
            Text("Gpx/s = rendered pixels × refresh — WindowServer recomposites this every second even when idle. Lower refresh (orange = >60 Hz) or a less-scaled resolution reduces it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var suspects: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top suspects (HEAVY score)").font(.subheadline.bold())
            ForEach(model.snapshot?.apps.prefix(10).map { $0 } ?? []) { a in
                HStack(spacing: 10) {
                    Text(a.name).frame(width: 160, alignment: .leading).lineLimit(1)
                    Text("HEAVY \(Int(a.heavy))").frame(width: 90, alignment: .leading)
                        .foregroundStyle(.secondary).font(.callout)
                    Text("\(a.windows) Open Window\(a.windows == 1 ? "" : "s")")
                        .frame(width: 130, alignment: .leading)
                        .foregroundStyle(.secondary).font(.callout)
                    Text(String(format: "%.0f%% CPU", a.cpu)).frame(width: 70, alignment: .leading)
                        .foregroundStyle(.secondary).font(.callout)
                    Text(String(format: "%.1fM px", Double(a.area) / 1_000_000))
                        .foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Button("Pause") { model.onPause(a.pid, a.name) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var correlationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Most correlated with spikes").font(.subheadline.bold())
            ForEach(model.correlation) { c in
                Text(String(format: "%@   ·   r = %.2f", c.id, c.score)).foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Power cost by process (powermetrics — Energy Impact)").font(.subheadline.bold())
            Text("Per-process GPU ms/s reads 0 on Apple Silicon, so this ranks Energy Impact — Apple's combined CPU+GPU+ANE power cost, the best authoritative per-process signal.")
                .font(.caption2).foregroundStyle(.secondary)
            if model.powerProcs.isEmpty {
                Text("sampling…").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.powerProcs) { g in
                    HStack {
                        Text(g.name).frame(width: 320, alignment: .leading).lineLimit(1)
                        Text(String(format: "%.0f energy", g.energy)).foregroundStyle(.secondary)
                        Spacer()
                    }.font(.callout)
                }
            }
        }
    }

    private var spikesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent spikes").font(.subheadline.bold())
            ForEach(model.spikes) { e in
                Text(String(format: "%@   WS %.0f%% · GPU %.0f%% — %@", e.when, e.wsCPU, e.gpu, e.top))
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
    }
}
