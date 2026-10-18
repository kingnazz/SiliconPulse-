import Darwin
import Dispatch
import Foundation
import SiliconPulseCore

/// Unified memory from `host_statistics64`, swap from `vm.swapusage`, pressure from memorystatus.
final class MemoryCollector {
    private let host = mach_host_self()
    let totalBytes: UInt64
    private var previous: (vm: VMStatistics, time: UInt64)?
    private let pressureSource: DispatchSourceMemoryPressure
    private let lock = NSLock()
    private var lastPressureEvent: MemoryPressure = .unknown

    init() {
        totalBytes = UInt64(max(0, Sysctl.int("hw.memsize") ?? 0))
        pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                                 queue: DispatchQueue.global(qos: .utility))
        pressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.pressureSource.data
            let level: MemoryPressure = event.contains(.critical) ? .critical : (event.contains(.warning) ? .warning : .normal)
            self.lock.withLock { self.lastPressureEvent = level }
        }
        pressureSource.resume()
    }

    deinit {
        pressureSource.cancel()
    }

    func sample(now: UInt64) -> MemorySnapshot? {
        guard let vm = readVM() else { return nil }
        let swap = readSwap()
        let pressure: MemoryPressure
        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level"), MemoryPressure(kernelLevel: Int32(level)) != .unknown {
            pressure = MemoryPressure(kernelLevel: Int32(level))
        } else {
            pressure = lock.withLock { lastPressureEvent }
        }
        let freeLevel = Sysctl.int("kern.memorystatus_level").flatMap { (0...100).contains($0) ? $0 : nil }
        let elapsed = previous.map { Double(now &- $0.time) / 1e9 }
        let snapshot = MemoryCalculator.snapshot(vm: vm, totalBytes: totalBytes, swapUsed: swap.used, swapTotal: swap.total,
                                                 pressure: pressure, kernelFreeLevel: freeLevel,
                                                 previous: previous?.vm, elapsedSeconds: elapsed)
        previous = (vm, now)
        return snapshot
    }

    private func readVM() -> VMStatistics? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMStatistics(pageSize: UInt64(vm_kernel_page_size),
                            free: UInt64(stats.free_count), active: UInt64(stats.active_count),
                            inactive: UInt64(stats.inactive_count), speculative: UInt64(stats.speculative_count),
                            wired: UInt64(stats.wire_count), compressor: UInt64(stats.compressor_page_count),
                            purgeable: UInt64(stats.purgeable_count), external: UInt64(stats.external_page_count),
                            internal: UInt64(stats.internal_page_count),
                            swapins: UInt64(stats.swapins), swapouts: UInt64(stats.swapouts),
                            compressions: UInt64(stats.compressions), decompressions: UInt64(stats.decompressions))
    }

    private func readSwap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (UInt64(usage.xsu_used), UInt64(usage.xsu_total))
    }
}
