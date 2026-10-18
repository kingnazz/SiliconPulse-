import Darwin
import Foundation
import XCTest
@testable import SiliconPulseCore
@testable import SiliconPulseSystem

/// Checks that need real Apple Silicon hardware (CI runs on a virtual Mac that has no GPU utilization
/// and no P/E core levels). Run by `scripts/validate-on-mac.sh`, or directly:
///
///     SILICONPULSE_VALIDATE_MAC=1 swift test --filter RealMacValidationTests
///
/// Lines starting with `VALIDATE` are parsed by the script.
final class RealMacValidationTests: XCTestCase {
    private func requireRealMac() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SILICONPULSE_VALIDATE_MAC"] == "1",
                          "Set SILICONPULSE_VALIDATE_MAC=1 on a real Apple Silicon Mac")
    }

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private var isVirtual: Bool { (sysctlString("hw.model") ?? "").contains("VirtualMac") }

    func testCoreTopologyAndClusters() async throws {
        try requireRealMac()
        let sampler = SystemSampler()
        var snapshot = await sampler.sampleSystem(previous: .empty)
        try await Task.sleep(nanoseconds: 500_000_000)
        snapshot = await sampler.sampleSystem(previous: snapshot)
        let topology = snapshot.cpu.topology
        let levels = sysctlInt("hw.nperflevels") ?? 1
        print("VALIDATE machine model=\(sysctlString("hw.model") ?? "?") chip=\(topology.brand) logical=\(topology.logicalCores) "
              + "perflevels=\(levels) P=\(topology.performanceCores.map(String.init) ?? "-") E=\(topology.efficiencyCores.map(String.init) ?? "-")")
        XCTAssertEqual(snapshot.cpu.cores.count, topology.logicalCores)
        guard levels >= 2 else { throw XCTSkip("This Mac reports a single performance level; no P/E grouping to check") }
        XCTAssertEqual(topology.performanceCores, sysctlInt("hw.perflevel0.logicalcpu"), "P cores match hw.perflevel0")
        XCTAssertEqual(topology.efficiencyCores, sysctlInt("hw.perflevel1.logicalcpu"), "E cores match hw.perflevel1")
        let kinds = snapshot.cpu.cores.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .performance }.count, topology.performanceCores)
        XCTAssertEqual(kinds.filter { $0 == .efficiency }.count, topology.efficiencyCores)
        print("VALIDATE cores " + snapshot.cpu.cores.map { "\($0.id):\($0.kind.rawValue.prefix(1))" }.joined(separator: " "))
    }

    /// Samples GPU utilization once a second (default 15 s, `SILICONPULSE_VALIDATE_SECONDS`) and prints it,
    /// so the script can compare it with `powermetrics` over the same interval.
    func testGPUUtilizationTrace() async throws {
        try requireRealMac()
        guard !isVirtual else { throw XCTSkip("Virtual Macs do not report GPU utilization") }
        let seconds = Int(ProcessInfo.processInfo.environment["SILICONPULSE_VALIDATE_SECONDS"] ?? "") ?? 15
        let sampler = SystemSampler()
        var snapshot = await sampler.sampleSystem(previous: .empty)
        var values: [Double] = []
        for _ in 0..<seconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            snapshot = await sampler.sampleSystem(previous: snapshot)
            let gpu = snapshot.gpu
            if let device = gpu.deviceUtilization { values.append(device) }
            print(String(format: "VALIDATE gpu t=%.0f device=%@ renderer=%@ tiler=%@", Date().timeIntervalSince1970,
                         gpu.deviceUtilization.map { String(format: "%.3f", $0) } ?? "nil",
                         gpu.rendererUtilization.map { String(format: "%.3f", $0) } ?? "nil",
                         gpu.tilerUtilization.map { String(format: "%.3f", $0) } ?? "nil"))
        }
        XCTAssertFalse(values.isEmpty, "a real Apple Silicon GPU reports Device Utilization %")
        XCTAssertTrue(values.allSatisfy { (0...1).contains($0) }, "utilization stays within 0–100%")
        print(String(format: "VALIDATE gpu-mean %.3f over %d samples", values.reduce(0, +) / Double(max(1, values.count)), values.count))

        // Per-process GPU time is a share of time with GPU work queued: shown as an estimate, never as utilization.
        let processes = await sampler.sampleProcesses(apps: [:])
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let later = await sampler.sampleProcesses(apps: [:])
        _ = processes
        let busiest = later.filter { ($0.gpuTimeShare ?? 0) > 0.005 }.sorted { ($0.gpuTimeShare ?? 0) > ($1.gpuTimeShare ?? 0) }.prefix(5)
        for p in busiest {
            print(String(format: "VALIDATE gpu-time %@ %.3f", p.name, p.gpuTimeShare ?? 0))
        }
        XCTAssertEqual(MetricCatalog.aiProcessGPU.quality, .estimated, "per-process GPU time stays labeled as an estimate")
    }
}
