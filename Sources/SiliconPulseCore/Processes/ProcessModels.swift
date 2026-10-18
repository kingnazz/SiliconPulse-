import Foundation

public enum ProcessArchitecture: String, Sendable, Codable {
    case appleSilicon, intel, rosetta, unknown

    public var label: String {
        switch self {
        case .appleSilicon: return "Apple"
        case .intel: return "Intel"
        case .rosetta: return "Intel (Rosetta)"
        case .unknown: return "—"
        }
    }
}

/// Stable identity for a process: PIDs are reused, so the start time disambiguates.
public struct ProcessIdentity: Hashable, Sendable {
    public var pid: Int32
    public var startTime: TimeInterval

    public init(pid: Int32, startTime: TimeInterval) {
        self.pid = pid
        self.startTime = startTime
    }
}

/// One row of the process table.
public struct ProcessSample: Identifiable, Equatable, Sendable {
    public var id: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var executablePath: String?
    public var uid: UInt32
    public var userName: String
    /// Seconds since 1970.
    public var startTime: TimeInterval
    public var architecture: ProcessArchitecture
    public var isApp: Bool
    public var bundleIdentifier: String?

    /// False when macOS refuses per-process counters (other users' processes).
    public var countersAvailable: Bool
    /// Percentage of one core. Nil on the first sample of a process or when restricted.
    public var cpuPercent: Double?
    /// Cumulative CPU nanoseconds, kept for delta computation.
    public var cpuTimeNanoseconds: UInt64?
    public var memoryFootprint: UInt64?
    public var threadCount: Int?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var diskReadTotal: UInt64?
    public var diskWrittenTotal: UInt64?
    /// Fraction of wall time with GPU work, from IOKit client accounting (estimated).
    public var gpuTimeShare: Double?

    public init(pid: Int32, parentPID: Int32 = 1, name: String, executablePath: String? = nil, uid: UInt32 = 501,
                userName: String = "user", startTime: TimeInterval = 0, architecture: ProcessArchitecture = .appleSilicon,
                isApp: Bool = false, bundleIdentifier: String? = nil, countersAvailable: Bool = true,
                cpuPercent: Double? = nil, cpuTimeNanoseconds: UInt64? = nil, memoryFootprint: UInt64? = nil,
                threadCount: Int? = nil, diskReadBytesPerSecond: Double? = nil, diskWriteBytesPerSecond: Double? = nil,
                diskReadTotal: UInt64? = nil, diskWrittenTotal: UInt64? = nil, gpuTimeShare: Double? = nil) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.uid = uid
        self.userName = userName
        self.startTime = startTime
        self.architecture = architecture
        self.isApp = isApp
        self.bundleIdentifier = bundleIdentifier
        self.countersAvailable = countersAvailable
        self.cpuPercent = cpuPercent
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.memoryFootprint = memoryFootprint
        self.threadCount = threadCount
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.diskReadTotal = diskReadTotal
        self.diskWrittenTotal = diskWrittenTotal
        self.gpuTimeShare = gpuTimeShare
    }

    public func runtime(now: Date) -> TimeInterval { max(0, now.timeIntervalSince1970 - startTime) }

    /// Heuristic for the "System" filter: root/daemon accounts or OS locations.
    public var isSystemProcess: Bool {
        if uid < 500 { return true }
        guard let path = executablePath else { return false }
        return ProcessSample.systemPathPrefixes.contains { path.hasPrefix($0) }
    }

    static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/"]

    // Non-optional sort keys: unavailable values sort below any real value.
    public var cpuSortValue: Double { cpuPercent ?? -1 }
    public var memorySortValue: Double { memoryFootprint.map(Double.init) ?? -1 }
    public var threadSortValue: Int { threadCount ?? -1 }
    public var diskReadSortValue: Double { diskReadBytesPerSecond ?? -1 }
    public var diskWriteSortValue: Double { diskWriteBytesPerSecond ?? -1 }
    public var gpuSortValue: Double { gpuTimeShare ?? -1 }
    public var nameSortValue: String { name.lowercased() }
}

public enum ProcessFilter: String, CaseIterable, Identifiable, Sendable {
    case all, apps, system, ai, highCPU, highMemory

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "All"
        case .apps: return "Apps"
        case .system: return "System"
        case .ai: return "AI"
        case .highCPU: return "High CPU"
        case .highMemory: return "High Memory"
        }
    }

    /// Percent of one core.
    public static let highCPUThreshold = 25.0
    public static let highMemoryThreshold: UInt64 = 1_073_741_824  // 1 GB
}

public enum ProcessSortKey: String, CaseIterable, Sendable {
    case name, pid, cpu, memory, threads, diskRead, diskWrite, runtime, architecture, user, gpu
}

public struct ProcessQuery: Equatable, Sendable {
    public var search: String
    public var filter: ProcessFilter
    public var sortKey: ProcessSortKey
    public var ascending: Bool

    public init(search: String = "", filter: ProcessFilter = .all, sortKey: ProcessSortKey = .cpu, ascending: Bool = false) {
        self.search = search
        self.filter = filter
        self.sortKey = sortKey
        self.ascending = ascending
    }
}

public enum ProcessTable {
    public static func matches(_ p: ProcessSample, filter: ProcessFilter, aiPIDs: Set<Int32>) -> Bool {
        switch filter {
        case .all: return true
        case .apps: return p.isApp
        case .system: return p.isSystemProcess
        case .ai: return aiPIDs.contains(p.pid)
        case .highCPU: return (p.cpuPercent ?? 0) >= ProcessFilter.highCPUThreshold
        case .highMemory: return (p.memoryFootprint ?? 0) >= ProcessFilter.highMemoryThreshold
        }
    }

    public static func matches(_ p: ProcessSample, search: String) -> Bool {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return true }
        if let pid = Int32(term), p.pid == pid { return true }
        if p.name.localizedCaseInsensitiveContains(term) { return true }
        if let bundle = p.bundleIdentifier, bundle.localizedCaseInsensitiveContains(term) { return true }
        if let path = p.executablePath, path.localizedCaseInsensitiveContains(term) { return true }
        return p.userName.localizedCaseInsensitiveContains(term)
    }

    public static func apply(_ query: ProcessQuery, to processes: [ProcessSample], aiPIDs: Set<Int32> = [], now: Date = Date()) -> [ProcessSample] {
        let filtered = processes.filter { matches($0, filter: query.filter, aiPIDs: aiPIDs) && matches($0, search: query.search) }
        return sort(filtered, by: query.sortKey, ascending: query.ascending, now: now)
    }

    public static func sort(_ processes: [ProcessSample], by key: ProcessSortKey, ascending: Bool, now: Date = Date()) -> [ProcessSample] {
        switch key {
        case .name: return sorted(processes, ascending) { $0.nameSortValue }
        case .pid: return sorted(processes, ascending) { $0.pid }
        case .cpu: return sorted(processes, ascending) { $0.cpuSortValue }
        case .memory: return sorted(processes, ascending) { $0.memorySortValue }
        case .threads: return sorted(processes, ascending) { $0.threadSortValue }
        case .diskRead: return sorted(processes, ascending) { $0.diskReadSortValue }
        case .diskWrite: return sorted(processes, ascending) { $0.diskWriteSortValue }
        case .runtime: return sorted(processes, ascending) { $0.runtime(now: now) }
        case .architecture: return sorted(processes, ascending) { $0.architecture.rawValue }
        case .user: return sorted(processes, ascending) { $0.userName }
        case .gpu: return sorted(processes, ascending) { $0.gpuSortValue }
        }
    }

    /// Reads each process's key once and sorts small (key, pid, index) tuples rather than comparing
    /// whole samples; this runs for ~500 processes on every refresh while the table is visible.
    /// Equal keys fall back to PID so rows do not jump between refreshes.
    private static func sorted<T: Comparable>(_ processes: [ProcessSample], _ ascending: Bool, by key: (ProcessSample) -> T) -> [ProcessSample] {
        let keyed = processes.indices.map { (key: key(processes[$0]), pid: processes[$0].pid, index: $0) }
        let order = keyed.sorted { a, b in
            if a.key == b.key { return a.pid < b.pid }
            return ascending ? a.key < b.key : a.key > b.key
        }
        return order.map { processes[$0.index] }
    }

    /// Top processes by a key, skipping restricted rows.
    public static func top(_ processes: [ProcessSample], by key: ProcessSortKey, limit: Int) -> [ProcessSample] {
        Array(sort(processes.filter(\.countersAvailable), by: key, ascending: false).prefix(limit))
    }
}

/// Parent/child relationships derived from the process table.
public struct ProcessTree: Sendable {
    private let children: [Int32: [Int32]]

    public init(_ processes: [ProcessSample]) {
        var map: [Int32: [Int32]] = [:]
        for p in processes where p.pid != p.parentPID {
            map[p.parentPID, default: []].append(p.pid)
        }
        children = map
    }

    public func children(of pid: Int32) -> [Int32] { children[pid] ?? [] }

    /// All descendants, breadth first. Guards against cycles.
    public func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var seen: Set<Int32> = [pid]
        var queue = children(of: pid)
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard seen.insert(next).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: children(of: next))
        }
        return result
    }
}

/// Parses the buffer returned by `sysctl(KERN_PROCARGS2)`:
/// `int32 argc`, executable path, NUL padding, `argc` NUL-terminated arguments, then environment strings.
public enum ProcArgsParser {
    public struct Result: Equatable, Sendable {
        public var executablePath: String
        public var arguments: [String]
        public var environment: [String: String]
    }

    public static func parse(_ buffer: [UInt8]) -> Result? {
        guard buffer.count >= 4 else { return nil }
        let argc = Int(Int32(bitPattern: UInt32(buffer[0]) | UInt32(buffer[1]) << 8 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24))
        guard argc >= 0, argc < 65_536 else { return nil }
        var index = 4

        func readString() -> String? {
            guard index < buffer.count else { return nil }
            let start = index
            while index < buffer.count && buffer[index] != 0 { index += 1 }
            let value = String(decoding: buffer[start..<index], as: UTF8.self)
            if index < buffer.count { index += 1 }  // skip NUL
            return value
        }

        guard let path = readString() else { return nil }
        while index < buffer.count && buffer[index] == 0 { index += 1 }  // padding

        var arguments: [String] = []
        arguments.reserveCapacity(argc)
        for _ in 0..<argc {
            guard let arg = readString() else { break }
            arguments.append(arg)
        }

        var environment: [String: String] = [:]
        while index < buffer.count {
            guard let entry = readString(), !entry.isEmpty else { break }
            if let eq = entry.firstIndex(of: "=") {
                environment[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        return Result(executablePath: path, arguments: arguments, environment: environment)
    }
}
