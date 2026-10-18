import SiliconPulseCore
import SwiftUI

struct MemoryView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let m = engine.system.memory
        let window = settings.chartWindow
        Page(spacing: 28) {
            PageHeader("Memory", subtitle: "Unified memory shared by the CPU, GPU and Neural Engine")
            MemorySummary(m: m)
            MemoryCompositionView(m: m)

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("History")
                HStack(alignment: .top, spacing: 28) {
                    ChartCard(title: "Used and compressed", value: Format.bytes(m.used), info: MetricCatalog.memoryUsed,
                              series: [ChartSeries(points: engine.history[.memoryUsed].points(for: window), color: Theme.memory, label: "Used"),
                                       ChartSeries(points: engine.history[.memoryCompressed].points(for: window), color: Theme.caution, label: "Compressed", dashed: true)],
                              window: window, maxValue: Double(max(1, m.total)), format: { Format.bytes($0) }, height: 110)
                        .frame(maxWidth: .infinity)
                    ChartCard(title: "Swap used", value: Format.bytes(m.swapUsed), info: MetricCatalog.swapUsed,
                              series: [ChartSeries(points: engine.history[.swapUsed].points(for: window),
                                                   color: m.swapUsed > 0 ? Theme.critical : Color.secondary, label: "Swap")],
                              window: window, maxValue: nil, format: { Format.bytes($0) }, height: 110)
                        .frame(maxWidth: 320)
                }
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Activity")
                    StatRow(label: "Swap-outs", value: pagesPerSecond(m.swapOutsPerSecond), info: MetricCatalog.swapActivity,
                            valueColor: m.isSwappingOut ? Theme.critical : .primary)
                    StatRow(label: "Swap-ins", value: pagesPerSecond(m.swapInsPerSecond), info: MetricCatalog.swapActivity)
                    StatRow(label: "Compressions", value: pagesPerSecond(m.compressionsPerSecond), info: MetricCatalog.compressionActivity)
                    StatRow(label: "Decompressions", value: pagesPerSecond(m.decompressionsPerSecond), info: MetricCatalog.compressionActivity)
                    if let level = m.kernelFreeLevel {
                        StatRow(label: "Kernel free level", value: "\(level)%", info: MetricCatalog.memoryFreeLevel)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Largest memory users")
                    ProcessMiniList(processes: ProcessTable.top(engine.processes, by: .memory, limit: 6), metric: .memory)
                }
                .frame(maxWidth: .infinity)
            }
            LimitationNote(text: "Model weights a runner hands to the GPU are often wired memory, so they can appear under Wired rather than in the runner's own footprint.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { WindowPicker(selection: $settings.chartWindow) }
        }
    }

    private func pagesPerSecond(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value == 0 ? "0 /s" : Format.fixed(value, value < 10 ? 1 : 0) + " pages/s"
    }
}

/// Used / total as the dominant number, with pressure, swap and headroom beside it.
private struct MemorySummary: View {
    var m: MemorySnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Used").font(.metaMedium).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.fixed(Double(m.used) / 1_073_741_824, 1)).font(.system(size: 44, weight: .semibold).monospacedDigit())
                    Text("/ \(Format.fixed(Double(m.total) / 1_073_741_824, 0)) GB").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                }
                Text("\(Format.percent(m.usedFraction)) of unified memory · \(Format.bytes(m.available)) available")
                    .font(.body13).foregroundStyle(.secondary)
            }
            .metricHelp(MetricCatalog.memoryUsed)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pressure").font(.metaMedium).foregroundStyle(.secondary)
                    StatusPill(text: m.pressure.label, color: Theme.color(for: m.pressure), prominent: m.pressure != .normal)
                        .font(.metricSmall)
                }
                .metricHelp(MetricCatalog.memoryPressure)
                MetricReadout(label: "Swap", value: Format.bytes(m.swapUsed),
                              caption: m.isSwappingOut ? "Swapping now" : (m.swapUsed > 0 ? "Not swapping now" : "None in use"),
                              info: MetricCatalog.swapUsed, valueFont: .metric, tint: m.swapUsed > 0 ? Theme.caution : .primary)
                    .fixedSize()
                MetricReadout(label: "Headroom", value: "≈ " + Format.bytes(m.estimatedHeadroom), caption: headroomCaption,
                              info: MetricCatalog.memoryHeadroom, valueFont: .metric)
                    .fixedSize()
            }
        }
    }

    private var headroomCaption: String {
        switch m.pressure {
        case .critical: return "Another model will swap"
        case .warning: return "A larger model will likely swap"
        default: return "Room for a model this size"
        }
    }
}

/// The composition bar with a column legend underneath: each segment's name, size and share.
private struct MemoryCompositionView: View {
    var m: MemorySnapshot

    var body: some View {
        let total = Double(max(1, m.total))
        let accounted = m.app + m.wired + m.compressed + m.cachedFiles
        let free = m.total > accounted ? m.total - accounted : 0
        let segments: [(String, UInt64, Color, MetricInfo, Bool)] = [
            ("App memory", m.app, Theme.memory, MetricCatalog.memoryApp, false),
            ("Wired", m.wired, Theme.memory.opacity(0.55), MetricCatalog.memoryWired, false),
            ("Compressed", m.compressed, m.pressure == .normal ? Theme.memory.opacity(0.3) : Theme.caution, MetricCatalog.memoryCompressed, m.pressure != .normal),
            ("Cached files", m.cachedFiles, Color.secondary.opacity(0.35), MetricCatalog.memoryCached, false),
            ("Free", free, Theme.track, MetricCatalog.memoryFree, false),
        ]
        VStack(alignment: .leading, spacing: 14) {
            CompositionBar(segments: segments.dropLast().map { .init(label: $0.0, value: Double($0.1), color: $0.2) },
                           total: total, height: 18)
            HStack(alignment: .top, spacing: 0) {
                ForEach(segments, id: \.0) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2.5).fill(segment.2).frame(width: 10, height: 10)
                            Text(segment.0).font(.metaMedium).foregroundStyle(segment.4 ? Theme.caution : .secondary)
                        }
                        Text(Format.bytes(segment.1)).font(.metricSmall)
                        Text(Format.percent(Double(segment.1) / total)).font(.meta).foregroundStyle(.tertiary)
                    }
                    .metricHelp(segment.3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
