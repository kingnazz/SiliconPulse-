import SiliconPulseCore
import SwiftUI

/// Detail for the selected process. Deeper data (arguments, sockets, files) is collected only for this process.
struct ProcessInspector: View {
    var identity: ProcessIdentity
    @Binding var selection: ProcessIdentity?
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let sample = engine.processesByPID[identity.pid].flatMap { $0.startTime == identity.startTime ? $0 : nil }
        ScrollView {
            if let sample {
                content(sample).padding(18)
            } else {
                EmptyStateView(symbol: "xmark.circle", title: "Process exited", message: "PID \(identity.pid) is no longer running.")
            }
        }
    }

    @ViewBuilder
    private func content(_ p: ProcessSample) -> some View {
        let inspected = engine.inspected?.identity == identity ? engine.inspected : nil
        let details = inspected?.details
        let tree = ProcessTree(engine.processes)
        let children = tree.children(of: p.pid).compactMap { engine.processesByPID[$0] }
        let workload = engine.ai.workloads.first { $0.processPIDs.contains(p.pid) }

        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                ProcessIcon(sample: p, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 17, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                    Text(subtitle(p)).font(.meta).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                }
            }

            if let workload {
                HStack(spacing: 8) {
                    RunnerGlyph(runner: workload.runner, size: 20)
                    Text("Part of \(workload.runner.displayName)" + (workload.primaryModel.map { " · \($0.displayName)" } ?? ""))
                        .font(.meta).lineLimit(1)
                    Spacer(minLength: 0)
                    ActivityLabel(activity: workload.activity, lastActivity: workload.lastActivity, state: workload.state)
                }
                .padding(10)
                .background(Theme.ai.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            }

            if !p.countersAvailable {
                LimitationNote(text: MetricCatalog.restricted.note ?? "", symbol: "lock")
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    inspectorMetric("CPU", p.cpuPercent.map { Format.processCPU($0) + "%" } ?? "—", MetricCatalog.processCPU,
                                    spark: inspected?.cpu.points(for: .fiveMinutes), color: Theme.cpu)
                    inspectorMetric("Memory", p.memoryFootprint.map { Format.bytes($0) } ?? "—", MetricCatalog.processMemory,
                                    spark: inspected?.memory.points(for: .fiveMinutes), color: Theme.memory)
                }
                GridRow {
                    inspectorMetric("Threads", p.threadCount.map(String.init) ?? "—", MetricCatalog.processThreads)
                    inspectorMetric("Disk", diskText(p), MetricCatalog.processDisk)
                }
                if let gpu = p.gpuTimeShare {
                    GridRow {
                        inspectorMetric("GPU time", Format.percent(min(gpu, 1), precise: true), MetricCatalog.gpuProcessTime,
                                        quality: .estimated)
                        inspectorMetric("Uptime", Format.duration(p.runtime(now: engine.system.timestamp)), nil)
                    }
                }
            }

            InspectorSection(title: "Process") {
                InspectorRow("PID", String(p.pid))
                InspectorRow("User", "\(p.userName) (\(p.uid))")
                InspectorRow("Architecture", p.architecture.label)
                InspectorRow("Started", Date(timeIntervalSince1970: p.startTime).formatted(date: .abbreviated, time: .shortened))
                if p.gpuTimeShare == nil { InspectorRow("Uptime", Format.duration(p.runtime(now: engine.system.timestamp))) }
                if let read = p.diskReadTotal, let written = p.diskWrittenTotal {
                    InspectorRow("Disk total", "\(Format.bytes(read)) read · \(Format.bytes(written)) written")
                }
                if let open = details?.openFileCount { InspectorRow("Open files", String(open)) }
            }

            InspectorSection(title: "Family") {
                if let parent = engine.processesByPID[p.parentPID], p.parentPID != p.pid {
                    ProcessLink(process: parent, selection: $selection, caption: "Parent")
                } else {
                    InspectorRow("Parent", p.parentPID == 0 ? "kernel" : "PID \(p.parentPID)")
                }
                ForEach(children.prefix(12)) { child in ProcessLink(process: child, selection: $selection, caption: "Child") }
                if children.count > 12 { Text("and \(children.count - 12) more").font(.meta).foregroundStyle(.secondary) }
            }

            if let details, !details.listening.isEmpty {
                InspectorSection(title: "Listening") {
                    ForEach(details.listening) { socket in
                        InspectorRow("TCP \(socket.port)", socket.isLoopbackOnly ? "This Mac only" : (socket.address == "*" ? "All interfaces" : socket.address))
                    }
                }
            }

            if let path = p.executablePath {
                InspectorSection(title: "Executable") {
                    Text(path).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let details, !details.arguments.isEmpty {
                InspectorSection(title: "Arguments") {
                    Text(details.arguments.joined(separator: " "))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let cwd = details?.workingDirectory {
                InspectorSection(title: "Working directory") {
                    Text(cwd).font(.system(size: 11).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func subtitle(_ p: ProcessSample) -> String {
        [p.bundleIdentifier, "PID \(p.pid)", p.userName].compactMap { $0 }.joined(separator: " · ")
    }

    private func diskText(_ p: ProcessSample) -> String {
        guard let read = p.diskReadBytesPerSecond, let write = p.diskWriteBytesPerSecond else { return "—" }
        return "\(Format.rate(read + write))"
    }

    private func inspectorMetric(_ label: String, _ value: String, _ info: MetricInfo?, quality: MetricQuality? = nil,
                                 spark: [HistoryPoint]? = nil, color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MetricReadout(label: label, value: value, info: info, quality: quality, valueFont: .metricSmall)
            if let spark {
                Sparkline(points: spark, color: color, maxValue: nil, fill: true).frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct InspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.metaMedium).foregroundStyle(.secondary).padding(.bottom, 2)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorRow: View {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
    }
}

private struct ProcessLink: View {
    var process: ProcessSample
    @Binding var selection: ProcessIdentity?
    var caption: String
    @State private var hovering = false

    var body: some View {
        Button {
            selection = process.id
        } label: {
            HStack(spacing: 7) {
                ProcessIcon(sample: process, size: 14)
                Text(process.name).lineLimit(1)
                Text(String(process.pid)).foregroundStyle(.tertiary).font(.numeric)
                Spacer()
                Text(caption).font(.meta).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(hovering ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
