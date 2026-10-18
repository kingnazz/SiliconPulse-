import Darwin
import Foundation
import IOKit
import SiliconPulseCore

/// System CPU utilization from `host_processor_info` tick counters.
final class CPUCollector {
    private let host = mach_host_self()
    private var previous: [CPUTicks] = []
    let topology: CPUTopology

    init() {
        topology = CPUCollector.readTopology()
    }

    func sample() -> CPUSnapshot? {
        guard let ticks = readTicks() else { return nil }
        defer { previous = ticks }

        var load = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&load, 3)
        let loadAverage = loadCount > 0 ? Array(load.prefix(Int(loadCount))) : []

        guard let usage = CPUCalculator.usage(from: previous, to: ticks) else {
            // First sample (or core count changed): no interval to measure yet.
            return CPUSnapshot(usage: .zero, cores: [], loadAverage: loadAverage, topology: topology)
        }
        let kinds = topology.coreKinds
        var cores: [CoreUsage] = []
        cores.reserveCapacity(usage.perCore.count)
        for (index, core) in usage.perCore.enumerated() {
            let kind = (kinds != nil && index < kinds!.count) ? kinds![index] : .unknown
            cores.append(CoreUsage(id: index, kind: kind, usage: core))
        }
        return CPUSnapshot(usage: usage.total, cores: cores, loadAverage: loadAverage, topology: topology)
    }

    private func readTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }
        let stride = Int(CPU_STATE_MAX)
        var ticks: [CPUTicks] = []
        ticks.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            ticks.append(CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return ticks
    }

    static func readTopology() -> CPUTopology {
        let brand = Sysctl.string("machdep.cpu.brand_string") ?? "Unknown CPU"
        let physical = Sysctl.int("hw.physicalcpu") ?? 0
        let logical = Sysctl.int("hw.logicalcpu") ?? 0
        var performance: Int?
        var efficiency: Int?
        if let levels = Sysctl.int("hw.nperflevels"), levels > 1 {
            for level in 0..<levels {
                let name = Sysctl.string("hw.perflevel\(level).name")?.lowercased() ?? ""
                let count = Sysctl.int("hw.perflevel\(level).logicalcpu")
                if name.hasPrefix("perf") { performance = count } else if name.hasPrefix("eff") { efficiency = count }
            }
        }
        let kinds = deviceTreeCoreKinds(count: logical).flatMap {
            CPUCalculator.validatedCoreKinds($0, logicalCores: logical, performanceCores: performance, efficiencyCores: efficiency)
        }
        return CPUTopology(brand: brand, physicalCores: physical, logicalCores: logical,
                           performanceCores: performance, efficiencyCores: efficiency, coreKinds: kinds)
    }

    /// Reads `cluster-type` for each CPU from the device tree. Returns nil unless every CPU is accounted for.
    static func deviceTreeCoreKinds(count: Int) -> [CoreKind]? {
        guard count > 0 else { return nil }
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var kinds = [CoreKind](repeating: .unknown, count: count)
        var found = 0
        var position = 0
        IORegistry.forEachChild(of: cpus, plane: "IODeviceTree") { entry in
            defer { position += 1 }
            guard let typeBytes = IORegistry.bytes(entry, "cluster-type") else { return }
            let kind = IORegistryParsing.coreKind(fromClusterType: IORegistryParsing.string(fromDeviceTreeData: typeBytes))
            let id = (IORegistry.bytes(entry, "logical-cpu-id") ?? IORegistry.bytes(entry, "cpu-id"))
                .flatMap(IORegistryParsing.uint32(fromDeviceTreeData:)).map(Int.init) ?? position
            if id < count, kinds[id] == .unknown {
                kinds[id] = kind
                found += 1
            }
        }
        return found == count ? kinds : nil
    }
}
