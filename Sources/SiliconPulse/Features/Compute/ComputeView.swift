import SiliconPulseCore
import SwiftUI

struct ComputeView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let window = settings.chartWindow
        Page {
            HStack {
                Spacer()
                WindowPicker(selection: $settings.chartWindow)
            }
            CPUPanel(window: window)
            GPUPanel(window: window)
            HStack(alignment: .top, spacing: 12) {
                NeuralEnginePanel()
                ThermalPanel()
            }
        }
    }
}

private struct CPUPanel: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let cpu = engine.system.cpu
        let topology = cpu.topology
        Panel("CPU · \(topology.brand)") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Format.fixed(cpu.usage.total * 100, 0)).font(.metricValueLarge)
                        Text("%").font(.metricUnit).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        StatRow(label: "User", value: Format.percent(cpu.usage.user, precise: true), info: MetricCatalog.cpuUser, swatch: Theme.cpu)
                        StatRow(label: "System", value: Format.percent(cpu.usage.system, precise: true), info: MetricCatalog.cpuSystem, swatch: Theme.cpu.opacity(0.5))
                        StatRow(label: "Idle", value: Format.percent(cpu.usage.idle), info: MetricCatalog.cpuIdle)
                        StatRow(label: "Load average", value: cpu.loadAverage.map { Format.fixed($0, 2) }.joined(separator: "  "), info: MetricCatalog.loadAverage)
                        StatRow(label: "Cores", value: coreSummary(topology), info: MetricCatalog.coreTopology)
                        if let p = cpu.clusterUsage(.performance) {
                            StatRow(label: "Performance cores", value: Format.percent(p))
                        }
                        if let e = cpu.clusterUsage(.efficiency) {
                            StatRow(label: "Efficiency cores", value: Format.percent(e))
                        }
                    }
                }
                .frame(width: 280)
                VStack(alignment: .leading, spacing: 10) {
                    LineChart(series: [ChartSeries(points: engine.history[.cpu].points(for: window), color: Theme.cpu, label: "CPU")],
                              window: window, maxValue: 1, format: { Format.percent($0) }, height: 110)
                    CoreGrid(cores: cpu.cores)
                }
            }
        }
    }

    private func coreSummary(_ t: CPUTopology) -> String {
        var text = "\(t.logicalCores)"
        if let p = t.performanceCores, let e = t.efficiencyCores { text += " (\(p)P + \(e)E)" }
        return text
    }
}

/// Per-core bars, grouped by cluster when the layout is known.
private struct CoreGrid: View {
    var cores: [CoreUsage]

    var body: some View {
        let groups: [(String, [CoreUsage])] = {
            let kinds = Set(cores.map(\.kind))
            if kinds.contains(.unknown) || kinds.count <= 1 { return [("Cores", cores)] }
            return [("Efficiency", cores.filter { $0.kind == .efficiency }), ("Performance", cores.filter { $0.kind == .performance })]
        }()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.0).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(group.1) { core in
                            VStack(spacing: 2) {
                                GeometryReader { geometry in
                                    VStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        Rectangle().fill(Theme.load(core.usage.total, base: Theme.cpu))
                                            .frame(height: geometry.size.height * CGFloat(core.usage.total))
                                    }
                                }
                                .frame(height: 30)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                Text("\(core.id)").font(.system(size: 8).monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: 22)
                            .help("CPU \(core.id)\(core.kind == .unknown ? "" : " (\(core.kind.shortLabel)-core)"): \(Format.percent(core.usage.total))")
                        }
                    }
                }
            }
            if cores.isEmpty {
                Text("Measuring…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GPUPanel: View {
    var window: HistoryWindow
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let gpu = engine.system.gpu
        let busy = engine.processes.filter { ($0.gpuTimeShare ?? 0) > 0.001 }.sorted { ($0.gpuTimeShare ?? 0) > ($1.gpuTimeShare ?? 0) }
        Panel("GPU · \(gpu.name)" + (gpu.coreCount.map { " · \($0) cores" } ?? "")) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(gpu.deviceUtilization.map { Format.fixed($0 * 100, 0) } ?? "—").font(.metricValueLarge)
                        if gpu.isAvailable { Text("%").font(.metricUnit).foregroundStyle(.secondary) }
                        ScopeTag(scope: .system).padding(.leading, 6)
                    }
                    VStack(spacing: 0) {
                        StatRow(label: "Device utilization", value: gpu.deviceUtilization.map { Format.percent($0) } ?? "—", info: MetricCatalog.gpuDevice)
                        if let r = gpu.rendererUtilization { StatRow(label: "Renderer", value: Format.percent(r), info: MetricCatalog.gpuRenderer) }
                        if let t = gpu.tilerUtilization { StatRow(label: "Tiler", value: Format.percent(t), info: MetricCatalog.gpuTiler) }
                        if let m = gpu.memoryInUse { StatRow(label: "GPU memory in use", value: Format.bytes(m), info: MetricCatalog.gpuMemory) }
                    }
                    if !gpu.isAvailable {
                        LimitationNote(text: "This Mac's GPU driver does not report utilization through IOKit (common in virtual machines).")
                    }
                }
                .frame(width: 280)
                VStack(alignment: .leading, spacing: 10) {
                    LineChart(series: [ChartSeries(points: engine.history[.gpu].points(for: window), color: Theme.gpu, label: "GPU")],
                              window: window, maxValue: 1, format: { Format.percent($0) }, height: 110)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            SectionLabel(text: "Process GPU activity")
                            ScopeTag(scope: .process)
                            QualityBadge(info: MetricCatalog.gpuProcessTime)
                        }
                        if engine.perProcessGPUSupported == false {
                            LimitationNote(text: "This Mac does not expose per-process GPU accounting, so SiliconPulse shows system GPU only.")
                        } else if busy.isEmpty {
                            Text("No process submitted GPU work in the last interval.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        } else {
                            ForEach(busy.prefix(6)) { p in
                                HStack(spacing: 8) {
                                    ProcessIcon(sample: p, size: 14)
                                    Text(p.name).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    UsageBar(fraction: min(1, p.gpuTimeShare ?? 0), color: Theme.gpu.opacity(0.8)).frame(width: 90)
                                    Text(Format.percent(min(1, p.gpuTimeShare ?? 0), precise: true)).font(.numericMedium).frame(width: 46, alignment: .trailing)
                                }
                            }
                            Text("GPU time share: how much of the interval each process had GPU work executing. Shares overlap and are not a split of the system figure.")
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct NeuralEnginePanel: View {
    var body: some View {
        Panel("Neural Engine") {
            HStack(spacing: 6) {
                Text("Not exposed").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                QualityBadge(info: MetricCatalog.ane)
            }
            LimitationNote(text: "macOS has no public API for Neural Engine utilization. powermetrics shows ANE power only, and needs root. SiliconPulse does not use private APIs, so it shows no number here rather than a questionable one.")
        }
    }
}

private struct ThermalPanel: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let thermal = engine.system.thermal
        Panel("Thermal & power") {
            HStack(spacing: 8) {
                StatusPill(text: thermal.level.label, color: Theme.color(for: thermal.level))
                QualityBadge(info: MetricCatalog.thermalState)
            }
            Text(thermalExplanation(thermal.level)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                StatRow(label: "Power", value: thermal.power.summary, info: MetricCatalog.powerSource)
                StatRow(label: "Temperatures", value: "Not exposed", info: MetricCatalog.temperatures)
            }
        }
    }

    private func thermalExplanation(_ level: ThermalLevel) -> String {
        switch level {
        case .normal: return "No thermal pressure. Performance is not being limited."
        case .elevated: return "Thermal pressure is elevated. macOS may start reducing performance under sustained load."
        case .serious: return "Thermal pressure is serious. macOS is reducing performance; inference will slow down."
        case .critical: return "Critical thermal pressure. Performance is heavily limited."
        case .unknown: return "Thermal state not reported yet."
        }
    }
}
