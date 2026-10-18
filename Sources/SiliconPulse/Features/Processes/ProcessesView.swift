import SiliconPulseCore
import SwiftUI

struct ProcessesView: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var search = ""
    @State private var filter: ProcessFilter = .all
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuSort, order: .reverse)]
    @State private var selection: ProcessIdentity?
    @State private var showInspector = false

    /// Column key paths → core sort keys. Rows are sorted by `ProcessTable`, not by the Table itself.
    private static let sortKeys: [PartialKeyPath<ProcessRow>: ProcessSortKey] = [
        \ProcessRow.name: .name,
        \ProcessRow.pid: .pid,
        \ProcessRow.cpuSort: .cpu,
        \ProcessRow.memorySort: .memory,
        \ProcessRow.threadSort: .threads,
        \ProcessRow.diskReadSort: .diskRead,
        \ProcessRow.diskWriteSort: .diskWrite,
        \ProcessRow.runtimeSort: .runtime,
        \ProcessRow.architecture: .architecture,
        \ProcessRow.userName: .user,
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

            Table(rows.map { ProcessRow($0, now: now, isAI: aiPIDs.contains($0.pid)) }, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name) { row in
                    HStack(spacing: 6) {
                        ProcessIcon(sample: row.iconSample)
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                        if row.isAI {
                            Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Theme.ai)
                                .help("Part of a detected local AI workload")
                        }
                    }
                }
                .width(min: 170, ideal: 240)

                TableColumn("PID", value: \.pid) { row in
                    Text(String(row.pid)).font(.numeric).foregroundStyle(.secondary)
                }
                .width(min: 44, ideal: 56, max: 70)

                TableColumn("CPU %", value: \.cpuSort) { row in
                    RestrictedText(row.cpu, available: row.countersAvailable)
                        .foregroundStyle(row.isHighCPU ? Theme.caution : .primary)
                }
                .width(min: 52, ideal: 60, max: 80)

                TableColumn("Memory", value: \.memorySort) { row in
                    RestrictedText(row.memory, available: row.countersAvailable)
                }
                .width(min: 64, ideal: 78, max: 100)

                TableColumn("Threads", value: \.threadSort) { row in
                    RestrictedText(row.threads, available: row.countersAvailable)
                }
                .width(min: 46, ideal: 56, max: 70)

                TableColumn("Disk Read", value: \.diskReadSort) { row in
                    RestrictedText(row.diskRead, available: row.countersAvailable)
                }
                .width(min: 64, ideal: 78, max: 100)

                TableColumn("Disk Write", value: \.diskWriteSort) { row in
                    RestrictedText(row.diskWrite, available: row.countersAvailable)
                }
                .width(min: 64, ideal: 78, max: 100)

                TableColumn("Runtime", value: \.runtimeSort) { row in
                    Text(row.runtime).font(.numeric).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 72, max: 96)

                TableColumn("Arch", value: \.architecture) { row in
                    Text(row.architecture).foregroundStyle(row.isRosetta ? Theme.caution : .secondary)
                }
                .width(min: 50, ideal: 64, max: 110)

                TableColumn("User", value: \.userName) { row in
                    Text(row.userName).foregroundStyle(.secondary).lineLimit(1)
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
            // Defer: changing observed state inside the table's selection callback is reentrant for NSTableView.
            Task { @MainActor in engine.inspect(newValue) }
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

/// What one table row displays. Values are pre-formatted at display precision, so rows whose visible
/// values did not change compare equal and SwiftUI leaves their cells alone; most processes are idle,
/// so this keeps a 500-row table cheap to refresh every second.
struct ProcessRow: Identifiable, Equatable {
    let id: ProcessIdentity
    let pid: Int32
    let name: String
    let iconSample: ProcessSample
    let isAI: Bool
    let countersAvailable: Bool
    let cpu: String?
    let isHighCPU: Bool
    let memory: String?
    let threads: String?
    let diskRead: String?
    let diskWrite: String?
    let runtime: String
    let architecture: String
    let isRosetta: Bool
    let userName: String
    // Sort keys at display precision (sorting itself is done by ProcessTable on full values).
    let cpuSort: Double
    let memorySort: Double
    let threadSort: Int
    let diskReadSort: Double
    let diskWriteSort: Double
    let runtimeSort: Double

    init(_ p: ProcessSample, now: Date, isAI: Bool) {
        id = p.id
        pid = p.pid
        name = p.name
        iconSample = ProcessSample(pid: p.pid, name: p.name, executablePath: p.executablePath, isApp: p.isApp)
        self.isAI = isAI
        countersAvailable = p.countersAvailable
        cpu = p.cpuPercent.map(Format.processCPU)
        isHighCPU = (p.cpuPercent ?? 0) >= ProcessFilter.highCPUThreshold
        memory = p.memoryFootprint.map { Format.bytes($0) }
        threads = p.threadCount.map(String.init)
        diskRead = p.diskReadBytesPerSecond.map(Format.rate)
        diskWrite = p.diskWriteBytesPerSecond.map(Format.rate)
        runtime = p.startTime > 0 ? Format.duration(p.runtime(now: now)) : "—"
        architecture = p.architecture.label
        isRosetta = p.architecture == .rosetta
        userName = p.userName
        cpuSort = (p.cpuSortValue * 10).rounded() / 10
        memorySort = (p.memorySortValue / 1_048_576).rounded()
        threadSort = p.threadSortValue
        diskReadSort = (p.diskReadSortValue / 1_000).rounded()
        diskWriteSort = (p.diskWriteSortValue / 1_000).rounded()
        runtimeSort = -p.startTime.rounded()
    }
}
