import Foundation

/// The subset of `vm_statistics64` SiliconPulse uses, in pages.
public struct VMStatistics: Equatable, Sendable {
    public var pageSize: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var compressor: UInt64
    public var purgeable: UInt64
    public var external: UInt64
    public var `internal`: UInt64
    // Cumulative event counters
    public var swapins: UInt64
    public var swapouts: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64

    public init(pageSize: UInt64, free: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64,
                compressor: UInt64, purgeable: UInt64, external: UInt64, internal: UInt64,
                swapins: UInt64 = 0, swapouts: UInt64 = 0, compressions: UInt64 = 0, decompressions: UInt64 = 0) {
        self.pageSize = pageSize
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressor = compressor
        self.purgeable = purgeable
        self.external = external
        self.internal = `internal`
        self.swapins = swapins
        self.swapouts = swapouts
        self.compressions = compressions
        self.decompressions = decompressions
    }
}

public enum MemoryCalculator {
    /// Builds a memory snapshot using the same breakdown as Activity Monitor:
    /// used = app (internal − purgeable) + wired + compressed;
    /// cached files = external + purgeable.
    public static func snapshot(vm: VMStatistics, totalBytes: UInt64, swapUsed: UInt64, swapTotal: UInt64,
                                pressure: MemoryPressure, kernelFreeLevel: Int?,
                                previous: VMStatistics? = nil, elapsedSeconds: Double? = nil) -> MemorySnapshot {
        let page = vm.pageSize
        let appPages = vm.internal > vm.purgeable ? vm.internal - vm.purgeable : 0
        let app = appPages * page
        let wired = vm.wired * page
        let compressed = vm.compressor * page
        let used = min(totalBytes, app + wired + compressed)
        let cached = (vm.external + vm.purgeable) * page
        let free = vm.free * page

        var snapshot = MemorySnapshot(total: totalBytes, used: used, app: app, wired: wired, compressed: compressed,
                                      cachedFiles: cached, free: free, swapUsed: swapUsed, swapTotal: swapTotal,
                                      pressure: pressure, kernelFreeLevel: kernelFreeLevel)
        if let previous, let elapsedSeconds, elapsedSeconds > 0 {
            snapshot.swapInsPerSecond = CounterRate.perSecond(previous: previous.swapins, current: vm.swapins, elapsed: elapsedSeconds)
            snapshot.swapOutsPerSecond = CounterRate.perSecond(previous: previous.swapouts, current: vm.swapouts, elapsed: elapsedSeconds)
            snapshot.compressionsPerSecond = CounterRate.perSecond(previous: previous.compressions, current: vm.compressions, elapsed: elapsedSeconds)
            snapshot.decompressionsPerSecond = CounterRate.perSecond(previous: previous.decompressions, current: vm.decompressions, elapsed: elapsedSeconds)
        }
        return snapshot
    }
}

/// Rates from cumulative counters.
public enum CounterRate {
    /// Per-second rate between two counter readings. Nil if the counter reset (went backwards) or no time elapsed.
    public static func perSecond(previous: UInt64, current: UInt64, elapsed: Double) -> Double? {
        guard elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }

    /// Sum of per-key rates. Keys that are new or reset since the previous reading contribute nothing,
    /// so a disk being attached never shows up as a burst of its lifetime total.
    public static func summedPerSecond<Key: Hashable>(previous: [Key: UInt64], current: [Key: UInt64], elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        var total = 0.0
        for (key, value) in current {
            if let old = previous[key], value >= old {
                total += Double(value - old)
            }
        }
        return total / elapsed
    }
}
