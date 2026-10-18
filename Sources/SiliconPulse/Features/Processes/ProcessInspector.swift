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
                content(sample)
                    .padding(16)
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

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProcessIcon(sample: p, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                    Text(p.bundleIdentifier ?? "PID \(p.pid)").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            if let workload {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.ai)
                    Text("Part of \(workload.runner.displayName)" + (workload.primaryModel.map { " · \($0.displayName)" } ?? ""))
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
            }

            if !p.countersAvailable {
                LimitationNote(text: MetricCatalog.restricted.note ?? "", symbol: "lock")
            }

            VStack(spacing: 0) {
                StatRow(label: "CPU", value: p.cpuPercent.map { Format.processCPU($0) + "%" } ?? "—", info: MetricCatalog.processCPU)
                StatRow(label: "Memory", value: p.memoryFootprint.map { Format.bytes($0) } ?? "—", info: MetricCatalog.processMemory)
                StatRow(label: "Threads", value: p.threadCount.map(String.init) ?? "—", info: MetricCatalog.processThreads)
                StatRow(label: "Disk read", value: p.diskReadBytesPerSecond.map(Format.rate) ?? "—", info: MetricCatalog.processDisk)
                StatRow(label: "Disk write", value: p.diskWriteBytesPerSecond.map(Format.rate) ?? "—", info: MetricCatalog.processDisk)
                if let read = p.diskReadTotal, let written = p.diskWrittenTotal {
                    StatRow(label: "Disk total", value: "\(Format.bytes(read)) read · \(Format.bytes(written)) written")
                }
                if let gpu = p.gpuTimeShare {
                    StatRow(label: "GPU time share", value: Format.percent(min(gpu, 1), precise: true), info: MetricCatalog.gpuProcessTime)
                }
                StatRow(label: "Uptime", value: Format.duration(p.runtime(now: engine.system.timestamp)))
                StatRow(label: "Started", value: Date(timeIntervalSince1970: p.startTime).formatted(date: .abbreviated, time: .standard))
                StatRow(label: "Architecture", value: p.architecture.label, info: MetricCatalog.processArchitecture)
                StatRow(label: "User", value: "\(p.userName) (\(p.uid))")
                if let open = details?.openFileCount { StatRow(label: "Open files", value: String(open)) }
            }

            if let inspected, p.countersAvailable {
                HistoryMini(title: "CPU", points: inspected.cpu.points(for: .fiveMinutes), color: Theme.cpu,
                            value: p.cpuPercent.map { Format.processCPU($0) + "%" } ?? "—", maxValue: nil)
                HistoryMini(title: "Memory", points: inspected.memory.points(for: .fiveMinutes), color: Theme.memory,
                            value: p.memoryFootprint.map { Format.bytes($0) } ?? "—", maxValue: nil)
            }

            InspectorSection(title: "Parent") {
                if let parent = engine.processesByPID[p.parentPID], p.parentPID != p.pid {
                    ProcessLink(process: parent, selection: $selection)
                } else {
                    Text(p.parentPID == 0 ? "kernel" : "PID \(p.parentPID)").foregroundStyle(.secondary)
                }
            }

            if !children.isEmpty {
                InspectorSection(title: "Children (\(children.count))") {
                    ForEach(children.prefix(20)) { child in ProcessLink(process: child, selection: $selection) }
                    if children.count > 20 { Text("and \(children.count - 20) more").foregroundStyle(.secondary) }
                }
            }

            if let details, !details.listening.isEmpty {
                InspectorSection(title: "Listening") {
                    ForEach(details.listening) { socket in
                        HStack {
                            Text("TCP " + socket.label).font(.system(size: 11.5).monospacedDigit()).textSelection(.enabled)
                            Spacer()
                            Text(socket.isLoopbackOnly ? "this Mac only" : (socket.address == "*" ? "all interfaces" : ""))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let path = p.executablePath {
                InspectorSection(title: "Executable") {
                    Text(path).font(.system(size: 11).monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let details, !details.arguments.isEmpty {
                InspectorSection(title: "Arguments") {
                    Text(details.arguments.joined(separator: " "))
                        .font(.system(size: 11).monospaced())
                        .textSelection(.enabled)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let cwd = details?.workingDirectory {
                InspectorSection(title: "Working directory") {
                    Text(cwd).font(.system(size: 11).monospaced()).textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12))
    }
}

private struct InspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProcessLink: View {
    var process: ProcessSample
    @Binding var selection: ProcessIdentity?

    var body: some View {
        Button {
            selection = process.id
        } label: {
            HStack(spacing: 6) {
                ProcessIcon(sample: process, size: 14)
                Text(process.name).lineLimit(1)
                Text(String(process.pid)).foregroundStyle(.tertiary).font(.numeric)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryMini: View {
    var title: String
    var points: [HistoryPoint]
    var color: Color
    var value: String
    var maxValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(text: title + " · since selected")
                Spacer()
                Text(value).font(.numericMedium)
            }
            Sparkline(points: points, color: color, maxValue: maxValue)
                .frame(height: 34)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
