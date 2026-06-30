import SwiftUI
import WSCore

extension AppSample: Identifiable { public var id: Int32 { pid } }

struct CorrRow: Identifiable { let id: String; let score: Double }
struct SpikeRow: Identifiable { let id: Int; let when: String; let wsCPU: Double; let gpu: Double; let top: String }

final class DashboardModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var correlation: [CorrRow] = []
    @Published var spikes: [SpikeRow] = []
    var onPause: (Int32, String) -> Void = { _, _ in }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            suspects
            if !model.correlation.isEmpty {
                Divider(); correlationSection
            }
            if !model.spikes.isEmpty {
                Divider(); spikesSection
            }
            Spacer(minLength: 0)
            Text("Click Pause to freeze a suspect ~4s and watch if WindowServer drops — that proves the culprit.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
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
        }
    }

    private var suspects: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top suspects (HEAVY score)").font(.subheadline.bold())
            ForEach(model.snapshot?.apps.prefix(10).map { $0 } ?? []) { a in
                HStack {
                    Text(a.name).frame(width: 180, alignment: .leading).lineLimit(1)
                    Text("HEAVY \(Int(a.heavy))").frame(width: 100, alignment: .leading)
                        .foregroundStyle(.secondary).font(.callout)
                    Text(String(format: "%dw  %.0f%%  %dk px", a.windows, a.cpu, a.area / 1000))
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
