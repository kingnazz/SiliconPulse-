import XCTest
@testable import SiliconPulseCore

final class QualityAndFormattingTests: XCTestCase {
    // MARK: Quality classification

    func testQualityOrdering() {
        XCTAssertLessThan(MetricQuality.exact, .systemReported)
        XCTAssertLessThan(MetricQuality.calculated, .estimated)
        XCTAssertEqual(MetricQuality.weakest(.calculated, .estimated), .estimated)
        XCTAssertEqual(MetricQuality.weakest(.exact, .systemReported), .systemReported)
        XCTAssertEqual(MetricQuality.allCases.count, 5)
    }

    func testMeasuredNilIsAlwaysUnavailable() {
        let m = Measured<Double>(nil, quality: .calculated, source: "x")
        XCTAssertEqual(m.quality, .unavailable)
        XCTAssertFalse(m.isAvailable)
        let ok = Measured(4.2, quality: .estimated, source: "y")
        XCTAssertEqual(ok.quality, .estimated)
        XCTAssertTrue(ok.isAvailable)
    }

    func testCatalogIsCompleteAndConsistent() {
        let ids = MetricCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "metric ids must be unique")
        for info in MetricCatalog.all {
            XCTAssertFalse(info.source.isEmpty, info.id)
            XCTAssertFalse(info.title.isEmpty, info.id)
            if info.quality == .unavailable {
                XCTAssertNotNil(info.note, "unavailable metrics must explain why: \(info.id)")
            }
            XCTAssertTrue(info.tooltip.contains(info.quality.label))
        }
        XCTAssertEqual(MetricCatalog.ane.quality, .unavailable, "SiliconPulse does not fake Neural Engine utilization")
        XCTAssertEqual(MetricCatalog.gpuDevice.scope, .system)
        XCTAssertEqual(MetricCatalog.gpuProcessTime.quality, .estimated)
        XCTAssertEqual(MetricCatalog.temperatures.quality, .unavailable)
        XCTAssertNotNil(MetricCatalog.info(id: "mem.pressure"))
    }

    func testInferenceActivityQuality() {
        XCTAssertEqual(InferenceActivity.active(evidence: "x").quality, .systemReported)
        XCTAssertEqual(InferenceActivity.likely(evidence: "x").quality, .estimated)
        XCTAssertEqual(InferenceActivity.unknown.quality, .unavailable)
        XCTAssertTrue(InferenceActivity.likely(evidence: "x").isBusy)
        XCTAssertFalse(InferenceActivity.idle.isBusy)
    }

    // MARK: Formatting

    func testByteFormatting() {
        XCTAssertEqual(Format.bytes(UInt64(0)), "0 B")
        XCTAssertEqual(Format.bytes(UInt64(512 * 1024 * 1024)), "512 MB")
        XCTAssertEqual(Format.bytes(UInt64(23_407_000_000)), "21.8 GB")
        XCTAssertEqual(Format.bytes(UInt64(32) * 1_073_741_824), "32.0 GB")
        XCTAssertEqual(Format.compactBytes(23_407_000_000), "21.8G")
        XCTAssertEqual(Format.compactBytes(300 * 1_048_576), "300M")
    }

    func testRateFormatting() {
        XCTAssertEqual(Format.rate(0), "0 B/s")
        XCTAssertEqual(Format.rate(999), "999 B/s")
        XCTAssertEqual(Format.rate(1_500), "1.5 KB/s")
        XCTAssertEqual(Format.rate(12_300_000), "12 MB/s")
        XCTAssertEqual(Format.rate(-5), "0 B/s")
    }

    func testPercentAndDuration() {
        XCTAssertEqual(Format.percent(0.234), "23%")
        XCTAssertEqual(Format.percent(0.042, precise: true), "4.2%")
        XCTAssertEqual(Format.percent(1), "100%")
        XCTAssertEqual(Format.processCPU(12.34), "12.3")
        XCTAssertEqual(Format.processCPU(250.4), "250")
        XCTAssertEqual(Format.duration(42), "42s")
        XCTAssertEqual(Format.duration(17 * 60 + 42), "17m 42s")
        XCTAssertEqual(Format.duration(2 * 3600 + 5 * 60), "2h 05m")
        XCTAssertEqual(Format.duration(3 * 86_400 + 4 * 3600), "3d 4h")
        XCTAssertEqual(Format.integer(8192), "8,192")
        XCTAssertEqual(Format.integer(1_048_576), "1,048,576")
        XCTAssertEqual(Format.tokensPerSecond(37.44), "37.4 tok/s")
        XCTAssertEqual(Format.fixed(-0.25, 1), "-0.3")
        XCTAssertEqual(Format.fixed(.nan, 1), "—")
    }

    func testModelShortNames() {
        XCTAssertEqual(AIModelInfo.shortName(for: "qwen3:30b-a3b"), "qwen3")
        XCTAssertEqual(AIModelInfo.shortName(for: "Qwen3 30B A3B"), "Qwen3")
        XCTAssertEqual(AIModelInfo.shortName(for: "/models/Llama-3.2-3B-Instruct.gguf"), "Llama")
        XCTAssertEqual(AIModelInfo.shortName(for: "mlx-community/Qwen3-8B-4bit"), "Qwen3")
        XCTAssertEqual(AIModelInfo.shortName(for: "gpt-oss"), "gpt")
    }

    // MARK: Sampling policy

    func testScheduleWhenDashboardVisible() {
        let s = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: true, section: .overview), base: .oneSecond)
        XCTAssertEqual(s.system, 1)
        XCTAssertEqual(s.processes, 2)
        XCTAssertEqual(s.aiDiscovery, 5)
        let processes = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: true, section: .processes), base: .halfSecond)
        XCTAssertEqual(processes.system, 0.5)
        XCTAssertEqual(processes.processes, 2, "the process table is capped at 2 s")
        let slow = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: true, section: .processes), base: .fiveSeconds)
        XCTAssertEqual(slow.processes, 5)
        let ai = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: true, section: .ai), base: .oneSecond)
        XCTAssertEqual(ai.aiDiscovery, 2)
        let history = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: true, section: .history), base: .oneSecond)
        XCTAssertEqual(history.processes, 5, "history needs no process table")
    }

    func testScheduleWhenHidden() {
        let s = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: false), base: .halfSecond)
        XCTAssertEqual(s.system, 2)
        XCTAssertEqual(s.processes, 5)
        XCTAssertEqual(s.aiDiscovery, 10)
        let quiet = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: false, menuBarShowsLiveValues: false), base: .oneSecond)
        XCTAssertEqual(quiet.system, 5)
        let popover = SamplingPolicy.schedule(for: MonitoringDemand(popoverVisible: true), base: .oneSecond)
        XCTAssertEqual(popover.system, 1)
    }

    func testLowPowerModeDoublesIntervals() {
        let normal = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: true), base: .oneSecond)
        let low = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: true, lowPowerMode: true), base: .oneSecond)
        XCTAssertEqual(low.system, normal.system * 2)
        XCTAssertEqual(low.aiDiscovery, normal.aiDiscovery * 2)
    }

    func testScheduleNeverRunsAIFasterThanProcesses() {
        for base in SamplingInterval.allCases {
            for section in AppSection.allCases {
                for visible in [true, false] {
                    let s = SamplingPolicy.schedule(for: MonitoringDemand(dashboardVisible: visible, section: section), base: base)
                    XCTAssertGreaterThanOrEqual(s.aiDiscovery, s.processes)
                    XCTAssertGreaterThanOrEqual(s.system, 0.5)
                }
            }
        }
    }

    // MARK: Menu bar

    private func snapshot() -> SystemSnapshot {
        var s = SystemSnapshot.empty
        s.cpu.usage = CPUUsage(user: 0.15, system: 0.07, nice: 0, idle: 0.78)
        s.gpu.deviceUtilization = 0.91
        s.memory = MemorySnapshot(total: 32 * 1_073_741_824, used: 23_407_000_000, app: 0, wired: 0, compressed: 0, cachedFiles: 0,
                                  free: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
        return s
    }

    func testMenuBarTitle() {
        let title = MenuBarFormatter.title(items: [.cpu, .gpu, .memory], snapshot: snapshot(), featured: nil, preferAI: true)
        XCTAssertEqual(title, "CPU 22% · GPU 91% · RAM 21.8G")
    }

    func testMenuBarOmitsUnavailableGPU() {
        var s = snapshot()
        s.gpu.deviceUtilization = nil
        XCTAssertEqual(MenuBarFormatter.title(items: [.cpu, .gpu], snapshot: s, featured: nil, preferAI: false), "CPU 22%")
    }

    func testMenuBarAIModeOnlyShowsRealThroughput() {
        var w = AIWorkload(id: "x", runner: .llamaCpp, state: .modelLoaded,
                           models: [AIModelInfo(identifier: "Qwen3-30B-A3B", source: "test")])
        w.activity = .active(evidence: "test")
        w.tokensPerSecond = Measured(38.4, quality: .calculated, source: "test")
        XCTAssertEqual(MenuBarFormatter.title(items: [.gpu, .memory], snapshot: snapshot(), featured: w, preferAI: true),
                       "Qwen3 · GPU 91% · 38 tok/s")
        // Runner without counters: no tok/s, memory instead.
        w.tokensPerSecond = .unavailable("n/a")
        XCTAssertEqual(MenuBarFormatter.title(items: [.gpu, .memory], snapshot: snapshot(), featured: w, preferAI: true),
                       "Qwen3 · GPU 91% · RAM 21.8G")
    }

    func testMenuBarPressureOnlyWhenNotNormal() {
        var s = snapshot()
        XCTAssertEqual(MenuBarFormatter.title(items: [.pressure], snapshot: s, featured: nil, preferAI: false), "")
        s.memory.pressure = .warning
        XCTAssertEqual(MenuBarFormatter.title(items: [.pressure], snapshot: s, featured: nil, preferAI: false), "WARNING")
    }

    func testPowerSummary() {
        XCTAssertEqual(PowerSnapshot(hasBattery: true, onACPower: false, batteryPercent: 82, isCharging: false, lowPowerMode: false).summary,
                       "Battery 82% · On battery")
        XCTAssertEqual(PowerSnapshot(hasBattery: false, onACPower: true, batteryPercent: nil, isCharging: false, lowPowerMode: true).summary,
                       "Power adapter · Low Power Mode")
    }
}
