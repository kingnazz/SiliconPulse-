import Foundation

public enum HistoryWindow: String, CaseIterable, Identifiable, Sendable {
    case oneMinute, fiveMinutes, thirtyMinutes

    public var id: String { rawValue }

    public var duration: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .thirtyMinutes: return 1800
        }
    }

    public var label: String {
        switch self {
        case .oneMinute: return "60s"
        case .fiveMinutes: return "5m"
        case .thirtyMinutes: return "30m"
        }
    }

    /// Points kept per window. Bucket width = duration / pointsPerWindow.
    public static let pointsPerWindow = 120

    public var bucketWidth: TimeInterval { duration / Double(Self.pointsPerWindow) }
}

public struct HistoryPoint: Equatable, Sendable {
    /// Seconds since the reference date, start of the bucket.
    public var time: TimeInterval
    public var average: Double
    public var maximum: Double

    public init(time: TimeInterval, average: Double, maximum: Double) {
        self.time = time
        self.average = average
        self.maximum = maximum
    }
}

/// A single metric's history at three resolutions (60 s, 5 min, 30 min), each a bounded ring buffer.
/// Samples are averaged into fixed-width buckets, so memory is constant regardless of sample rate or uptime.
public struct HistorySeries: Sendable {
    private struct Tier: Sendable {
        let window: HistoryWindow
        var points: RingBuffer<HistoryPoint>
        var bucket: Int64?
        var sum = 0.0
        var count = 0
        var maximum = -Double.infinity

        init(window: HistoryWindow) {
            self.window = window
            points = RingBuffer(capacity: HistoryWindow.pointsPerWindow)
        }

        mutating func add(_ value: Double, at time: TimeInterval) {
            let index = Int64((time / window.bucketWidth).rounded(.down))
            if let bucket, index != bucket {
                if index < bucket { return }  // clock went backwards: drop the sample
                flush()
            }
            bucket = index
            sum += value
            count += 1
            maximum = max(maximum, value)
        }

        mutating func flush() {
            guard let bucket, count > 0 else { return }
            points.append(HistoryPoint(time: Double(bucket) * window.bucketWidth, average: sum / Double(count), maximum: maximum))
            sum = 0
            count = 0
            maximum = -.infinity
        }

        /// Points inside the window, measured back from the newest point. With sparse sampling (1 Hz into
        /// 0.5 s buckets) the ring can hold more than the window's duration, so it is trimmed by time.
        func snapshot() -> [HistoryPoint] {
            var result = points.elements
            if let bucket, count > 0 {
                result.append(HistoryPoint(time: Double(bucket) * window.bucketWidth, average: sum / Double(count), maximum: maximum))
            }
            guard let newest = result.last?.time else { return result }
            let cutoff = newest - window.duration
            if let firstInside = result.firstIndex(where: { $0.time > cutoff }), firstInside > 0 {
                result.removeFirst(firstInside)
            }
            return result
        }
    }

    private var tiers: [Tier] = HistoryWindow.allCases.map(Tier.init(window:))
    public private(set) var latest: Double?

    public init() {}

    public mutating func append(_ value: Double, at date: Date) {
        guard value.isFinite else { return }
        let time = date.timeIntervalSinceReferenceDate
        for index in tiers.indices { tiers[index].add(value, at: time) }
        latest = value
    }

    /// Points for a window, oldest first, including the bucket currently filling.
    public func points(for window: HistoryWindow) -> [HistoryPoint] {
        tiers.first { $0.window == window }?.snapshot() ?? []
    }

    public func maximum(in window: HistoryWindow) -> Double? {
        points(for: window).map(\.maximum).max()
    }

    public func average(in window: HistoryWindow) -> Double? {
        let p = points(for: window)
        guard !p.isEmpty else { return nil }
        return p.reduce(0) { $0 + $1.average } / Double(p.count)
    }

    /// Upper bound on stored points, used by tests to prove history is bounded.
    public var storedPointCount: Int { tiers.reduce(0) { $0 + $1.points.count } }
}

public enum HistoryMetric: String, CaseIterable, Hashable, Sendable {
    case cpu, gpu, memoryUsed, memoryCompressed, swapUsed, diskRead, diskWrite, networkReceived, networkSent

    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memoryUsed: return "Memory used"
        case .memoryCompressed: return "Compressed"
        case .swapUsed: return "Swap used"
        case .diskRead: return "Disk read"
        case .diskWrite: return "Disk write"
        case .networkReceived: return "Download"
        case .networkSent: return "Upload"
        }
    }
}

/// System-wide history for all charted metrics.
public struct MetricHistory: Sendable {
    private var series: [HistoryMetric: HistorySeries] = [:]

    public init() {
        for metric in HistoryMetric.allCases { series[metric] = HistorySeries() }
    }

    public mutating func record(_ snapshot: SystemSnapshot) {
        let t = snapshot.timestamp
        // Stale (carried-over) values are not recorded: a gap is more honest than a repeated value.
        if !snapshot.stale.contains(.cpu) { series[.cpu]?.append(snapshot.cpu.usage.total, at: t) }
        if let gpu = snapshot.gpu.deviceUtilization { series[.gpu]?.append(gpu, at: t) }
        if !snapshot.stale.contains(.memory) {
            series[.memoryUsed]?.append(Double(snapshot.memory.used), at: t)
            series[.memoryCompressed]?.append(Double(snapshot.memory.compressed), at: t)
            series[.swapUsed]?.append(Double(snapshot.memory.swapUsed), at: t)
        }
        series[.diskRead]?.append(snapshot.disk.readBytesPerSecond, at: t)
        series[.diskWrite]?.append(snapshot.disk.writeBytesPerSecond, at: t)
        series[.networkReceived]?.append(snapshot.network.receivedBytesPerSecond, at: t)
        series[.networkSent]?.append(snapshot.network.sentBytesPerSecond, at: t)
    }

    public subscript(metric: HistoryMetric) -> HistorySeries { series[metric] ?? HistorySeries() }

    public var storedPointCount: Int { series.values.reduce(0) { $0 + $1.storedPointCount } }
}
