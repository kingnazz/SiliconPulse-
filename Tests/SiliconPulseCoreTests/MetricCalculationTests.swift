import XCTest
@testable import SiliconPulseCore

final class MetricCalculationTests: XCTestCase {
    // MARK: CPU

    func testCPUUsageFromTickDelta() throws {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let b = CPUTicks(user: 160, system: 70, idle: 900, nice: 20)
        let usage = try XCTUnwrap(CPUCalculator.usage(from: a, to: b))
        XCTAssertEqual(usage.user, 0.3, accuracy: 1e-9)
        XCTAssertEqual(usage.system, 0.1, accuracy: 1e-9)
        XCTAssertEqual(usage.nice, 0.1, accuracy: 1e-9)
        XCTAssertEqual(usage.idle, 0.5, accuracy: 1e-9)
        XCTAssertEqual(usage.total, 0.5, accuracy: 1e-9)
    }

    func testCPUUsageHandlesCounterWraparound() throws {
        let a = CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29, nice: 0)
        let b = CPUTicks(user: 10, system: 0, idle: 50, nice: 0)  // +20 user, +80 idle
        let usage = try XCTUnwrap(CPUCalculator.usage(from: a, to: b))
        XCTAssertEqual(usage.user, 0.2, accuracy: 1e-9)
        XCTAssertEqual(usage.idle, 0.8, accuracy: 1e-9)
    }

    func testCPUUsageNilWhenNoTimeElapsed() {
        let a = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        XCTAssertNil(CPUCalculator.usage(from: a, to: a))
    }

    func testAggregateAndPerCoreUsage() throws {
        let previous = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [CPUTicks(user: 100, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let result = try XCTUnwrap(CPUCalculator.usage(from: previous, to: current))
        XCTAssertEqual(result.total.total, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.perCore[0].total, 1, accuracy: 1e-9)
        XCTAssertEqual(result.perCore[1].total, 0, accuracy: 1e-9)
    }

    func testCoreCountChangeResynchronises() {
        XCTAssertNil(CPUCalculator.usage(from: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
                                         to: [CPUTicks(user: 1, system: 0, idle: 0, nice: 0), CPUTicks(user: 1, system: 0, idle: 0, nice: 0)]))
    }

    func testCoreKindsValidatedAgainstSysctl() {
        let kinds: [CoreKind] = [.efficiency, .efficiency, .performance, .performance, .performance, .performance]
        XCTAssertEqual(CPUCalculator.validatedCoreKinds(kinds, logicalCores: 6, performanceCores: 4, efficiencyCores: 2), kinds)
        // Disagreement with sysctl: refuse to guess.
        XCTAssertNil(CPUCalculator.validatedCoreKinds(kinds, logicalCores: 6, performanceCores: 3, efficiencyCores: 3))
        XCTAssertNil(CPUCalculator.validatedCoreKinds(kinds, logicalCores: 8, performanceCores: 4, efficiencyCores: 2))
        XCTAssertNil(CPUCalculator.validatedCoreKinds([.unknown, .performance], logicalCores: 2, performanceCores: nil, efficiencyCores: nil))
    }

    func testClusterUsageOnlyWithKnownKinds() {
        var snapshot = CPUSnapshot.empty
        snapshot.cores = [
            CoreUsage(id: 0, kind: .efficiency, usage: CPUUsage(user: 0.2, system: 0, nice: 0, idle: 0.8)),
            CoreUsage(id: 1, kind: .performance, usage: CPUUsage(user: 0.8, system: 0.2, nice: 0, idle: 0)),
        ]
        XCTAssertEqual(snapshot.clusterUsage(.efficiency)!, 0.2, accuracy: 1e-9)
        XCTAssertEqual(snapshot.clusterUsage(.performance)!, 1, accuracy: 1e-9)
        XCTAssertNil(snapshot.clusterUsage(.unknown))
    }

    func testProcessCPUPercent() {
        // 0.5 s of CPU over 1 s of wall time = 50% of one core.
        XCTAssertEqual(ProcessCPUCalculator.percent(previousCPUNanoseconds: 1_000_000_000, currentCPUNanoseconds: 1_500_000_000,
                                                    elapsedNanoseconds: 1_000_000_000)!, 50, accuracy: 1e-9)
        // Multi-threaded: 3 s of CPU in 1 s.
        XCTAssertEqual(ProcessCPUCalculator.percent(previousCPUNanoseconds: 0, currentCPUNanoseconds: 3_000_000_000,
                                                    elapsedNanoseconds: 1_000_000_000)!, 300, accuracy: 1e-9)
        // PID reuse: counter went backwards.
        XCTAssertNil(ProcessCPUCalculator.percent(previousCPUNanoseconds: 10, currentCPUNanoseconds: 5, elapsedNanoseconds: 1))
        XCTAssertNil(ProcessCPUCalculator.percent(previousCPUNanoseconds: 0, currentCPUNanoseconds: 5, elapsedNanoseconds: 0))
    }

    func testMachTimebaseConversion() {
        // Apple Silicon: 24 MHz ticks, numer/denom = 125/3.
        XCTAssertEqual(ProcessCPUCalculator.nanoseconds(machUnits: 24_000_000, numer: 125, denom: 3), 1_000_000_000)
        XCTAssertEqual(ProcessCPUCalculator.nanoseconds(machUnits: 12345, numer: 1, denom: 1), 12345)
        // Large values must not overflow.
        let big: UInt64 = 1 << 56
        XCTAssertEqual(ProcessCPUCalculator.nanoseconds(machUnits: big * 3, numer: 125, denom: 3), big * 125)
        XCTAssertEqual(ProcessCPUCalculator.nanoseconds(machUnits: .max, numer: 125, denom: 3), .max, "saturates")
    }

    // MARK: Memory

    func testMemoryBreakdownMatchesActivityMonitorFormula() {
        let page: UInt64 = 16_384
        let vm = VMStatistics(pageSize: page, free: 10_000, active: 200_000, inactive: 150_000, speculative: 5_000,
                              wired: 100_000, compressor: 50_000, purgeable: 20_000, external: 80_000, internal: 300_000)
        let total: UInt64 = 32 * 1_073_741_824
        let m = MemoryCalculator.snapshot(vm: vm, totalBytes: total, swapUsed: 0, swapTotal: 0, pressure: .normal, kernelFreeLevel: 60)
        XCTAssertEqual(m.app, (300_000 - 20_000) * page)
        XCTAssertEqual(m.wired, 100_000 * page)
        XCTAssertEqual(m.compressed, 50_000 * page)
        XCTAssertEqual(m.used, m.app + m.wired + m.compressed)
        XCTAssertEqual(m.cachedFiles, (80_000 + 20_000) * page)
        XCTAssertEqual(m.free, 10_000 * page)
        XCTAssertEqual(m.available, total - m.used)
        XCTAssertEqual(m.estimatedHeadroom, m.available - total / 10)
        XCTAssertNil(m.swapOutsPerSecond, "rates need two samples")
    }

    func testMemoryUsedNeverExceedsInstalled() {
        let vm = VMStatistics(pageSize: 4096, free: 0, active: 0, inactive: 0, speculative: 0, wired: 1_000_000,
                              compressor: 1_000_000, purgeable: 0, external: 0, internal: 1_000_000)
        let m = MemoryCalculator.snapshot(vm: vm, totalBytes: 1_000, swapUsed: 0, swapTotal: 0, pressure: .unknown, kernelFreeLevel: nil)
        XCTAssertEqual(m.used, 1_000)
        XCTAssertEqual(m.available, 0)
        XCTAssertEqual(m.estimatedHeadroom, 0)
    }

    func testSwapAndCompressionRates() {
        let base = VMStatistics(pageSize: 16_384, free: 0, active: 0, inactive: 0, speculative: 0, wired: 0, compressor: 0,
                                purgeable: 0, external: 0, internal: 0, swapins: 100, swapouts: 200, compressions: 1_000, decompressions: 500)
        var next = base
        next.swapouts = 260
        next.compressions = 1_400
        let m = MemoryCalculator.snapshot(vm: next, totalBytes: 1 << 34, swapUsed: 1 << 20, swapTotal: 1 << 30, pressure: .warning,
                                          kernelFreeLevel: 20, previous: base, elapsedSeconds: 2)
        XCTAssertEqual(m.swapInsPerSecond, 0)
        XCTAssertEqual(m.swapOutsPerSecond, 30)
        XCTAssertEqual(m.compressionsPerSecond, 200)
        XCTAssertTrue(m.isSwappingOut)
    }

    func testMemoryPressureMapping() {
        XCTAssertEqual(MemoryPressure(kernelLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(kernelLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(kernelLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(kernelLevel: 0), .unknown)
        XCTAssertEqual(MemoryPressure(kernelLevel: -1), .unknown)
    }

    func testThermalMapping() {
        XCTAssertEqual(ThermalLevel(processInfoRawValue: 0), .normal)
        XCTAssertEqual(ThermalLevel(processInfoRawValue: 1), .elevated)
        XCTAssertEqual(ThermalLevel(processInfoRawValue: 2), .serious)
        XCTAssertEqual(ThermalLevel(processInfoRawValue: 3), .critical)
        XCTAssertEqual(ThermalLevel(processInfoRawValue: 9), .unknown)
        XCTAssertTrue(ThermalLevel.serious.isConstrained)
        XCTAssertFalse(ThermalLevel.elevated.isConstrained)
    }

    // MARK: Counters

    func testCounterRateHandlesReset() {
        XCTAssertEqual(CounterRate.perSecond(previous: 1_000, current: 3_000, elapsed: 2), 1_000)
        XCTAssertNil(CounterRate.perSecond(previous: 3_000, current: 1_000, elapsed: 2))
        XCTAssertNil(CounterRate.perSecond(previous: 0, current: 1_000, elapsed: 0))
    }

    func testSummedRatesIgnoreNewAndResetKeys() {
        let previous: [String: UInt64] = ["disk0": 1_000, "disk1": 5_000]
        // disk1 reset, disk2 newly attached with a large lifetime total.
        let current: [String: UInt64] = ["disk0": 3_000, "disk1": 100, "disk2": 999_999_999]
        XCTAssertEqual(CounterRate.summedPerSecond(previous: previous, current: current, elapsed: 2), 1_000)
    }

    func testNetworkInterfaceFilter() {
        for name in ["en0", "en1", "awdl0", "en8"] { XCTAssertTrue(NetworkInterfaceFilter.includes(name), name) }
        for name in ["lo0", "utun3", "ipsec0", "gif0", "stf0", "bridge0", "llw0", "anpi1", ""] {
            XCTAssertFalse(NetworkInterfaceFilter.includes(name), name)
        }
    }

    // MARK: IOKit parsing

    func testUserClientCreatorParsing() {
        XCTAssertEqual(IORegistryParsing.pid(fromUserClientCreator: "pid 1234, ollama"), 1234)
        XCTAssertEqual(IORegistryParsing.name(fromUserClientCreator: "pid 1234, ollama"), "ollama")
        XCTAssertEqual(IORegistryParsing.pid(fromUserClientCreator: "pid 77, LM Studio Helper"), 77)
        XCTAssertNil(IORegistryParsing.pid(fromUserClientCreator: "kernel"))
        XCTAssertNil(IORegistryParsing.pid(fromUserClientCreator: "pid , x"))
    }

    func testDeviceTreeParsing() {
        XCTAssertEqual(IORegistryParsing.string(fromDeviceTreeData: [0x50, 0x00]), "P")
        XCTAssertEqual(IORegistryParsing.coreKind(fromClusterType: "E"), .efficiency)
        XCTAssertEqual(IORegistryParsing.coreKind(fromClusterType: "P"), .performance)
        XCTAssertEqual(IORegistryParsing.coreKind(fromClusterType: "X"), .unknown)
        XCTAssertEqual(IORegistryParsing.uint32(fromDeviceTreeData: [0x05, 0, 0, 0]), 5)
        XCTAssertNil(IORegistryParsing.uint32(fromDeviceTreeData: [1, 2]))
    }

    func testGPUTimeTrackerShares() {
        var tracker = GPUTimeTracker()
        XCTAssertTrue(tracker.update(totals: [10: 0, 20: 0], now: 1_000_000_000).isEmpty, "first sample has no baseline")
        let shares = tracker.update(totals: [10: 500_000_000, 20: 100_000_000, 30: 9_999], now: 2_000_000_000)
        XCTAssertEqual(shares[10]!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(shares[20]!, 0.1, accuracy: 1e-9)
        XCTAssertNil(shares[30], "new client has no baseline")
        // Counter reset (process restarted with the same PID) is skipped.
        let after = tracker.update(totals: [10: 1, 20: 200_000_000], now: 3_000_000_000)
        XCTAssertNil(after[10])
        XCTAssertEqual(after[20]!, 0.1, accuracy: 1e-9)
    }

    // MARK: Prometheus & dates

    func testPrometheusParsing() {
        let metrics = PrometheusParser.parse(Fixtures.llamaMetrics(tokens: 1234, seconds: 30.5, processing: 1))
        XCTAssertEqual(metrics["llamacpp:tokens_predicted_total"], 1234)
        XCTAssertEqual(metrics["llamacpp:tokens_predicted_seconds_total"], 30.5)
        XCTAssertEqual(metrics["llamacpp:requests_processing"], 1)
        XCTAssertEqual(metrics["llamacpp:predicted_tokens_seconds"], 37.5, "labels are stripped")
        XCTAssertNil(metrics["# HELP"])
        XCTAssertTrue(PrometheusParser.parse("garbage\n{}\n").isEmpty)
    }

    func testRFC3339WithNanoseconds() throws {
        let date = try XCTUnwrap(RFC3339.parse("2026-10-18T06:05:00.123456789-07:00"))
        let reference = try XCTUnwrap(RFC3339.parse("2026-10-18T13:05:00Z"))
        XCTAssertEqual(date.timeIntervalSince(reference), 0.123456789, accuracy: 1e-6)
        XCTAssertNotNil(RFC3339.parse("2026-10-18T06:05:00Z"))
        XCTAssertNil(RFC3339.parse("not a date"))
    }
}
