import SiliconPulseCore
import SwiftUI

struct HistoryView: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var window: HistoryWindow = .fiveMinutes

    var body: some View {
        let history = engine.history
        let total = Double(max(1, engine.system.memory.total))
        Page {
            HStack {
                Text("In-memory history only: nothing is written to disk. Older data is averaged into coarser buckets, so memory use stays constant.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                WindowPicker(selection: $window)
            }
            row("CPU", info: MetricCatalog.cpuTotal, series: [ChartSeries(points: history[.cpu].points(for: window), color: Theme.cpu, label: "CPU")],
                metric: .cpu, maxValue: 1, format: { Format.percent($0) })
            row("GPU", info: MetricCatalog.gpuDevice, series: [ChartSeries(points: history[.gpu].points(for: window), color: Theme.gpu, label: "GPU")],
                metric: .gpu, maxValue: 1, format: { Format.percent($0) },
                emptyMessage: engine.system.gpu.isAvailable ? nil : "GPU utilization is not reported on this Mac")
            row("Memory", info: MetricCatalog.memoryUsed,
                series: [ChartSeries(points: history[.memoryUsed].points(for: window), color: Theme.memory, label: "Used"),
                         ChartSeries(points: history[.memoryCompressed].points(for: window), color: Theme.caution, label: "Compressed", dashed: true),
                         ChartSeries(points: history[.swapUsed].points(for: window), color: Theme.critical, label: "Swap", dashed: true, fill: false)],
                metric: .memoryUsed, maxValue: total, format: { Format.bytes($0) })
            row("Disk", info: MetricCatalog.diskThroughput,
                series: [ChartSeries(points: history[.diskRead].points(for: window), color: Theme.disk, label: "Read"),
                         ChartSeries(points: history[.diskWrite].points(for: window), color: Theme.disk, label: "Write", dashed: true)],
                metric: .diskRead, maxValue: nil, format: { Format.rate($0) })
            row("Network", info: MetricCatalog.networkThroughput,
                series: [ChartSeries(points: history[.networkReceived].points(for: window), color: Theme.network, label: "Download"),
                         ChartSeries(points: history[.networkSent].points(for: window), color: Theme.network, label: "Upload", dashed: true)],
                metric: .networkReceived, maxValue: nil, format: { Format.rate($0) })
        }
    }

    private func row(_ title: String, info: MetricInfo, series: [ChartSeries], metric: HistoryMetric, maxValue: Double?,
                     format: @escaping (Double) -> String, emptyMessage: String? = nil) -> some View {
        let s = engine.history[metric]
        let summary = [s.average(in: window).map { "avg " + format($0) }, s.maximum(in: window).map { "peak " + format($0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return ChartCard(title: title, value: summary.isEmpty ? "—" : summary, info: info, series: series, window: window,
                         maxValue: maxValue, format: format, height: 120, emptyMessage: emptyMessage)
    }
}
