import XCTest
@testable import SiliconPulseCore

final class HistoryTests: XCTestCase {
    func testRingBufferOverwritesOldest() {
        var ring = RingBuffer<Int>(capacity: 3)
        XCTAssertTrue(ring.isEmpty)
        for i in 1...5 { ring.append(i) }
        XCTAssertEqual(ring.elements, [3, 4, 5])
        XCTAssertEqual(ring.count, 3)
        XCTAssertTrue(ring.isFull)
        XCTAssertEqual(ring.first, 3)
        XCTAssertEqual(ring.last, 5)
        XCTAssertEqual(ring[0], 3)
        XCTAssertEqual(ring[2], 5)
    }

    func testRingBufferPartialAndReset() {
        var ring = RingBuffer<String>(capacity: 4)
        ring.append("a")
        ring.append("b")
        XCTAssertEqual(ring.elements, ["a", "b"])
        XCTAssertEqual(ring.last, "b")
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertNil(ring.last)
        ring.append("c")
        XCTAssertEqual(ring.elements, ["c"])
    }

    func testRingBufferIteratesInOrderAfterManyWraps() {
        var ring = RingBuffer<Int>(capacity: 7)
        for i in 0..<1_003 { ring.append(i) }
        XCTAssertEqual(Array(ring), Array(996..<1_003))
    }

    func testHistoryBucketsAverageAndMax() {
        var series = HistorySeries()
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        // 60 s window has 0.5 s buckets: both samples land in the same bucket.
        series.append(10, at: start)
        series.append(30, at: start.addingTimeInterval(0.1))
        let points = series.points(for: .oneMinute)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].average, 20)
        XCTAssertEqual(points[0].maximum, 30)
        XCTAssertEqual(series.latest, 30)
    }

    func testHistoryDownsamplesLongerWindows() {
        var series = HistorySeries()
        let start = Date(timeIntervalSinceReferenceDate: 3_000_000)
        for i in 0..<300 { series.append(Double(i), at: start.addingTimeInterval(Double(i))) }  // 5 min at 1 Hz
        // 30-minute window uses 15 s buckets: 300 s spans 20 or 21 buckets.
        XCTAssertTrue((20...21).contains(series.points(for: .thirtyMinutes).count))
        // 5-minute window uses 2.5 s buckets: 120 points.
        XCTAssertTrue((119...121).contains(series.points(for: .fiveMinutes).count))
        // 60 s window at 1 Hz: one point per second, trimmed to the last 60 s even though the ring holds 120.
        let minute = series.points(for: .oneMinute)
        XCTAssertTrue((59...61).contains(minute.count), "\(minute.count)")
        XCTAssertLessThanOrEqual(minute.last!.time - minute.first!.time, 60)
        XCTAssertEqual(minute.last!.average, 299)
        XCTAssertEqual(series.maximum(in: .fiveMinutes), 299)
    }

    func testHistoryMemoryIsBoundedIndefinitely() {
        var history = MetricHistory()
        var snapshot = SystemSnapshot.empty
        let start = Date(timeIntervalSinceReferenceDate: 5_000_000)
        // Two hours at 2 Hz.
        for i in 0..<14_400 {
            snapshot.timestamp = start.addingTimeInterval(Double(i) * 0.5)
            snapshot.cpu.usage = CPUUsage(user: Double(i % 100) / 100, system: 0, nice: 0, idle: 0)
            snapshot.gpu.deviceUtilization = 0.5
            history.record(snapshot)
        }
        let perSeriesBound = HistoryWindow.allCases.count * HistoryWindow.pointsPerWindow
        XCTAssertLessThanOrEqual(history.storedPointCount, HistoryMetric.allCases.count * perSeriesBound)
        XCTAssertTrue((HistoryWindow.pointsPerWindow...HistoryWindow.pointsPerWindow + 1).contains(history[.cpu].points(for: .thirtyMinutes).count))
        // Windows cover their durations.
        let minute = history[.cpu].points(for: .oneMinute)
        XCTAssertLessThanOrEqual(minute.last!.time - minute.first!.time, 60)
    }

    func testHistoryIgnoresNonFiniteAndBackwardsClock() {
        var series = HistorySeries()
        let t = Date(timeIntervalSinceReferenceDate: 9_000_000)
        series.append(.nan, at: t)
        series.append(.infinity, at: t)
        XCTAssertTrue(series.points(for: .oneMinute).isEmpty)
        series.append(1, at: t)
        series.append(2, at: t.addingTimeInterval(5))
        series.append(100, at: t.addingTimeInterval(1))  // clock went back
        XCTAssertEqual(series.points(for: .oneMinute).map(\.average), [1, 2])
    }

    func testGPUHistorySkippedWhenUnavailable() {
        var history = MetricHistory()
        var snapshot = SystemSnapshot.empty
        snapshot.timestamp = Date(timeIntervalSinceReferenceDate: 100)
        history.record(snapshot)
        XCTAssertTrue(history[.gpu].points(for: .oneMinute).isEmpty, "unavailable GPU must not be charted as 0%")
        XCTAssertEqual(history[.cpu].points(for: .oneMinute).count, 1)
    }

    func testWindowGeometry() {
        XCTAssertEqual(HistoryWindow.oneMinute.bucketWidth, 0.5)
        XCTAssertEqual(HistoryWindow.fiveMinutes.bucketWidth, 2.5)
        XCTAssertEqual(HistoryWindow.thirtyMinutes.bucketWidth, 15)
    }
}


final class UnavailableMetricsTests: XCTestCase {
    private func memory(_ used: UInt64) -> MemorySnapshot {
        MemorySnapshot(total: 16 << 30, used: used, app: used, wired: 0, compressed: 0, cachedFiles: 0, free: 0,
                       swapUsed: 0, swapTotal: 0, pressure: .normal)
    }

    func testFailedCollectorKeepsPreviousValueAndMarksStale() {
        var previous = SystemSnapshot.empty
        previous.cpu.usage = CPUUsage(user: 0.4, system: 0.1, nice: 0, idle: 0.5)
        previous.memory = memory(8 << 30)
        let snapshot = SystemSnapshot.assemble(previous: previous, timestamp: Date(timeIntervalSinceReferenceDate: 50),
                                               cpu: nil, gpu: .unavailable, memory: nil, disk: .empty, network: .empty,
                                               thermal: .normal)
        XCTAssertEqual(snapshot.cpu.usage.total, 0.5, accuracy: 1e-9, "UI keeps the last value instead of blanking")
        XCTAssertEqual(snapshot.memory.used, 8 << 30)
        XCTAssertEqual(snapshot.stale, [.cpu, .memory])
        XCTAssertEqual(snapshot.thermal.level, .normal)
    }

    func testRecoveredCollectorClearsStale() {
        var cpu = CPUSnapshot.empty
        cpu.usage = CPUUsage(user: 0.2, system: 0, nice: 0, idle: 0.8)
        let snapshot = SystemSnapshot.assemble(previous: .empty, timestamp: Date(), cpu: cpu, gpu: .unavailable,
                                               memory: memory(1 << 30), disk: .empty, network: .empty, thermal: .serious)
        XCTAssertTrue(snapshot.stale.isEmpty)
        XCTAssertEqual(snapshot.thermal.level, .serious)
    }

    func testStaleValuesAreNotRecordedInHistory() {
        var history = MetricHistory()
        var previous = SystemSnapshot.empty
        previous.memory = memory(4 << 30)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var good = SystemSnapshot.assemble(previous: previous, timestamp: t0, cpu: .empty, gpu: .unavailable,
                                           memory: memory(4 << 30), disk: .empty, network: .empty, thermal: .normal)
        history.record(good)
        let failed = SystemSnapshot.assemble(previous: good, timestamp: t0.addingTimeInterval(5), cpu: nil, gpu: .unavailable,
                                             memory: nil, disk: .empty, network: .empty, thermal: .normal)
        history.record(failed)
        good.timestamp = t0.addingTimeInterval(10)
        history.record(good)
        XCTAssertEqual(history[.cpu].points(for: .oneMinute).count, 2, "the failed pass leaves a gap")
        XCTAssertEqual(history[.memoryUsed].points(for: .oneMinute).count, 2)
        XCTAssertEqual(history[.diskRead].points(for: .oneMinute).count, 3, "collectors that worked are still recorded")
    }
}
