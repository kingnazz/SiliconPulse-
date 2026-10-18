import SiliconPulseCore
import SwiftUI

struct DiskNetworkView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Page {
            HStack {
                Spacer()
                WindowPicker(selection: $settings.chartWindow)
            }
            DiskPanel(window: settings.chartWindow)
            NetworkPanel(window: settings.chartWindow)
        }
    }
}

private struct DiskPanel: View {
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
        Panel("Disk") {
            HStack(spacing: 0) {
                MetricTile(label: "Read", value: Format.rate(disk.readBytesPerSecond),
                           detail: "\(Format.bytes(disk.totalRead)) since boot", info: MetricCatalog.diskThroughput)
                    .padding(.trailing, 16).stripDivider()
                MetricTile(label: "Write", value: Format.rate(disk.writeBytesPerSecond),
                           detail: "\(Format.bytes(disk.totalWritten)) since boot", info: MetricCatalog.diskThroughput)
                    .padding(.horizontal, 16)
            }
            LineChart(series: [ChartSeries(points: history[.diskRead].points(for: window), color: Theme.disk, label: "Read"),
                               ChartSeries(points: history[.diskWrite].points(for: window), color: Theme.disk, label: "Write", dashed: true)],
                      window: window, maxValue: nil, format: { Format.rate($0) }, height: 110)
            Divider()
            HStack(spacing: 4) {
                SectionLabel(text: "Top disk activity")
                ScopeTag(scope: .process)
                QualityBadge(info: MetricCatalog.processDisk)
            }
            if top.isEmpty {
                Text("None of your processes read or wrote in the last interval.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                ForEach(top) { p in DiskRow(process: p) }
            }
            LimitationNote(text: "Per-process disk counters cover your own processes; system daemons are included in the totals above.")
        }
    }
}

private struct DiskRow: View {
    var process: ProcessSample

    var body: some View {
        HStack(spacing: 8) {
            ProcessIcon(sample: process, size: 14)
            Text(process.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text("↓ " + Format.rate(process.diskReadBytesPerSecond ?? 0)).font(.numeric).frame(width: 90, alignment: .trailing)
            Text("↑ " + Format.rate(process.diskWriteBytesPerSecond ?? 0)).font(.numeric).frame(width: 90, alignment: .trailing)
        }
    }
}

private struct NetworkPanel: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let network = engine.system.network
        let history = engine.history
        Panel("Network") {
            HStack(spacing: 0) {
                MetricTile(label: "Download", value: Format.rate(network.receivedBytesPerSecond), info: MetricCatalog.networkThroughput)
                    .padding(.trailing, 16).stripDivider()
                MetricTile(label: "Upload", value: Format.rate(network.sentBytesPerSecond), info: MetricCatalog.networkThroughput)
                    .padding(.horizontal, 16)
            }
            LineChart(series: [ChartSeries(points: history[.networkReceived].points(for: window), color: Theme.network, label: "Download"),
                               ChartSeries(points: history[.networkSent].points(for: window), color: Theme.network, label: "Upload", dashed: true)],
                      window: window, maxValue: nil, format: { Format.rate($0) }, height: 110)
            if !network.interfaces.isEmpty {
                Divider()
                SectionLabel(text: "Interfaces")
                ForEach(network.interfaces) { interface in InterfaceRow(interface: interface) }
            }
            LimitationNote(text: (MetricCatalog.processNetwork.note ?? "") + " SiliconPulse therefore does not list per-process network usage.")
        }
    }
}

private struct InterfaceRow: View {
    var interface: InterfaceThroughput

    var body: some View {
        HStack {
            Text(interface.name).font(.system(size: 12).monospaced()).frame(width: 70, alignment: .leading)
            Text("↓ " + Format.rate(interface.receivedBytesPerSecond)).font(.numeric).frame(width: 100, alignment: .leading)
            Text("↑ " + Format.rate(interface.sentBytesPerSecond)).font(.numeric).frame(width: 100, alignment: .leading)
            Spacer()
            Text("\(Format.bytes(interface.totalReceived)) in · \(Format.bytes(interface.totalSent)) out")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
