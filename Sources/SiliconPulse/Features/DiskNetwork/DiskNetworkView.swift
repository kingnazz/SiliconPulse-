import SiliconPulseCore
import SwiftUI

struct DiskNetworkView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Page(spacing: 34) {
            PageHeader("Disk & Network", subtitle: "System throughput, with per-process disk activity for your own processes")
            DiskSection(window: settings.chartWindow)
            NetworkSection(window: settings.chartWindow)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { WindowPicker(selection: $settings.chartWindow) }
        }
    }
}

private struct DiskSection: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    private static func total(_ p: ProcessSample) -> Double {
        (p.diskReadBytesPerSecond ?? 0) + (p.diskWriteBytesPerSecond ?? 0)
    }

    var body: some View {
        let disk = engine.system.disk
        let history = engine.history
        let top: [ProcessSample] = Array(engine.processes.filter { Self.total($0) > 0 }
            .sorted { Self.total($0) > Self.total($1) }
            .prefix(6))
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 40) {
                MetricReadout(label: "Disk read", value: Format.rate(disk.readBytesPerSecond),
                              caption: "\(Format.bytes(disk.totalRead)) since boot", info: MetricCatalog.diskThroughput,
                              valueFont: .metricLarge, tint: Theme.disk)
                    .fixedSize()
                MetricReadout(label: "Disk write", value: Format.rate(disk.writeBytesPerSecond),
                              caption: "\(Format.bytes(disk.totalWritten)) since boot", info: MetricCatalog.diskThroughput,
                              valueFont: .metricLarge)
                    .fixedSize()
                Spacer(minLength: 0)
                ChartLegend(series: diskSeries(history))
            }
            LineChart(series: diskSeries(history), window: window, maxValue: nil, format: { Format.rate($0) }, height: 110)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Busiest processes").font(.label)
                    Spacer()
                    Text("Read").frame(width: 90, alignment: .trailing)
                    Text("Write").frame(width: 90, alignment: .trailing)
                }
                .font(.metaMedium)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
                if top.isEmpty {
                    Text("None of your processes read or wrote in the last interval.").font(.meta).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(top) { p in DiskRow(process: p) }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func diskSeries(_ history: MetricHistory) -> [ChartSeries] {
        [ChartSeries(points: history[.diskRead].points(for: window), color: Theme.disk, label: "Read"),
         ChartSeries(points: history[.diskWrite].points(for: window), color: Theme.disk, label: "Write", dashed: true)]
    }
}

private struct DiskRow: View {
    var process: ProcessSample

    var body: some View {
        HStack(spacing: 8) {
            ProcessIcon(sample: process, size: 16)
            Text(process.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text(Format.rate(process.diskReadBytesPerSecond ?? 0)).font(.numeric).frame(width: 90, alignment: .trailing)
            Text(Format.rate(process.diskWriteBytesPerSecond ?? 0)).font(.numeric).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .hairlineBelow()
    }
}

private struct NetworkSection: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let network = engine.system.network
        let history = engine.history
        let series = [ChartSeries(points: history[.networkReceived].points(for: window), color: Theme.network, label: "Download"),
                      ChartSeries(points: history[.networkSent].points(for: window), color: Theme.network, label: "Upload", dashed: true)]
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 40) {
                MetricReadout(label: "Download", value: Format.rate(network.receivedBytesPerSecond), info: MetricCatalog.networkThroughput,
                              valueFont: .metricLarge, tint: Theme.network)
                    .fixedSize()
                MetricReadout(label: "Upload", value: Format.rate(network.sentBytesPerSecond), info: MetricCatalog.networkThroughput,
                              valueFont: .metricLarge)
                    .fixedSize()
                Spacer(minLength: 0)
                ChartLegend(series: series)
            }
            LineChart(series: series, window: window, maxValue: nil, format: { Format.rate($0) }, height: 110)
            if !network.interfaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Interfaces").font(.label).foregroundStyle(.primary)
                        Spacer()
                        Text("Down").frame(width: 90, alignment: .trailing)
                        Text("Up").frame(width: 90, alignment: .trailing)
                        Text("Since boot").frame(width: 170, alignment: .trailing)
                    }
                    .font(.metaMedium)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    ForEach(network.interfaces) { interface in
                        HStack {
                            Text(interface.name).font(.system(size: 12).monospaced())
                            Spacer()
                            Text(Format.rate(interface.receivedBytesPerSecond)).font(.numeric).frame(width: 90, alignment: .trailing)
                            Text(Format.rate(interface.sentBytesPerSecond)).font(.numeric).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                            Text("\(Format.bytes(interface.totalReceived)) in · \(Format.bytes(interface.totalSent)) out")
                                .font(.meta).foregroundStyle(.secondary).frame(width: 170, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        .hairlineBelow()
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
            LimitationNote(text: (MetricCatalog.processNetwork.note ?? "") + " SiliconPulse therefore does not list per-process network usage.")
        }
    }
}
