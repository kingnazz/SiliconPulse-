import Foundation

// Plain value snapshots produced by collectors and consumed by views.
// Collectors live in SiliconPulseSystem; nothing here touches the OS.

// MARK: CPU

public enum CoreKind: String, Sendable, Codable {
    case performance, efficiency, unknown

    public var shortLabel: String {
        switch self {
        case .performance: return "P"
        case .efficiency: return "E"
        case .unknown: return ""
        }
    }
}

public struct CPUUsage: Equatable, Sendable {
    /// Fractions in 0...1.
    public var user: Double
    public var system: Double
    public var nice: Double
    public var idle: Double

    public init(user: Double, system: Double, nice: Double, idle: Double) {
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
    }

    public static let zero = CPUUsage(user: 0, system: 0, nice: 0, idle: 1)

    public var total: Double { min(1, max(0, user + system + nice)) }
}

public struct CoreUsage: Identifiable, Equatable, Sendable {
    public var id: Int
    public var kind: CoreKind
    public var usage: CPUUsage

    public init(id: Int, kind: CoreKind, usage: CPUUsage) {
        self.id = id
        self.kind = kind
        self.usage = usage
    }
}

public struct CPUTopology: Equatable, Sendable {
    public var brand: String
    public var physicalCores: Int
    public var logicalCores: Int
    /// nil when the machine has no performance levels (Intel) or they could not be read.
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    /// Per logical CPU kind, only present when the device tree agrees with sysctl.
    public var coreKinds: [CoreKind]?

    public init(brand: String, physicalCores: Int, logicalCores: Int, performanceCores: Int? = nil,
                efficiencyCores: Int? = nil, coreKinds: [CoreKind]? = nil) {
        self.brand = brand
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.coreKinds = coreKinds
    }

    public static let unknown = CPUTopology(brand: "Unknown CPU", physicalCores: 0, logicalCores: 0)
}

public struct CPUSnapshot: Equatable, Sendable {
    public var usage: CPUUsage
    public var cores: [CoreUsage]
    public var loadAverage: [Double]
    public var topology: CPUTopology

    public init(usage: CPUUsage, cores: [CoreUsage], loadAverage: [Double], topology: CPUTopology) {
        self.usage = usage
        self.cores = cores
        self.loadAverage = loadAverage
        self.topology = topology
    }

    public static let empty = CPUSnapshot(usage: .zero, cores: [], loadAverage: [], topology: .unknown)

    /// Average utilization of one cluster kind, or nil when the core kinds are not known.
    public func clusterUsage(_ kind: CoreKind) -> Double? {
        let matching = cores.filter { $0.kind == kind }
        guard !matching.isEmpty, kind != .unknown else { return nil }
        return matching.reduce(0) { $0 + $1.usage.total } / Double(matching.count)
    }
}

// MARK: GPU

public struct GPUSnapshot: Equatable, Sendable {
    public var name: String
    public var coreCount: Int?
    /// Fractions 0...1, nil when not reported.
    public var deviceUtilization: Double?
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    public var memoryInUse: UInt64?
    public var memoryAllocated: UInt64?

    public init(name: String, coreCount: Int? = nil, deviceUtilization: Double? = nil, rendererUtilization: Double? = nil,
                tilerUtilization: Double? = nil, memoryInUse: UInt64? = nil, memoryAllocated: UInt64? = nil) {
        self.name = name
        self.coreCount = coreCount
        self.deviceUtilization = deviceUtilization
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
        self.memoryInUse = memoryInUse
        self.memoryAllocated = memoryAllocated
    }

    public static let unavailable = GPUSnapshot(name: "GPU")

    public var isAvailable: Bool { deviceUtilization != nil }
}

// MARK: Memory

public enum MemoryPressure: String, Sendable, Codable, CaseIterable {
    case normal, warning, critical, unknown

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    /// Maps `kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical).
    public init(kernelLevel: Int32) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

public struct MemorySnapshot: Equatable, Sendable {
    public var total: UInt64
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cachedFiles: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure
    /// `kern.memorystatus_level`, 0...100.
    public var kernelFreeLevel: Int?
    /// Pages per second, nil on the first sample.
    public var swapInsPerSecond: Double?
    public var swapOutsPerSecond: Double?
    public var compressionsPerSecond: Double?
    public var decompressionsPerSecond: Double?

    public init(total: UInt64, used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cachedFiles: UInt64,
                free: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure, kernelFreeLevel: Int? = nil,
                swapInsPerSecond: Double? = nil, swapOutsPerSecond: Double? = nil,
                compressionsPerSecond: Double? = nil, decompressionsPerSecond: Double? = nil) {
        self.total = total
        self.used = used
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.free = free
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
        self.kernelFreeLevel = kernelFreeLevel
        self.swapInsPerSecond = swapInsPerSecond
        self.swapOutsPerSecond = swapOutsPerSecond
        self.compressionsPerSecond = compressionsPerSecond
        self.decompressionsPerSecond = decompressionsPerSecond
    }

    public static let empty = MemorySnapshot(total: 0, used: 0, app: 0, wired: 0, compressed: 0, cachedFiles: 0, free: 0,
                                             swapUsed: 0, swapTotal: 0, pressure: .unknown)

    public var available: UInt64 { total > used ? total - used : 0 }

    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    /// Estimated room to allocate before compression ramps up: available minus 10% of installed memory.
    public var estimatedHeadroom: UInt64 {
        let reserve = total / 10
        return available > reserve ? available - reserve : 0
    }

    /// True when macOS wrote memory to swap during the last interval.
    public var isSwappingOut: Bool { (swapOutsPerSecond ?? 0) > 0 }
}

// MARK: Disk & network

public struct DiskSnapshot: Equatable, Sendable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var totalRead: UInt64
    public var totalWritten: UInt64

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double, totalRead: UInt64, totalWritten: UInt64) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.totalRead = totalRead
        self.totalWritten = totalWritten
    }

    public static let empty = DiskSnapshot(readBytesPerSecond: 0, writeBytesPerSecond: 0, totalRead: 0, totalWritten: 0)
}

public struct InterfaceThroughput: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var receivedBytesPerSecond: Double
    public var sentBytesPerSecond: Double
    public var totalReceived: UInt64
    public var totalSent: UInt64

    public init(name: String, receivedBytesPerSecond: Double, sentBytesPerSecond: Double, totalReceived: UInt64, totalSent: UInt64) {
        self.name = name
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.totalReceived = totalReceived
        self.totalSent = totalSent
    }
}

public struct NetworkSnapshot: Equatable, Sendable {
    public var receivedBytesPerSecond: Double
    public var sentBytesPerSecond: Double
    public var interfaces: [InterfaceThroughput]

    public init(receivedBytesPerSecond: Double, sentBytesPerSecond: Double, interfaces: [InterfaceThroughput]) {
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.interfaces = interfaces
    }

    public static let empty = NetworkSnapshot(receivedBytesPerSecond: 0, sentBytesPerSecond: 0, interfaces: [])
}

// MARK: Thermal & power

public enum ThermalLevel: String, Sendable, Codable, CaseIterable {
    case normal, elevated, serious, critical, unknown

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .elevated: return "Elevated"
        case .serious: return "Serious"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    /// Maps `ProcessInfo.ThermalState.rawValue` (0 nominal, 1 fair, 2 serious, 3 critical).
    public init(processInfoRawValue: Int) {
        switch processInfoRawValue {
        case 0: self = .normal
        case 1: self = .elevated
        case 2: self = .serious
        case 3: self = .critical
        default: self = .unknown
        }
    }

    public var isConstrained: Bool { self == .serious || self == .critical }
}

public struct PowerSnapshot: Equatable, Sendable {
    public var hasBattery: Bool
    public var onACPower: Bool
    public var batteryPercent: Int?
    public var isCharging: Bool
    public var lowPowerMode: Bool

    public init(hasBattery: Bool, onACPower: Bool, batteryPercent: Int?, isCharging: Bool, lowPowerMode: Bool) {
        self.hasBattery = hasBattery
        self.onACPower = onACPower
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.lowPowerMode = lowPowerMode
    }

    public static let unknown = PowerSnapshot(hasBattery: false, onACPower: true, batteryPercent: nil, isCharging: false, lowPowerMode: false)

    public var summary: String {
        var parts: [String] = []
        if hasBattery {
            if let batteryPercent { parts.append("Battery \(batteryPercent)%") }
            parts.append(onACPower ? (isCharging ? "Charging" : "On power adapter") : "On battery")
        } else {
            parts.append("Power adapter")
        }
        if lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: " · ")
    }
}

public struct ThermalSnapshot: Equatable, Sendable {
    public var level: ThermalLevel
    public var power: PowerSnapshot

    public init(level: ThermalLevel, power: PowerSnapshot) {
        self.level = level
        self.power = power
    }

    public static let unknown = ThermalSnapshot(level: .unknown, power: .unknown)
}

// MARK: System snapshot

public enum SystemComponent: String, Sendable, CaseIterable {
    case cpu, memory
}

/// Everything the fast tier produces in one pass.
public struct SystemSnapshot: Equatable, Sendable {
    public var timestamp: Date
    /// Components whose collector failed this pass; their values are carried over from the previous pass.
    public var stale: Set<SystemComponent> = []
    public var cpu: CPUSnapshot
    public var gpu: GPUSnapshot
    public var memory: MemorySnapshot
    public var disk: DiskSnapshot
    public var network: NetworkSnapshot
    public var thermal: ThermalSnapshot

    public init(timestamp: Date, cpu: CPUSnapshot, gpu: GPUSnapshot, memory: MemorySnapshot, disk: DiskSnapshot,
                network: NetworkSnapshot, thermal: ThermalSnapshot) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.thermal = thermal
    }

    public static let empty = SystemSnapshot(timestamp: .distantPast, cpu: .empty, gpu: .unavailable, memory: .empty,
                                             disk: .empty, network: .empty, thermal: .unknown)

    /// Combines one pass of collector results. A collector that failed (nil) keeps its previous value and is
    /// marked stale, so a transient failure neither blanks the UI nor passes old data off as fresh.
    public static func assemble(previous: SystemSnapshot, timestamp: Date, cpu: CPUSnapshot?, gpu: GPUSnapshot,
                                memory: MemorySnapshot?, disk: DiskSnapshot, network: NetworkSnapshot,
                                thermal: ThermalLevel) -> SystemSnapshot {
        var snapshot = SystemSnapshot(timestamp: timestamp, cpu: cpu ?? previous.cpu, gpu: gpu, memory: memory ?? previous.memory,
                                      disk: disk, network: network,
                                      thermal: ThermalSnapshot(level: thermal, power: previous.thermal.power))
        if cpu == nil { snapshot.stale.insert(.cpu) }
        if memory == nil { snapshot.stale.insert(.memory) }
        return snapshot
    }
}
