import Darwin
import Foundation
import IOKit
import SiliconPulseCore

/// System GPU utilization from the `IOAccelerator` registry entry, and per-process GPU time from its user clients.
final class GPUCollector {
    private var staticInfo: (name: String, cores: Int?)?
    /// nil = not yet known; false = this machine's GPU clients have no `AppUsage` accounting.
    private(set) var perProcessSupported: Bool?

    func sample() -> GPUSnapshot {
        var result: GPUSnapshot?
        IORegistry.forEachService(matching: "IOAccelerator") { service in
            guard result == nil else { return }
            if staticInfo == nil {
                let model = (IORegistry.property(service, "model") as? String)
                    ?? (IORegistry.property(service, "model") as? Data).map { IORegistryParsing.string(fromDeviceTreeData: [UInt8]($0)) }
                let cores = IORegistry.number(IORegistry.property(service, "gpu-core-count"))?.intValue
                staticInfo = (model ?? Sysctl.string("machdep.cpu.brand_string") ?? "GPU", cores)
            }
            guard let stats = IORegistry.property(service, "PerformanceStatistics") as? [String: Any] else { return }
            func fraction(_ key: String) -> Double? {
                IORegistry.number(stats[key]).map { min(1, max(0, $0.doubleValue / 100)) }
            }
            func bytes(_ key: String) -> UInt64? { IORegistry.number(stats[key])?.uint64Value }
            guard let device = fraction("Device Utilization %") ?? fraction("GPU Activity(%)") else { return }
            result = GPUSnapshot(name: staticInfo?.name ?? "GPU", coreCount: staticInfo?.cores,
                                 deviceUtilization: device,
                                 rendererUtilization: fraction("Renderer Utilization %"),
                                 tilerUtilization: fraction("Tiler Utilization %"),
                                 memoryInUse: bytes("In use system memory"),
                                 memoryAllocated: bytes("Alloc system memory"))
        }
        return result ?? GPUSnapshot(name: staticInfo?.name ?? "GPU", coreCount: staticInfo?.cores)
    }

    /// Cumulative GPU nanoseconds per PID from the accelerator's user clients (`AppUsage.accumulatedGPUTime`).
    /// Returns nil when the accounting is not available on this machine.
    func perProcessGPUTime() -> [Int32: UInt64]? {
        if perProcessSupported == false { return nil }
        var totals: [Int32: UInt64] = [:]
        var sawAccounting = false
        IORegistry.forEachService(matching: "IOAccelerator") { service in
            IORegistry.forEachChild(of: service, plane: "IOService") { client in
                guard let creator = IORegistry.property(client, "IOUserClientCreator") as? String,
                      let pid = IORegistryParsing.pid(fromUserClientCreator: creator) else { return }
                guard let usage = IORegistry.property(client, "AppUsage") as? [[String: Any]] else { return }
                sawAccounting = true
                var sum: UInt64 = 0
                for entry in usage {
                    if let time = IORegistry.number(entry["accumulatedGPUTime"])?.uint64Value { sum &+= time }
                }
                totals[pid, default: 0] &+= sum
            }
        }
        if perProcessSupported == nil { perProcessSupported = sawAccounting }
        return sawAccounting ? totals : nil
    }
}

/// System disk throughput from `IOBlockStorageDriver` statistics.
final class DiskCollector {
    private var previous: (read: [UInt64: UInt64], written: [UInt64: UInt64], time: UInt64)?

    func sample(now: UInt64) -> DiskSnapshot {
        var read: [UInt64: UInt64] = [:]
        var written: [UInt64: UInt64] = [:]
        IORegistry.forEachService(matching: "IOBlockStorageDriver") { service in
            guard let stats = IORegistry.property(service, "Statistics") as? [String: Any] else { return }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            read[id] = IORegistry.number(stats["Bytes (Read)"])?.uint64Value ?? 0
            written[id] = IORegistry.number(stats["Bytes (Write)"])?.uint64Value ?? 0
        }
        defer { previous = (read, written, now) }
        let totalRead = read.values.reduce(0, &+)
        let totalWritten = written.values.reduce(0, &+)
        guard let previous, now > previous.time else {
            return DiskSnapshot(readBytesPerSecond: 0, writeBytesPerSecond: 0, totalRead: totalRead, totalWritten: totalWritten)
        }
        let elapsed = Double(now - previous.time) / 1e9
        return DiskSnapshot(readBytesPerSecond: CounterRate.summedPerSecond(previous: previous.read, current: read, elapsed: elapsed),
                            writeBytesPerSecond: CounterRate.summedPerSecond(previous: previous.written, current: written, elapsed: elapsed),
                            totalRead: totalRead, totalWritten: totalWritten)
    }
}

/// System network throughput from 64-bit interface counters (`NET_RT_IFLIST2`).
final class NetworkCollector {
    private var buffer: [UInt8] = []
    private var names: [UInt16: String] = [:]
    private var previous: (rx: [String: UInt64], tx: [String: UInt64], time: UInt64)?

    func sample(now: UInt64) -> NetworkSnapshot {
        var rx: [String: UInt64] = [:]
        var tx: [String: UInt64] = [:]
        readCounters(rx: &rx, tx: &tx)
        defer { previous = (rx, tx, now) }
        guard let previous, now > previous.time else {
            return NetworkSnapshot(receivedBytesPerSecond: 0, sentBytesPerSecond: 0, interfaces: [])
        }
        let elapsed = Double(now - previous.time) / 1e9
        var interfaces: [InterfaceThroughput] = []
        for (name, received) in rx {
            let sent = tx[name] ?? 0
            let inRate = previous.rx[name].flatMap { CounterRate.perSecond(previous: $0, current: received, elapsed: elapsed) } ?? 0
            let outRate = previous.tx[name].flatMap { CounterRate.perSecond(previous: $0, current: sent, elapsed: elapsed) } ?? 0
            interfaces.append(InterfaceThroughput(name: name, receivedBytesPerSecond: inRate, sentBytesPerSecond: outRate,
                                                  totalReceived: received, totalSent: sent))
        }
        interfaces.sort { $0.name < $1.name }
        return NetworkSnapshot(receivedBytesPerSecond: interfaces.reduce(0) { $0 + $1.receivedBytesPerSecond },
                               sentBytesPerSecond: interfaces.reduce(0) { $0 + $1.sentBytesPerSecond },
                               interfaces: interfaces.filter { $0.totalReceived > 0 || $0.totalSent > 0 })
    }

    private func readCounters(rx: inout [String: UInt64], tx: inout [String: UInt64]) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return }
        if buffer.count < length { buffer = [UInt8](repeating: 0, count: length + 2048) }
        let status = buffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &length, nil, 0) }
        guard status == 0 else { return }

        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let name = interfaceName(message.ifm_index)
                    if NetworkInterfaceFilter.includes(name) {
                        rx[name] = message.ifm_data.ifi_ibytes
                        tx[name] = message.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
    }

    private func interfaceName(_ index: UInt16) -> String {
        if let cached = names[index] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let name = if_indextoname(UInt32(index), &buffer).map { String(cString: $0) } ?? ""
        names[index] = name
        return name
    }
}
