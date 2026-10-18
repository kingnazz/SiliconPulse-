import SiliconPulseCore
import SwiftUI

struct MemoryView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let m = engine.system.memory
        let window = settings.chartWindow
        Page {
            Panel {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: "Memory used")
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Format.fixed(Double(m.used) / 1_073_741_824, 1)).font(.metricValueLarge)
                            Text("/ \(Format.fixed(Double(m.total) / 1_073_741_824, 0)) GB").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Text("\(Format.percent(m.usedFraction)) of unified memory").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            SectionLabel(text: "Pressure")
                            QualityBadge(info: MetricCatalog.memoryPressure)
                        }
                        StatusPill(text: m.pressure.label, color: Theme.color(for: m.pressure))
                        if let level = m.kernelFreeLevel {
                            Text("Kernel free level \(level)%").font(.system(size: 11)).foregroundStyle(.secondary)
                                .help(MetricCatalog.memoryFreeLevel.tooltip)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            SectionLabel(text: "Headroom")
                            QualityBadge(info: MetricCatalog.memoryHeadroom)
                        }
                        Text("≈ " + Format.bytes(m.estimatedHeadroom)).font(.metricValue)
                        Text(headroomAdvice(m)).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(maxWidth: 300, alignment: .leading)
                    }
                    Spacer()
                }
                CompositionBar(segments: segments(m), total: Double(m.total))
                    .padding(.top, 6)
                HStack(spacing: 16) {
                    ForEach(segments(m)) { segment in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 8, height: 8)
                            Text(segment.label).foregroundStyle(.secondary)
                            Text(Format.bytes(UInt64(max(0, segment.value)))).font(.numericMedium)
                        }
                    }
                }
                .font(.system(size: 11.5))
            }

            HStack(alignment: .top, spacing: 12) {
                Panel("Breakdown") {
                    VStack(spacing: 0) {
                        StatRow(label: "Installed", value: Format.bytes(m.total), info: MetricCatalog.memoryInstalled)
                        StatRow(label: "Used", value: Format.bytes(m.used), info: MetricCatalog.memoryUsed)
                        StatRow(label: "Available", value: Format.bytes(m.available), info: MetricCatalog.memoryAvailable)
                        Divider().padding(.vertical, 4)
                        StatRow(label: "App memory", value: Format.bytes(m.app), info: MetricCatalog.memoryApp, swatch: Theme.memory)
                        StatRow(label: "Wired", value: Format.bytes(m.wired), info: MetricCatalog.memoryWired, swatch: Theme.gpu.opacity(0.8))
                        StatRow(label: "Compressed", value: Format.bytes(m.compressed), info: MetricCatalog.memoryCompressed, swatch: Theme.caution)
                        StatRow(label: "Cached files", value: Format.bytes(m.cachedFiles), info: MetricCatalog.memoryCached, swatch: Color.secondary.opacity(0.45))
                        StatRow(label: "Free", value: Format.bytes(m.free), info: MetricCatalog.memoryFree)
                    }
                }
                Panel("Swap & compression") {
                    VStack(spacing: 0) {
                        StatRow(label: "Swap used", value: "\(Format.bytes(m.swapUsed)) of \(Format.bytes(m.swapTotal))", info: MetricCatalog.swapUsed,
                                valueColor: m.swapUsed > 0 ? Theme.caution : .primary)
                        StatRow(label: "Swap-outs", value: pagesPerSecond(m.swapOutsPerSecond), info: MetricCatalog.swapActivity,
                                valueColor: m.isSwappingOut ? Theme.critical : .primary)
                        StatRow(label: "Swap-ins", value: pagesPerSecond(m.swapInsPerSecond), info: MetricCatalog.swapActivity)
                        StatRow(label: "Compressions", value: pagesPerSecond(m.compressionsPerSecond), info: MetricCatalog.compressionActivity)
                        StatRow(label: "Decompressions", value: pagesPerSecond(m.decompressionsPerSecond), info: MetricCatalog.compressionActivity)
                    }
                    Text(swapSummary(m)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                SectionLabel(text: "History")
                Spacer()
                WindowPicker(selection: $settings.chartWindow)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                ChartCard(title: "Used & compressed", value: Format.bytes(m.used), info: MetricCatalog.memoryUsed,
                          series: [ChartSeries(points: engine.history[.memoryUsed].points(for: window), color: Theme.memory, label: "Used"),
                                   ChartSeries(points: engine.history[.memoryCompressed].points(for: window), color: Theme.caution, label: "Compressed", dashed: true)],
                          window: window, maxValue: Double(max(1, m.total)), format: { Format.bytes($0) })
                ChartCard(title: "Swap used", value: Format.bytes(m.swapUsed), info: MetricCatalog.swapUsed,
                          series: [ChartSeries(points: engine.history[.swapUsed].points(for: window), color: Theme.critical.opacity(0.8), label: "Swap")],
                          window: window, maxValue: nil, format: { Format.bytes($0) })
            }

            Panel("Largest memory users") {
                ProcessMiniList(processes: ProcessTable.top(engine.processes, by: .memory, limit: 8), metric: .memory)
                LimitationNote(text: "Model weights a runner hands to the GPU are often wired memory, so they can appear under Wired rather than in the runner's own footprint.")
            }
        }
    }

    private func segments(_ m: MemorySnapshot) -> [CompositionBar.Segment] {
        [
            .init(label: "App", value: Double(m.app), color: Theme.memory),
            .init(label: "Wired", value: Double(m.wired), color: Theme.gpu.opacity(0.8)),
            .init(label: "Compressed", value: Double(m.compressed), color: Theme.caution),
            .init(label: "Cached", value: Double(m.cachedFiles), color: Color.secondary.opacity(0.45)),
        ]
    }

    private func pagesPerSecond(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value == 0 ? "0 /s" : Format.fixed(value, value < 10 ? 1 : 0) + " pages/s"
    }

    private func headroomAdvice(_ m: MemorySnapshot) -> String {
        switch m.pressure {
        case .critical: return "macOS is under critical pressure. Loading another model will swap."
        case .warning: return "macOS is compressing memory. A larger model will likely swap."
        default:
            if m.total == 0 { return "" }
            return "A model up to about this size should load without heavy compression."
        }
    }

    private func swapSummary(_ m: MemorySnapshot) -> String {
        if m.isSwappingOut { return "macOS is writing memory to disk right now. Expect slowdowns, especially for large models." }
        if m.swapUsed > 0 { return "Some memory was swapped earlier, but nothing is being swapped out right now." }
        return "No swap in use."
    }
}
