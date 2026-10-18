import SiliconPulseCore
import SwiftUI

struct OverviewView: View {
    var body: some View {
        Page {
            TopMetricsStrip()
            OverviewCharts()
            LocalAISection()
            TopProcessesSection()
        }
    }
}

/// The five headline numbers.
struct TopMetricsStrip: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let s = engine.system
        let ready = engine.hasSystemSample
        HStack(spacing: 0) {
            MetricTile(label: "CPU", value: ready ? Format.fixed(s.cpu.usage.total * 100, 0) : "—", unit: "%",
                       detail: "User \(Format.percent(s.cpu.usage.user)) · System \(Format.percent(s.cpu.usage.system))",
                       info: MetricCatalog.cpuTotal, tint: Theme.load(s.cpu.usage.total, base: .primary))
                .padding(.horizontal, 16).stripDivider()

            MetricTile(label: "GPU", value: s.gpu.deviceUtilization.map { Format.fixed($0 * 100, 0) } ?? "—",
                       unit: s.gpu.isAvailable ? "%" : nil, detail: gpuDetail(s.gpu),
                       info: MetricCatalog.gpuDevice, quality: s.gpu.isAvailable ? nil : .unavailable)
                .padding(.horizontal, 16).stripDivider()

            MetricTile(label: "Memory", value: ready ? Format.fixed(Double(s.memory.used) / 1_073_741_824, 1) : "—",
                       unit: "/ " + Format.fixed(Double(s.memory.total) / 1_073_741_824, 0) + " GB",
                       detail: "\(Format.bytes(s.memory.available)) available",
                       info: MetricCatalog.memoryUsed)
                .padding(.horizontal, 16).stripDivider()

            MetricTile(label: "Pressure", value: s.memory.pressure.label, detail: pressureDetail(s.memory),
                       info: MetricCatalog.memoryPressure, tint: s.memory.pressure == .normal ? .primary : Theme.color(for: s.memory.pressure),
                       indicator: Theme.color(for: s.memory.pressure))
                .padding(.horizontal, 16).stripDivider()

            MetricTile(label: "Thermal", value: s.thermal.level.label, detail: s.thermal.power.summary,
                       info: MetricCatalog.thermalState, tint: s.thermal.level.isConstrained ? Theme.color(for: s.thermal.level) : .primary,
                       indicator: Theme.color(for: s.thermal.level))
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
        .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).strokeBorder(Theme.separator))
    }

    private func gpuDetail(_ gpu: GPUSnapshot) -> String {
        guard gpu.isAvailable else { return "Not reported" }
        if let memory = gpu.memoryInUse { return "\(Format.bytes(memory)) in use" }
        return gpu.coreCount.map { "\($0)-core GPU" } ?? gpu.name
    }

    private func pressureDetail(_ memory: MemorySnapshot) -> String {
        if memory.isSwappingOut { return "Swapping now · \(Format.bytes(memory.swapUsed)) swap" }
        if memory.swapUsed > 0 { return "Swap \(Format.bytes(memory.swapUsed)) · comp. \(Format.bytes(memory.compressed))" }
        return "Compressed \(Format.bytes(memory.compressed)) · no swap"
    }
}

/// Live charts for the five core metrics.
struct OverviewCharts: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let history = engine.history
        let window = settings.chartWindow
        let s = engine.system
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Activity")
                Spacer()
                WindowPicker(selection: $settings.chartWindow)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ChartCard(title: "CPU", value: Format.percent(s.cpu.usage.total), info: MetricCatalog.cpuTotal,
                          series: [ChartSeries(points: history[.cpu].points(for: window), color: Theme.cpu, label: "CPU")],
                          window: window, maxValue: 1, format: { Format.percent($0) })
                ChartCard(title: "GPU", value: s.gpu.deviceUtilization.map { Format.percent($0) } ?? "—", info: MetricCatalog.gpuDevice,
                          series: [ChartSeries(points: history[.gpu].points(for: window), color: Theme.gpu, label: "GPU")],
                          window: window, maxValue: 1, format: { Format.percent($0) },
                          emptyMessage: s.gpu.isAvailable ? nil : "GPU utilization is not reported on this Mac")
                ChartCard(title: "Memory", value: Format.bytes(s.memory.used), info: MetricCatalog.memoryUsed,
                          series: [ChartSeries(points: history[.memoryUsed].points(for: window), color: Theme.memory, label: "Used"),
                                   ChartSeries(points: history[.memoryCompressed].points(for: window), color: Theme.caution, label: "Compressed", dashed: true)],
                          window: window, maxValue: Double(max(1, s.memory.total)), format: { Format.bytes($0) })
                ChartCard(title: "Disk", value: "R \(Format.rate(s.disk.readBytesPerSecond))  W \(Format.rate(s.disk.writeBytesPerSecond))",
                          info: MetricCatalog.diskThroughput,
                          series: [ChartSeries(points: history[.diskRead].points(for: window), color: Theme.disk, label: "Read"),
                                   ChartSeries(points: history[.diskWrite].points(for: window), color: Theme.disk, label: "Write", dashed: true)],
                          window: window, maxValue: nil, format: { Format.rate($0) })
                ChartCard(title: "Network", value: "↓ \(Format.rate(s.network.receivedBytesPerSecond))  ↑ \(Format.rate(s.network.sentBytesPerSecond))",
                          info: MetricCatalog.networkThroughput,
                          series: [ChartSeries(points: history[.networkReceived].points(for: window), color: Theme.network, label: "Download"),
                                   ChartSeries(points: history[.networkSent].points(for: window), color: Theme.network, label: "Upload", dashed: true)],
                          window: window, maxValue: nil, format: { Format.rate($0) })
            }
        }
    }
}

/// The local AI workload, surfaced prominently when one is detected.
struct LocalAISection: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let ai = engine.ai
        Panel("Local AI", accessory: AnyView(
            Button("Details") { engine.section = .ai }
                .buttonStyle(.link)
                .font(.system(size: 11))
        )) {
            if let featured = ai.featured {
                AIWorkloadSummary(workload: featured, compact: true)
                let others = ai.workloads.filter { $0.id != featured.id }
                if !others.isEmpty {
                    Divider()
                    ForEach(others) { workload in
                        HStack(spacing: 8) {
                            Text(workload.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(workload.runner.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            ActivityLabel(activity: workload.activity, lastActivity: workload.lastActivity)
                            StatusPill(text: workload.state.label, color: Theme.color(for: workload.state))
                        }
                    }
                }
            } else if ai.timestamp == .distantPast {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for local AI runtimes…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                EmptyStateView(symbol: "sparkles", title: "No local AI runtime detected",
                               message: "SiliconPulse watches for Ollama, LM Studio, llama.cpp, MLX, Python inference scripts and OpenAI-compatible servers on this Mac.")
            }
        }
    }
}

/// Top consumers among processes SiliconPulse can measure.
struct TopProcessesSection: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let processes = engine.processes
        let restricted = processes.filter { !$0.countersAvailable }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Panel("Top CPU") {
                    ProcessMiniList(processes: ProcessTable.top(processes, by: .cpu, limit: 6), metric: .cpu)
                }
                Panel("Top memory") {
                    ProcessMiniList(processes: ProcessTable.top(processes, by: .memory, limit: 6), metric: .memory)
                }
            }
            if restricted > 0 {
                LimitationNote(text: "\(restricted) processes owned by other users (system daemons) are not listed here: macOS only lets an app read per-process counters for its own user. System totals above include them.")
                    .help(MetricCatalog.restricted.tooltip)
            }
        }
    }
}

struct ProcessMiniList: View {
    enum Metric { case cpu, memory }
    var processes: [ProcessSample]
    var metric: Metric
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        VStack(spacing: 6) {
            if processes.isEmpty {
                Text("Waiting for process data…").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(processes) { process in
                HStack(spacing: 8) {
                    ProcessIcon(sample: process)
                    Text(process.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(valueText(process)).font(.numericMedium).frame(width: 74, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    engine.section = .processes
                    engine.inspect(process.id)
                }
            }
        }
    }

    private func valueText(_ p: ProcessSample) -> String {
        switch metric {
        case .cpu: return p.cpuPercent.map { Format.processCPU($0) + "%" } ?? "—"
        case .memory: return p.memoryFootprint.map { Format.bytes($0) } ?? "—"
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
