import SiliconPulseCore
import SwiftUI

struct ProcessesView: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var search = ""
    @State private var filter: ProcessFilter = .all
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpuSortValue, order: .reverse)]
    @State private var selection: ProcessIdentity?
    @State private var showInspector = false

    private static let sortKeys: [PartialKeyPath<ProcessSample>: ProcessSortKey] = [
        \ProcessSample.nameSortValue: .name,
        \ProcessSample.pid: .pid,
        \ProcessSample.cpuSortValue: .cpu,
        \ProcessSample.memorySortValue: .memory,
        \ProcessSample.threadSortValue: .threads,
        \ProcessSample.diskReadSortValue: .diskRead,
        \ProcessSample.diskWriteSortValue: .diskWrite,
        \ProcessSample.runtimeSortValue: .runtime,
        \ProcessSample.architectureSortValue: .architecture,
        \ProcessSample.userName: .user,
    ]

    private var query: ProcessQuery {
        let comparator = sortOrder.first
        let key = comparator.flatMap { Self.sortKeys[$0.keyPath] } ?? .cpu
        return ProcessQuery(search: search, filter: filter, sortKey: key, ascending: comparator?.order == .forward)
    }

    var body: some View {
        let now = engine.system.timestamp
        let all = engine.processes
        let aiPIDs = engine.ai.aiPIDs
        let rows = ProcessTable.apply(query, to: all, aiPIDs: aiPIDs, now: now)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Filter", selection: $filter) {
                    ForEach(ProcessFilter.allCases) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                Spacer()
                Text("\(rows.count) of \(all.count) processes")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.nameSortValue) { p in
                    HStack(spacing: 6) {
                        ProcessIcon(sample: p)
                        Text(p.name).lineLimit(1).truncationMode(.middle)
                        if aiPIDs.contains(p.pid) {
                            Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Theme.ai)
                                .help("Part of a detected local AI workload")
                        }
                    }
                }
                .width(min: 170, ideal: 240)

                TableColumn("PID", value: \.pid) { p in
                    Text(String(p.pid)).font(.numeric).foregroundStyle(.secondary)
                }
                .width(min: 44, ideal: 56, max: 70)

                TableColumn("CPU %", value: \.cpuSortValue) { p in
                    RestrictedText(p.cpuPercent.map(Format.processCPU), available: p.countersAvailable)
                        .foregroundStyle((p.cpuPercent ?? 0) >= ProcessFilter.highCPUThreshold ? Theme.caution : .primary)
                }
                .width(min: 52, ideal: 60, max: 80)

                TableColumn("Memory", value: \.memorySortValue) { p in
                    RestrictedText(p.memoryFootprint.map { Format.bytes($0) }, available: p.countersAvailable)
                }
                .width(min: 64, ideal: 78, max: 100)

                TableColumn("Threads", value: \.threadSortValue) { p in
                    RestrictedText(p.threadCount.map(String.init), available: p.countersAvailable)
                }
                .width(min: 46, ideal: 56, max: 70)

                TableColumn("Disk Read", value: \.diskReadSortValue) { p in
                    RestrictedText(p.diskReadBytesPerSecond.map(Format.rate), available: p.countersAvailable)
                }
                .width(min: 64, ideal: 78, max: 100)

                TableColumn("Disk Write", value: \.diskWriteSortValue) { p in
                    RestrictedText(p.diskWriteBytesPerSecond.map(Format.rate), available: p.countersAvailable)
                }
                .width(min: 64, ideal: 78, max: 100)

                TableColumn("Runtime", value: \.runtimeSortValue) { p in
                    Text(p.startTime > 0 ? Format.duration(p.runtime(now: now)) : "—").font(.numeric).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 72, max: 96)

                TableColumn("Arch", value: \.architectureSortValue) { p in
                    Text(p.architecture.label).foregroundStyle(p.architecture == .rosetta ? Theme.caution : .secondary)
                }
                .width(min: 50, ideal: 64, max: 110)

                TableColumn("User", value: \.userName) { p in
                    Text(p.userName).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 50, ideal: 80, max: 140)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .font(.system(size: 12))
            .contextMenu(forSelectionType: ProcessIdentity.self) { ids in
                if let id = ids.first, let p = all.first(where: { $0.id == id }) {
                    Button("Copy PID") { copy(String(p.pid)) }
                    if let path = p.executablePath {
                        Button("Copy Executable Path") { copy(path) }
                        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                    }
                }
            } primaryAction: { ids in
                selection = ids.first
                showInspector = true
            }

            Divider()
            footer(all: all)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name, PID, bundle ID or path")
        .inspector(isPresented: $showInspector) {
            Group {
                if let selection {
                    ProcessInspector(identity: selection, selection: $selection)
                } else {
                    EmptyStateView(symbol: "sidebar.right", title: "No process selected", message: "Select a process to inspect it.")
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the process inspector")
            }
        }
        .onChange(of: selection) { _, newValue in
            engine.inspect(newValue)
            if newValue != nil { showInspector = true }
        }
        .onAppear {
            if let inspected = engine.inspected?.identity {
                selection = inspected
                showInspector = true
            }
        }
        .onDisappear { engine.inspect(nil) }
    }

    private func footer(all: [ProcessSample]) -> some View {
        let restricted = all.filter { !$0.countersAvailable }.count
        let rosetta = all.filter { $0.architecture == .rosetta }.count
        return HStack(spacing: 14) {
            if restricted > 0 {
                Label("\(restricted) restricted", systemImage: "lock")
                    .help(MetricCatalog.restricted.tooltip)
            }
            if rosetta > 0 {
                Label("\(rosetta) under Rosetta", systemImage: "cpu")
            }
            Spacer()
            Text("Updated every \(Format.fixed(engine.activeSchedule.processes, engine.activeSchedule.processes < 1 ? 1 : 0)) s")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Shows "—" with an explanation for restricted processes.
struct RestrictedText: View {
    var text: String?
    var available: Bool

    init(_ text: String?, available: Bool) {
        self.text = text
        self.available = available
    }

    var body: some View {
        Text(text ?? "—")
            .font(.numeric)
            .foregroundStyle(text == nil ? .tertiary : .primary)
            .help(available ? "" : MetricCatalog.restricted.note ?? "")
    }
}

extension ProcessSample {
    /// Ascending runtime is descending start time, so the key is the negated start time.
    var runtimeSortValue: TimeInterval { -startTime }
    var architectureSortValue: String { architecture.rawValue }
}
