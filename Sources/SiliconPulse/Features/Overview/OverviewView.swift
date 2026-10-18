import SiliconPulseCore
import SwiftUI

/// The showcase: who this Mac is and whether it is fine, the three numbers that matter,
/// the active model when there is one, then everything else at a smaller scale.
struct OverviewView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Page(spacing: 26) {
            OverviewHeader()
            VStack(alignment: .leading, spacing: 12) {
                PrimaryMetrics(window: settings.chartWindow)
                SystemStatusLine()
            }
            LocalAISection()
            SecondaryRow(window: settings.chartWindow)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) { WindowPicker(selection: $settings.chartWindow) }
        }
    }
}

// MARK: - Header

/// Machine identity and a single health state.
struct OverviewHeader: View {
    @Environment(MonitorEngine.self) private var engine
    private let identity = MachineIdentity.current

    var body: some View {
        let health = MachineHealth.evaluate(engine.system)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(identity.computerName).font(.pageTitle).lineLimit(1)
                Text(machineLine).font(.body13).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 16)
            if engine.hasSystemSample {
                VStack(alignment: .trailing, spacing: 3) {
                    StatusPill(text: health.title, color: health.color, prominent: health.level != .healthy)
                    if let detail = health.detail {
                        Text(detail).font(.meta).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var machineLine: String {
        var parts: [String] = []
        if let model = identity.modelName { parts.append(model) }
        let brand = engine.system.cpu.topology.brand
        if brand != CPUTopology.unknown.brand, !(identity.modelName ?? "").contains(brand) { parts.append(brand) }
        if engine.system.memory.total > 0 { parts.append(Format.bytes(engine.system.memory.total, decimals: 0)) }
        parts.append(identity.osVersion)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Primary metrics

/// CPU, GPU and unified memory as one instrument: three columns, each with its value and its history.
struct PrimaryMetrics: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let s = engine.system
        let history = engine.history
        let ready = engine.hasSystemSample
        HStack(alignment: .top, spacing: 0) {
            column {
                MetricReadout(label: "CPU", value: ready ? Format.fixed(s.cpu.usage.total * 100, 0) : "—", unit: "%",
                              caption: s.stale.contains(.cpu) ? "Last value · sampling failed"
                                  : "User \(Format.percent(s.cpu.usage.user)) · System \(Format.percent(s.cpu.usage.system))",
                              info: MetricCatalog.cpuTotal, valueFont: .heroMetric, tint: Theme.load(s.cpu.usage.total, base: .primary))
                LineChart(series: [ChartSeries(points: history[.cpu].points(for: window), color: Theme.cpu, label: "CPU")],
                          window: window, maxValue: 1, format: { Format.percent($0) }, height: 78, showsScale: false)
            }
            divider
            column {
                MetricReadout(label: "GPU", value: s.gpu.deviceUtilization.map { Format.fixed($0 * 100, 0) } ?? "—",
                              unit: s.gpu.isAvailable ? "%" : nil, caption: gpuCaption(s.gpu),
                              info: MetricCatalog.gpuDevice, quality: s.gpu.isAvailable ? nil : .unavailable,
                              valueFont: .heroMetric, tint: Theme.load(s.gpu.deviceUtilization ?? 0, base: .primary))
                if s.gpu.isAvailable || !history[.gpu].points(for: window).isEmpty {
                    LineChart(series: [ChartSeries(points: history[.gpu].points(for: window), color: Theme.gpu, label: "GPU")],
                              window: window, maxValue: 1, format: { Format.percent($0) }, height: 78, showsScale: false)
                } else {
                    UnavailablePlot(height: 78)
                }
            }
            divider
            column {
                MetricReadout(label: "Unified memory",
                              value: ready ? Format.fixed(Double(s.memory.used) / 1_073_741_824, 1) : "—",
                              unit: "/ " + Format.fixed(Double(s.memory.total) / 1_073_741_824, 0) + " GB",
                              caption: s.stale.contains(.memory) ? "Last value · sampling failed"
                                  : "\(Format.percent(s.memory.usedFraction)) used · \(Format.bytes(s.memory.available)) available",
                              info: MetricCatalog.memoryUsed, valueFont: .heroMetric)
                VStack(spacing: 10) {
                    CompositionBar(segments: MemoryComposition.segments(s.memory), total: Double(max(1, s.memory.total)), height: 8)
                    LineChart(series: [ChartSeries(points: history[.memoryUsed].points(for: window), color: Theme.memory, label: "Used")],
                              window: window, maxValue: Double(max(1, s.memory.total)), format: { Format.bytes($0) },
                              height: 60, showsScale: false)
                }
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 4)
        .surface(.raised, padding: nil)
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 2)
    }

    private func gpuCaption(_ gpu: GPUSnapshot) -> String {
        guard gpu.isAvailable else { return "Not reported by this Mac's GPU driver" }
        if let memory = gpu.memoryInUse { return "Whole Mac · \(Format.bytes(memory)) in use" }
        return "Whole Mac"
    }
}

/// Placeholder plot area with a short reason, same height as a chart so columns stay aligned.
/// An empty plot for a metric this Mac does not report: just the baseline, so the row stays aligned.
struct UnavailablePlot: View {
    var height: CGFloat

    var body: some View {
        Rectangle().fill(Theme.grid).frame(height: 1)
            .frame(height: height, alignment: .bottom)
            .accessibilityHidden(true)
    }
}

enum MemoryComposition {
    static func segments(_ m: MemorySnapshot) -> [CompositionBar.Segment] {
        [
            .init(label: "App memory", value: Double(m.app), color: Theme.memory),
            .init(label: "Wired", value: Double(m.wired), color: Theme.memory.opacity(0.55)),
            .init(label: "Compressed", value: Double(m.compressed), color: m.pressure == .normal ? Theme.memory.opacity(0.3) : Theme.caution),
        ]
    }
}

/// Pressure, thermal and swap in one quiet line; promoted to a banner only when something is wrong.
struct SystemStatusLine: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let s = engine.system
        let health = MachineHealth.evaluate(s)
        if health.level != .healthy, engine.hasSystemSample {
            HStack(spacing: 10) {
                Image(systemName: health.level == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(health.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(health.title).font(.label)
                    Text(details(s)).font(.meta).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Memory") { engine.section = .memory }.buttonStyle(.link).font(.meta)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(health.color.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        } else {
            HStack(spacing: 14) {
                item("Memory pressure", s.memory.pressure.label, dot: Theme.color(for: s.memory.pressure))
                item("Thermal", s.thermal.level.label, dot: Theme.color(for: s.thermal.level))
                item("Swap", Format.bytes(s.memory.swapUsed))
                item("Compressed", Format.bytes(s.memory.compressed))
                Text(s.thermal.power.summary).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .font(.meta)
            .padding(.horizontal, 4)
            .lineLimit(1)
        }
    }

    private func item(_ label: String, _ value: String, dot: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot.opacity(0.85)).frame(width: 6, height: 6) }
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary).monospacedDigit()
        }
    }

    private func details(_ s: SystemSnapshot) -> String {
        var parts = ["Pressure \(s.memory.pressure.label.lowercased())", "\(Format.bytes(s.memory.compressed)) compressed",
                     "swap \(Format.bytes(s.memory.swapUsed))"]
        if s.thermal.level != .normal { parts.append("thermal \(s.thermal.level.label.lowercased())") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Local AI

/// The active model, prominent; other runtimes listed compactly; a single quiet line when there is none.
struct LocalAISection: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let ai = engine.ai
        if let featured = ai.featured {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    PulseDot(color: Theme.ai, isLive: featured.activity.isBusy, size: 6)
                    Overline(text: featured.activity.isBusy ? "Local AI · Live" : "Local AI", color: featured.activity.isBusy ? Theme.ai : .secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ActiveModelHero(workload: featured) { engine.section = .ai }
                    let others = ai.workloads.filter { $0.id != featured.id }
                    if !others.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(others) { workload in OtherWorkloadRow(workload: workload) }
                        }
                        .padding(.top, 2)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                }
                .padding(20)
                .surface(.emphasized, padding: nil)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.tertiary)
                Text(ai.timestamp == .distantPast ? "Looking for local AI runtimes…" : "No local AI runtime detected")
                    .font(.label)
                Text("Watching Ollama, LM Studio, llama.cpp, MLX and OpenAI-compatible servers on this Mac.")
                    .font(.meta).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }
}

struct OtherWorkloadRow: View {
    var workload: AIWorkload
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        HStack(spacing: 10) {
            RunnerGlyph(runner: workload.runner, size: 20)
            Text(workload.title).font(.label).lineLimit(1).truncationMode(.middle)
            Text(workload.runner.displayName).font(.meta).foregroundStyle(.secondary)
            Spacer()
            if let tps = workload.tokensPerSecond.value, workload.activity.isBusy {
                Text(Format.tokensPerSecond(tps)).font(.numericMedium)
            } else if let size = workload.primaryModel?.sizeBytes {
                Text(Format.bytes(size)).font(.numeric).foregroundStyle(.secondary)
            }
            ActivityLabel(activity: workload.activity, lastActivity: workload.lastActivity, state: workload.state)
                .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { engine.section = .ai }
    }
}

// MARK: - Secondary row

/// Disk, network and top consumers at a deliberately smaller scale than compute.
struct SecondaryRow: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let s = engine.system
        let history = engine.history
        let processes = engine.processes
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Disk & network")
                IOStrip(label: "Disk", primary: "Read \(Format.rate(s.disk.readBytesPerSecond))",
                        secondary: "Write \(Format.rate(s.disk.writeBytesPerSecond))",
                        series: [ChartSeries(points: history[.diskRead].points(for: window), color: Theme.disk, label: "Read"),
                                 ChartSeries(points: history[.diskWrite].points(for: window), color: Theme.disk, label: "Write", dashed: true)],
                        window: window, info: MetricCatalog.diskThroughput)
                IOStrip(label: "Network", primary: "↓ \(Format.rate(s.network.receivedBytesPerSecond))",
                        secondary: "↑ \(Format.rate(s.network.sentBytesPerSecond))",
                        series: [ChartSeries(points: history[.networkReceived].points(for: window), color: Theme.network, label: "Down"),
                                 ChartSeries(points: history[.networkSent].points(for: window), color: Theme.network, label: "Up", dashed: true)],
                        window: window, info: MetricCatalog.networkThroughput)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Top CPU")
                ProcessMiniList(processes: ProcessTable.top(processes, by: .cpu, limit: 5), metric: .cpu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Top memory")
                ProcessMiniList(processes: ProcessTable.top(processes, by: .memory, limit: 5), metric: .memory)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }
}

/// One line of throughput figures over a short chart.
struct IOStrip: View {
    var label: String
    var primary: String
    var secondary: String
    var series: [ChartSeries]
    var window: HistoryWindow
    var info: MetricInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).font(.metaMedium).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text(primary).font(.numericMedium)
                Text(secondary).font(.numeric).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .metricHelp(info)
            LineChart(series: series, window: window, maxValue: nil, format: { Format.rate($0) }, height: 34,
                      showsScale: false, showsMarker: false)
        }
    }
}

struct ProcessMiniList: View {
    enum Metric { case cpu, memory }
    var processes: [ProcessSample]
    var metric: Metric
    @Environment(MonitorEngine.self) private var engine
    @State private var hovered: Int32?

    var body: some View {
        VStack(spacing: 0) {
            if processes.isEmpty {
                Text("Waiting for process data…").font(.meta).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(processes) { process in
                HStack(spacing: 8) {
                    ProcessIcon(sample: process)
                    Text(process.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(valueText(process)).font(.numericMedium).foregroundStyle(valueColor(process))
                        .frame(width: 70, alignment: .trailing)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(hovered == process.pid ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? process.pid : (hovered == process.pid ? nil : hovered) }
                .onTapGesture {
                    engine.section = .processes
                    engine.inspect(process.id)
                }
                .help("Open in Processes")
            }
        }
        .padding(.horizontal, -6)
    }

    private func valueText(_ p: ProcessSample) -> String {
        switch metric {
        case .cpu: return p.cpuPercent.map { Format.processCPU($0) + "%" } ?? "—"
        case .memory: return p.memoryFootprint.map { Format.bytes($0) } ?? "—"
        }
    }

    private func valueColor(_ p: ProcessSample) -> Color {
        switch metric {
        case .cpu: return (p.cpuPercent ?? 0) >= ProcessFilter.highCPUThreshold ? Theme.caution : .primary
        case .memory: return .primary
        }
    }
}

struct ProcessIcon: View {
    var sample: ProcessSample
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = IconCache.shared.icon(for: sample) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "gearshape").resizable().foregroundStyle(.tertiary).padding(2)
            }
        }
        .frame(width: size, height: size)
    }
}
