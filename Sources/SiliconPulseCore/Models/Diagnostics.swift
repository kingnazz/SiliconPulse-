import Foundation

/// Deeper information gathered only for the process selected in the inspector.
public struct ProcessDetails: Equatable, Sendable {
    public var pid: Int32
    public var arguments: [String]
    public var workingDirectory: String?
    public var listening: [ListeningSocket]
    public var openFileCount: Int?

    public init(pid: Int32, arguments: [String] = [], workingDirectory: String? = nil, listening: [ListeningSocket] = [], openFileCount: Int? = nil) {
        self.pid = pid
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.listening = listening
        self.openFileCount = openFileCount
    }
}

public struct ListeningSocket: Hashable, Sendable, Identifiable {
    public var id: String { "\(address):\(port)" }
    public var address: String
    public var port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }

    public var isLoopbackOnly: Bool { address == "127.0.0.1" || address == "::1" }

    public var label: String {
        let host = address.contains(":") ? "[\(address)]" : address
        return "\(host):\(port)"
    }
}

/// Self-measured cost of one collector, from thread CPU time around each call.
public struct CollectorTiming: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var runs: Int
    public var totalCPUNanoseconds: UInt64
    public var lastCPUNanoseconds: UInt64
    public var lastWallNanoseconds: UInt64

    public init(name: String, runs: Int = 0, totalCPUNanoseconds: UInt64 = 0, lastCPUNanoseconds: UInt64 = 0, lastWallNanoseconds: UInt64 = 0) {
        self.name = name
        self.runs = runs
        self.totalCPUNanoseconds = totalCPUNanoseconds
        self.lastCPUNanoseconds = lastCPUNanoseconds
        self.lastWallNanoseconds = lastWallNanoseconds
    }

    public var averageCPUMilliseconds: Double { runs == 0 ? 0 : Double(totalCPUNanoseconds) / Double(runs) / 1_000_000 }

    public mutating func record(cpu: UInt64, wall: UInt64) {
        runs += 1
        totalCPUNanoseconds &+= cpu
        lastCPUNanoseconds = cpu
        lastWallNanoseconds = wall
    }
}

/// Self-reported engine health: used to prove there is exactly one sampling loop.
public struct EngineDiagnostics: Equatable, Sendable {
    public var activeLoops: Int = 0
    public var loopStarts: Int = 0
    public var systemSamples: Int = 0
    public var processSamples: Int = 0
    public var aiRefreshes: Int = 0
    public var aiRefreshesSkippedBusy: Int = 0
    public var lastAIRefreshDuration: TimeInterval = 0
    public var schedule: SamplingSchedule = SamplingSchedule(system: 1, processes: 2, aiDiscovery: 5, slow: 10)
    public var timings: [CollectorTiming] = []
    /// SiliconPulse's own process, from its own process sample.
    public var selfCPUPercent: Double?
    public var selfFootprint: UInt64?
    public var historyPoints: Int = 0

    public init() {}
}
