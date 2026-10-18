import Foundation

/// Raw cumulative tick counters for one logical CPU, as reported by `host_processor_info`.
/// The kernel keeps them as 32-bit values, so they wrap around.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum CPUCalculator {
    /// Utilization between two tick samples. Wrap-safe. Returns nil when no time elapsed.
    public static func usage(from previous: CPUTicks, to current: CPUTicks) -> CPUUsage? {
        let user = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let idle = Double(current.idle &- previous.idle)
        let nice = Double(current.nice &- previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return CPUUsage(user: user / total, system: system / total, nice: nice / total, idle: idle / total)
    }

    /// Per-core and aggregate utilization. When the core count changes between samples (it should not)
    /// the result is nil so the caller can resynchronise.
    public static func usage(from previous: [CPUTicks], to current: [CPUTicks]) -> (total: CPUUsage, perCore: [CPUUsage])? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var perCore: [CPUUsage] = []
        perCore.reserveCapacity(current.count)
        var sums = (user: 0.0, system: 0.0, idle: 0.0, nice: 0.0)
        for index in current.indices {
            let p = previous[index], c = current[index]
            let user = Double(c.user &- p.user), system = Double(c.system &- p.system)
            let idle = Double(c.idle &- p.idle), nice = Double(c.nice &- p.nice)
            sums.user += user; sums.system += system; sums.idle += idle; sums.nice += nice
            let total = user + system + idle + nice
            perCore.append(total > 0
                ? CPUUsage(user: user / total, system: system / total, nice: nice / total, idle: idle / total)
                : .zero)
        }
        let total = sums.user + sums.system + sums.idle + sums.nice
        guard total > 0 else { return nil }
        let aggregate = CPUUsage(user: sums.user / total, system: sums.system / total, nice: sums.nice / total, idle: sums.idle / total)
        return (aggregate, perCore)
    }

    /// Validates device-tree core kinds against the sysctl performance-level counts.
    /// Returns nil (unknown layout) rather than guessing when they disagree.
    public static func validatedCoreKinds(_ kinds: [CoreKind], logicalCores: Int, performanceCores: Int?, efficiencyCores: Int?) -> [CoreKind]? {
        guard kinds.count == logicalCores, logicalCores > 0, !kinds.contains(.unknown) else { return nil }
        let p = kinds.filter { $0 == .performance }.count
        let e = kinds.filter { $0 == .efficiency }.count
        if let performanceCores, performanceCores != p { return nil }
        if let efficiencyCores, efficiencyCores != e { return nil }
        return kinds
    }
}

/// Converts per-process cumulative CPU time into a utilization percentage.
public enum ProcessCPUCalculator {
    /// - Returns: percentage where 100 means one fully busy core, or nil if the counter went backwards
    ///   (PID reuse) or no time elapsed.
    public static func percent(previousCPUNanoseconds: UInt64, currentCPUNanoseconds: UInt64, elapsedNanoseconds: UInt64) -> Double? {
        guard elapsedNanoseconds > 0, currentCPUNanoseconds >= previousCPUNanoseconds else { return nil }
        return Double(currentCPUNanoseconds - previousCPUNanoseconds) / Double(elapsedNanoseconds) * 100
    }

    /// Converts Mach absolute time units to nanoseconds using a `mach_timebase_info` ratio.
    /// On Apple Silicon the ratio is 125/3; on Intel it is 1/1.
    public static func nanoseconds(machUnits: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom != 0 else { return machUnits }
        if numer == denom { return machUnits }
        // 128-bit intermediate so large tick counts cannot overflow; saturates if the result does not fit.
        let d = UInt64(denom)
        let product = machUnits.multipliedFullWidth(by: UInt64(numer))
        guard product.high < d else { return .max }
        return d.dividingFullWidth(product).quotient
    }
}
