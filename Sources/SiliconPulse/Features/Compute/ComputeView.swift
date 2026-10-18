import SiliconPulseCore
import SwiftUI

struct ComputeView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let window = settings.chartWindow
        Page(spacing: 32) {
            PageHeader("Compute", subtitle: subtitle)
            CPUSection(window: window)
            GPUSection(window: window)
            ComputeFootnotes()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) { WindowPicker(selection: $settings.chartWindow) }
        }
    }

    private var subtitle: String {
        let t = engine.system.cpu.topology
        var parts = [t.brand]
        if let p = t.performanceCores, let e = t.efficiencyCores {
            parts.append("\(p) performance + \(e) efficiency cores")
        } else if t.logicalCores > 0 {
            parts.append("\(t.logicalCores) cores")
        }
        if let gpuCores = engine.system.gpu.coreCount { parts.append("\(gpuCores)-core GPU") }
        return parts.joined(separator: " · ")
    }
}

private struct CPUSection: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let cpu = engine.system.cpu
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 32) {
                MetricReadout(label: "CPU", value: Format.fixed(cpu.usage.total * 100, 0), unit: "%",
                              caption: "User \(Format.percent(cpu.usage.user, precise: true)) · System \(Format.percent(cpu.usage.system, precise: true)) · Load \(cpu.loadAverage.map { Format.fixed($0, 2) }.joined(separator: " "))",
                              info: MetricCatalog.cpuTotal, valueFont: .heroMetric,
                              tint: Theme.load(cpu.usage.total, base: .primary))
                    .fixedSize()
                if let p = cpu.clusterUsage(.performance) {
                    MetricReadout(label: "Performance cores", value: Format.percent(p), valueFont: .metric).fixedSize()
                }
                if let e = cpu.clusterUsage(.efficiency) {
                    MetricReadout(label: "Efficiency cores", value: Format.percent(e), valueFont: .metric).fixedSize()
                }
                Spacer(minLength: 0)
            }
            LineChart(series: [ChartSeries(points: engine.history[.cpu].points(for: window), color: Theme.cpu, label: "CPU")],
                      window: window, maxValue: 1, format: { Format.percent($0) }, height: 130)
            CoreGrid(cores: cpu.cores)
        }
    }
}

/// Per-core bars, grouped by cluster when the layout is known.
private struct CoreGrid: View {
    var cores: [CoreUsage]

    var body: some View {
        let kinds = Set(cores.map(\.kind))
        let grouped = !kinds.contains(.unknown) && kinds.count > 1
        let groups: [(String, [CoreUsage])] = grouped
            ? [("Performance", cores.filter { $0.kind == .performance }), ("Efficiency", cores.filter { $0.kind == .efficiency })]
            : [("Cores", cores)]
        HStack(alignment: .top, spacing: 28) {
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(group.0) · \(group.1.count)").font(.metaMedium).foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(group.1) { core in
                            CoreBar(core: core)
                        }
                    }
                }
            }
            if cores.isEmpty {
                Text("Measuring…").font(.meta).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CoreBar: View {
    var core: CoreUsage

    var body: some View {
        let fraction = core.usage.total
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Theme.track)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Theme.load(fraction, base: core.kind == .efficiency ? Theme.cpu.opacity(0.6) : Theme.cpu))
                .frame(height: max(2, 44 * CGFloat(fraction)))
        }
        .frame(width: 14, height: 44)
        .help("CPU \(core.id)\(core.kind == .unknown ? "" : " (\(core.kind.rawValue))"): \(Format.percent(fraction))")
    }
}

private struct GPUSection: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let gpu = engine.system.gpu
        let busy = engine.processes.filter { ($0.gpuTimeShare ?? 0) > 0.001 }.sorted { ($0.gpuTimeShare ?? 0) > ($1.gpuTimeShare ?? 0) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 32) {
                MetricReadout(label: "GPU", value: gpu.deviceUtilization.map { Format.fixed($0 * 100, 0) } ?? "—",
                              unit: gpu.isAvailable ? "%" : nil, caption: gpu.isAvailable ? "Whole Mac" : "Not reported by this Mac's GPU driver",
                              info: MetricCatalog.gpuDevice, quality: gpu.isAvailable ? nil : .unavailable, valueFont: .heroMetric,
                              tint: Theme.load(gpu.deviceUtilization ?? 0, base: .primary))
                    .fixedSize()
                if let r = gpu.rendererUtilization {
                    MetricReadout(label: "Renderer", value: Format.percent(r), info: MetricCatalog.gpuRenderer, valueFont: .metric).fixedSize()
                }
                if let t = gpu.tilerUtilization {
                    MetricReadout(label: "Tiler", value: Format.percent(t), info: MetricCatalog.gpuTiler, valueFont: .metric).fixedSize()
                }
                if let m = gpu.memoryInUse {
                    MetricReadout(label: "GPU memory in use", value: Format.bytes(m), info: MetricCatalog.gpuMemory, valueFont: .metric).fixedSize()
                }
                Spacer(minLength: 0)
            }
            if gpu.isAvailable || !engine.history[.gpu].points(for: window).isEmpty {
                LineChart(series: [ChartSeries(points: engine.history[.gpu].points(for: window), color: Theme.gpu, label: "GPU")],
                          window: window, maxValue: 1, format: { Format.percent($0) }, height: 130)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("GPU time by process").font(.label)
                    QualityBadge(info: MetricCatalog.gpuProcessTime)
                }
                .metricHelp(MetricCatalog.gpuProcessTime)
                if engine.perProcessGPUSupported == false {
                    Text("This Mac does not expose per-process GPU accounting, so only the system figure is shown.")
                        .font(.meta).foregroundStyle(.secondary)
                } else if busy.isEmpty {
                    Text("No process submitted GPU work in the last interval.").font(.meta).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(busy.prefix(6)) { p in
                            HStack(spacing: 10) {
                                ProcessIcon(sample: p, size: 16)
                                Text(p.name).font(.system(size: 12)).lineLimit(1).frame(width: 220, alignment: .leading)
                                UsageBar(fraction: min(1, p.gpuTimeShare ?? 0), color: Theme.gpu)
                                Text(Format.percent(min(1, p.gpuTimeShare ?? 0), precise: true)).font(.numericMedium)
                                    .frame(width: 52, alignment: .trailing)
                            }
                            .padding(.vertical, 5)
                            .hairlineBelow()
                        }
                    }
                    Text("Share of time each process had GPU work running. Shares overlap and are not a split of the system figure.")
                        .font(.meta).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

/// What macOS does not expose, and thermal/power, as quiet lines rather than empty cards.
private struct ComputeFootnotes: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let thermal = engine.system.thermal
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.color(for: thermal.level)).frame(width: 7, height: 7)
                Text("Thermal state \(thermal.level.label.lowercased())").font(.label)
                Text(thermalExplanation(thermal.level)).font(.meta).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(thermal.power.summary).font(.meta).foregroundStyle(.secondary)
            }
            .metricHelp(MetricCatalog.thermalState)
            LimitationNote(text: "Neural Engine utilization and component temperatures are not exposed by macOS through public interfaces, so SiliconPulse does not show them.")
                .help((MetricCatalog.ane.note ?? "") + "\n" + (MetricCatalog.temperatures.note ?? ""))
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1).offset(y: -14) }
    }

    private func thermalExplanation(_ level: ThermalLevel) -> String {
        switch level {
        case .normal: return "Performance is not being limited."
        case .elevated: return "macOS may reduce performance under sustained load."
        case .serious: return "macOS is reducing performance; inference will slow."
        case .critical: return "Performance is heavily limited."
        case .unknown: return "Not reported yet."
        }
    }
}
