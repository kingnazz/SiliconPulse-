import Darwin
import Foundation
import SiliconPulseCore

/// Owns every collector. All OS calls happen on this actor, off the main thread,
/// and each collector's own CPU cost is measured so SiliconPulse can report what it costs.
public actor SystemSampler {
    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let gpu = GPUCollector()
    private let disk = DiskCollector()
    private let network = NetworkCollector()
    private let power = PowerCollector()
    private let processes = ProcessCollector()
    private var gpuTracker = GPUTimeTracker()
    private var lastPower: PowerSnapshot = .unknown
    private var timings: [String: CollectorTiming] = [:]
    private var lastProcesses: [ProcessSample] = []
    /// Listening ports per candidate, rescanned at most every `portRescanInterval` seconds.
    private var portCache: [ProcessIdentity: (ports: [UInt16], time: UInt64)] = [:]
    private let portRescanInterval: UInt64 = 15_000_000_000

    public init() {}

    public var ownPID: Int32 { processes.ownPID }

    public nonisolated var cpuTopology: CPUTopology { CPUCollector.readTopology() }

    private func measure<T>(_ name: String, _ body: () -> T) -> T {
        let cpuStart = Clock.threadCPUNanoseconds()
        let wallStart = Clock.uptimeNanoseconds()
        let value = body()
        let cpu = Clock.threadCPUNanoseconds() &- cpuStart
        let wall = Clock.uptimeNanoseconds() &- wallStart
        timings[name, default: CollectorTiming(name: name)].record(cpu: cpu, wall: wall)
        return value
    }

    /// Fast tier: CPU, GPU, memory, disk, network, thermal.
    public func sampleSystem(previous: SystemSnapshot) -> SystemSnapshot {
        let now = Clock.uptimeNanoseconds()
        let cpuSnapshot = measure("CPU") { cpu.sample() }
        let gpuSnapshot = measure("GPU") { gpu.sample() }
        let memorySnapshot = measure("Memory") { memory.sample(now: now) }
        let diskSnapshot = measure("Disk") { disk.sample(now: now) }
        let networkSnapshot = measure("Network") { network.sample(now: now) }
        let thermal = measure("Thermal") { power.thermalLevel() }
        var snapshot = SystemSnapshot.assemble(previous: previous, timestamp: Date(), cpu: cpuSnapshot, gpu: gpuSnapshot,
                                               memory: memorySnapshot, disk: diskSnapshot, network: networkSnapshot,
                                               thermal: thermal)
        snapshot.thermal.power = lastPower
        return snapshot
    }

    /// Slow tier: power source and battery.
    public func samplePower() -> PowerSnapshot {
        lastPower = measure("Power") { power.power() }
        return lastPower
    }

    /// Process tier: process table plus per-process GPU time.
    public func sampleProcesses(apps: [Int32: RunningAppInfo]) -> [ProcessSample] {
        let now = Clock.uptimeNanoseconds()
        let gpuTotals = measure("GPU clients") { gpu.perProcessGPUTime() }
        let shares = gpuTotals.map { gpuTracker.update(totals: $0, now: now) } ?? [:]
        let result = measure("Processes") { processes.sample(now: now, apps: apps, gpuShares: shares) }
        lastProcesses = result
        return result
    }

    public var perProcessGPUSupported: Bool? { gpu.perProcessSupported }

    /// AI tier: arguments, selected environment and listening ports for candidate processes only.
    public func aiCandidates(from samples: [ProcessSample]) -> [AIProcessInfo] {
        let now = Clock.uptimeNanoseconds()
        let result = measure("AI candidates") {
            samples.filter(AICandidateFilter.isCandidate).map { sample in
                let args = sample.countersAvailable ? processes.arguments(for: sample.id) : nil
                var environment: [String: String] = [:]
                if let value = args?.environment["OLLAMA_HOST"] { environment["OLLAMA_HOST"] = value }
                return AIProcessInfo(sample: sample, arguments: args?.arguments ?? [], environment: environment,
                                     listeningPorts: sample.countersAvailable ? listeningPorts(for: sample.id, now: now) : [])
            }
        }
        let alive = Set(samples.map(\.id))
        portCache = portCache.filter { alive.contains($0.key) }
        return result
    }

    private func listeningPorts(for identity: ProcessIdentity, now: UInt64) -> [UInt16] {
        if let cached = portCache[identity], now &- cached.time < portRescanInterval { return cached.ports }
        let ports = Array(Set(processes.listeningSockets(pid: identity.pid).map(\.port))).sorted()
        portCache[identity] = (ports, now)
        return ports
    }

    /// Forces the next AI pass to rescan listening ports (e.g. the user asked for a refresh).
    public func invalidatePortCache() { portCache.removeAll() }

    /// Inspector detail for one process.
    public func details(for identity: ProcessIdentity) -> ProcessDetails {
        measure("Inspector") {
            ProcessDetails(pid: identity.pid,
                           arguments: processes.arguments(for: identity)?.arguments ?? [],
                           workingDirectory: processes.workingDirectory(pid: identity.pid),
                           listening: processes.listeningSockets(pid: identity.pid),
                           openFileCount: processes.openFileCount(pid: identity.pid))
        }
    }

    public func collectorTimings() -> [CollectorTiming] {
        timings.values.sorted { $0.averageCPUMilliseconds > $1.averageCPUMilliseconds }
    }
}
