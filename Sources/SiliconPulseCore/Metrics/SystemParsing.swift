import Foundation

/// Which network interfaces count toward system throughput.
public enum NetworkInterfaceFilter {
    /// Virtual interfaces whose traffic is already counted on a physical interface
    /// (tunnels, bridges) or never leaves the machine (loopback).
    public static let excludedPrefixes = ["lo", "utun", "ipsec", "gif", "stf", "bridge", "llw", "anpi", "pktap", "vmenet"]

    public static func includes(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return !excludedPrefixes.contains { name.hasPrefix($0) }
    }
}

/// Parsers for IOKit registry strings.
public enum IORegistryParsing {
    /// Parses `IOUserClientCreator`, e.g. `"pid 1234, ollama"`.
    public static func pid(fromUserClientCreator creator: String) -> Int32? {
        let trimmed = creator.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("pid ") else { return nil }
        let rest = trimmed.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        return Int32(digits)
    }

    /// Name part of `IOUserClientCreator`.
    public static func name(fromUserClientCreator creator: String) -> String? {
        guard let comma = creator.firstIndex(of: ",") else { return nil }
        let name = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Device-tree properties such as `cluster-type` are NUL-terminated byte strings.
    public static func string(fromDeviceTreeData data: [UInt8]) -> String {
        let bytes = data.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Device-tree integers are little-endian.
    public static func uint32(fromDeviceTreeData data: [UInt8]) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
    }

    public static func coreKind(fromClusterType value: String) -> CoreKind {
        switch value.uppercased() {
        case "P": return .performance
        case "E": return .efficiency
        default: return .unknown
        }
    }
}

/// Tracks per-process cumulative GPU time from IOKit user clients and turns it into time shares.
public struct GPUTimeTracker: Sendable {
    private var previous: [Int32: UInt64] = [:]
    private var previousTime: UInt64?

    public init() {}

    /// - Parameters:
    ///   - totals: cumulative GPU nanoseconds per PID.
    ///   - now: monotonic nanoseconds.
    /// - Returns: fraction of wall time each PID had GPU work running (can exceed 1 with concurrent queues).
    public mutating func update(totals: [Int32: UInt64], now: UInt64) -> [Int32: Double] {
        defer {
            previous = totals
            previousTime = now
        }
        guard let previousTime, now > previousTime else { return [:] }
        let elapsed = Double(now - previousTime)
        var shares: [Int32: Double] = [:]
        for (pid, total) in totals {
            guard let old = previous[pid], total >= old else { continue }
            shares[pid] = Double(total - old) / elapsed
        }
        return shares
    }
}
