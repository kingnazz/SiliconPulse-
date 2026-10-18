import SiliconPulseCore
import SwiftUI

struct DiskNetworkView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let s = engine.system
        let window = settings.chartWindow
        let history = engine.history
        let diskTop = engine.processes
            .filter { ($0.diskReadBytesPerSecond ?? 0) + ($0.diskWriteBytesPerSecond ?? 0) > 0 }
            .sorted { ($0.diskReadBytesPerSecond ?? 0) + ($0.diskWriteBytesPerSecond ?? 0) > ($1.diskReadBytesPerSecond ?? 0) + ($1.diskWriteBytesPerSecond ?? 0) }
        Page {
            HStack {
                Spacer()
                WindowPicker(selection: $settings.chartWindow)
            }
            Panel("Disk") {
                HStack(spacing: 0) {
                    MetricTile(label: "Read", value: Format.rate(s.disk.readBytesPerSecond), detail: "\(Format.bytes(s.disk.totalRead)) since boot",
                               info: MetricCatalog.diskThroughput)
                        .padding(.trailing, 16).stripDivider()
                    MetricTile(label: "Write", value: Format.rate(s.disk.writeBytesPerSecond), detail: "\(Format.bytes(s.disk.totalWritten)) since boot",
                               info: MetricCatalog.diskThroughput)
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
                if diskTop.isEmpty {
                    Text("None of your processes read or wrote in the last interval.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    ForEach(diskTop.prefix(6)) { p in
                        HStack(spacing: 8) {
                            ProcessIcon(sample: p, size: 14)
                            Text(p.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text("↓ " + Format.rate(p.diskReadBytesPerSecond ?? 0)).font(.numeric).frame(width: 90, alignment: .trailing)
                            Text("↑ " + Format.rate(p.diskWriteBytesPerSecond ?? 0)).font(.numeric).frame(width: 90, alignment: .trailing)
                        }
                    }
                }
                LimitationNote(text: "Per-process disk counters cover your own processes; system daemons are included in the totals above.")
            }

            Panel("Network") {
                HStack(spacing: 0) {
                    MetricTile(label: "Download", value: Format.rate(s.network.receivedBytesPerSecond), info: MetricCatalog.networkThroughput)
                        .padding(.trailing, 16).stripDivider()
                    MetricTile(label: "Upload", value: Format.rate(s.network.sentBytesPerSecond), info: MetricCatalog.networkThroughput)
                        .padding(.horizontal, 16)
                }
                LineChart(series: [ChartSeries(points: history[.networkReceived].points(for: window), color: Theme.network, label: "Download"),
                                   ChartSeries(points: history[.networkSent].points(for: window), color: Theme.network, label: "Upload", dashed: true)],
                          window: window, maxValue: nil, format: { Format.rate($0) }, height: 110)
                if !s.network.interfaces.isEmpty {
                    Divider()
                    SectionLabel(text: "Interfaces")
                    ForEach(s.network.interfaces) { interface in
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
                LimitationNote(text: (MetricCatalog.processNetwork.note ?? "") + " SiliconPulse therefore does not list per-process network usage.")
            }
        }
    }
}
