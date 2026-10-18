import Darwin
import Foundation
import XCTest
@testable import SiliconPulseCore
@testable import SiliconPulseSystem

/// Smoke tests against the real macOS interfaces. They check plausibility, not exact values.
final class SystemCollectorTests: XCTestCase {
    func testCPUSnapshotIsPlausible() throws {
        let collector = CPUCollector()
        XCTAssertGreaterThan(collector.topology.logicalCores, 0)
        XCTAssertFalse(collector.topology.brand.isEmpty)
        _ = collector.sample()
        // Burn a little CPU so the interval is non-trivial.
        var x = 0.0
        for i in 0..<2_000_000 { x += sin(Double(i)) }
        XCTAssertNotEqual(x, 0.123)
        usleep(100_000)
        let snapshot = try XCTUnwrap(collector.sample())
        XCTAssertEqual(snapshot.cores.count, collector.topology.logicalCores)
        XCTAssertTrue((0...1).contains(snapshot.usage.total))
        XCTAssertEqual(snapshot.usage.user + snapshot.usage.system + snapshot.usage.nice + snapshot.usage.idle, 1, accuracy: 1e-6)
        XCTAssertEqual(snapshot.loadAverage.count, 3)
        if let kinds = collector.topology.coreKinds {
            XCTAssertEqual(kinds.filter { $0 == .performance }.count, collector.topology.performanceCores)
        }
        print("CPU topology:", collector.topology)
    }

    func testMemorySnapshotIsPlausible() throws {
        let collector = MemoryCollector()
        let snapshot = try XCTUnwrap(collector.sample(now: Clock.uptimeNanoseconds()))
        XCTAssertGreaterThan(snapshot.total, 1 << 30)
        XCTAssertLessThanOrEqual(snapshot.used, snapshot.total)
        XCTAssertGreaterThan(snapshot.wired, 0)
        XCTAssertLessThanOrEqual(snapshot.app + snapshot.wired + snapshot.compressed, snapshot.total + (1 << 20))
        usleep(50_000)
        let second = try XCTUnwrap(collector.sample(now: Clock.uptimeNanoseconds()))
        XCTAssertNotNil(second.swapOutsPerSecond, "second sample has rates")
        print("Memory:", Format.bytes(snapshot.used), "/", Format.bytes(snapshot.total), "pressure", snapshot.pressure, "level", snapshot.kernelFreeLevel as Any)
    }

    func testGPUCollectorDoesNotCrash() {
        let collector = GPUCollector()
        let snapshot = collector.sample()
        if let device = snapshot.deviceUtilization { XCTAssertTrue((0...1).contains(device)) }
        let clients = collector.perProcessGPUTime()
        print("GPU:", snapshot.name, snapshot.deviceUtilization as Any, "per-process supported:", collector.perProcessSupported as Any, "clients:", clients?.count as Any)
    }

    func testDiskAndNetworkRatesAreNonNegative() {
        let disk = DiskCollector()
        let network = NetworkCollector()
        _ = disk.sample(now: Clock.uptimeNanoseconds())
        _ = network.sample(now: Clock.uptimeNanoseconds())
        usleep(200_000)
        let d = disk.sample(now: Clock.uptimeNanoseconds())
        let n = network.sample(now: Clock.uptimeNanoseconds())
        XCTAssertGreaterThanOrEqual(d.readBytesPerSecond, 0)
        XCTAssertGreaterThanOrEqual(n.receivedBytesPerSecond, 0)
        XCTAssertFalse(n.interfaces.contains { $0.name.hasPrefix("lo") }, "loopback excluded")
        print("Disk total read:", Format.bytes(d.totalRead), "interfaces:", n.interfaces.map(\.name))
    }

    func testOwnProcessIsSampledAccurately() throws {
        let collector = ProcessCollector()
        _ = collector.sample(now: Clock.uptimeNanoseconds(), apps: [:], gpuShares: [:])
        var x = 0.0
        let start = Date()
        while Date().timeIntervalSince(start) < 0.3 { x += sqrt(Double(arc4random())) }
        XCTAssertGreaterThan(x, 0)
        let samples = collector.sample(now: Clock.uptimeNanoseconds(), apps: [:], gpuShares: [:])
        XCTAssertGreaterThan(samples.count, 10)
        let me = try XCTUnwrap(samples.first { $0.pid == getpid() })
        XCTAssertTrue(me.countersAvailable)
        XCTAssertEqual(me.parentPID, getppid())
        XCTAssertGreaterThan(me.memoryFootprint ?? 0, 1 << 20)
        XCTAssertGreaterThan(me.threadCount ?? 0, 0)
        // Busy-looped ~0.3 s on one thread: CPU should be clearly non-zero and below 400%.
        let cpu = try XCTUnwrap(me.cpuPercent)
        XCTAssertGreaterThan(cpu, 20)
        XCTAssertLessThan(cpu, 400)
        XCTAssertNotNil(me.executablePath)
        // launchd is owned by root: counters must be reported as restricted, not zero.
        if getuid() != 0, let launchd = samples.first(where: { $0.pid == 1 }) {
            XCTAssertFalse(launchd.countersAvailable)
            XCTAssertNil(launchd.cpuPercent)
            XCTAssertEqual(launchd.userName, "root")
        }
    }

    func testOwnArgumentsAndDetails() throws {
        let collector = ProcessCollector()
        let samples = collector.sample(now: Clock.uptimeNanoseconds(), apps: [:], gpuShares: [:])
        let me = try XCTUnwrap(samples.first { $0.pid == getpid() })
        let args = try XCTUnwrap(collector.arguments(for: me.id))
        XCTAssertFalse(args.arguments.isEmpty)
        XCTAssertFalse(args.environment.isEmpty)
        XCTAssertNotNil(collector.workingDirectory(pid: getpid()))
        XCTAssertGreaterThan(collector.openFileCount(pid: getpid()) ?? 0, 0)
    }

    func testListeningSocketsDetected() throws {
        // Open a listening socket on loopback and check it is reported.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = UInt16(bigEndian: actual.sin_port)

        let sockets = ProcessCollector().listeningSockets(pid: getpid())
        XCTAssertTrue(sockets.contains { $0.port == port && $0.address == "127.0.0.1" }, "\(sockets) should contain \(port)")
    }

    func testSamplerProducesSnapshotsAndTimings() async {
        let sampler = SystemSampler()
        var snapshot = await sampler.sampleSystem(previous: .empty)
        try? await Task.sleep(nanoseconds: 200_000_000)
        snapshot = await sampler.sampleSystem(previous: snapshot)
        _ = await sampler.samplePower()
        let processes = await sampler.sampleProcesses(apps: [:])
        _ = await sampler.aiCandidates(from: processes)
        XCTAssertGreaterThan(snapshot.memory.total, 0)
        XCTAssertEqual(snapshot.cpu.cores.count, snapshot.cpu.topology.logicalCores)
        let timings = await sampler.collectorTimings()
        XCTAssertTrue(timings.contains { $0.name == "Processes" })
        for timing in timings {
            print(String(format: "collector %-14@ runs %d avg CPU %.3f ms", timing.name as NSString, timing.runs, timing.averageCPUMilliseconds))
        }
    }

    func testAIMonitorAgainstRealLoopbackHandlesNoRunners() async {
        // On CI nothing listens on the runner ports: detection must finish quickly and report nothing loaded.
        let monitor = AIMonitor(http: URLSessionLocalHTTPClient())
        let start = Date()
        let result = await monitor.refresh(candidates: [], samples: [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        XCTAssertFalse(result.workloads.contains { $0.state == .modelLoaded && $0.runner == .lmStudio })
    }
}
