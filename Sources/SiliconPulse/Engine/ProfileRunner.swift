import AppKit
import Darwin
import SiliconPulseCore
import SwiftUI

/// Scripted self-profiling, enabled with `--profile <directory>`.
///
/// Drives the real app through its states (dashboard visible, every screen, window closed, rapid open/close)
/// and records SiliconPulse's own CPU time and memory footprint per phase, plus window screenshots.
/// The numbers come from the kernel's accounting for this process (getrusage, task_info), not estimates.
@MainActor
final class ProfileRunner {
    struct Phase: Codable {
        var name: String
        var seconds: Double
        var cpuSeconds: Double
        var averageCPUPercent: Double
        var footprintStartMB: Double
        var footprintEndMB: Double
        var systemSamples: Int
        var processSamples: Int
        var aiRefreshes: Int
        var activeLoopsAtEnd: Int
        var loopStartsAtEnd: Int
        var historyPoints: Int
    }

    struct Report: Codable {
        var machine: String
        var macOS: String
        var logicalCores: Int
        var memoryGB: Double
        var phases: [Phase]
        var collectors: [Collector]
        var gpuReported: Bool
        var perProcessGPUSupported: Bool?
        var processCount: Int
        var restrictedProcessCount: Int
        var aiWorkloads: [String]
        var problems: [String]
    }

    struct Collector: Codable {
        var name: String
        var runs: Int
        var averageCPUMilliseconds: Double
        var lastWallMilliseconds: Double
    }

    private let engine: MonitorEngine
    private let directory: URL
    private var phases: [Phase] = []
    private var problems: [String] = []

    init(engine: MonitorEngine, directory: URL) {
        self.engine = engine
        self.directory = directory
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { await run() }
    }

    private func run() async {
        engine.section = .overview
        await wait(6)
        await measure("Window visible · Overview (1 s sampling)", seconds: 30)

        // Tour every screen and capture it.
        let tourStart = mark()
        for section in AppSection.allCases {
            engine.section = section
            await wait(3.5)
            capture(name: "\(section.rawValue)")
        }
        record("Screen tour (all sections)", start: tourStart)

        engine.section = .processes
        await wait(2)
        await measure("Window visible · Processes", seconds: 20)

        engine.section = .ai
        await wait(2)
        await measure("Window visible · AI Models", seconds: 15)

        renderPopover()

        engine.section = .overview
        closeMainWindow()
        await wait(4)
        await measure("Window closed · menu bar only", seconds: 40)

        // Open and close the window repeatedly: must not accumulate loops or tasks.
        let cycleStart = mark()
        for _ in 0..<10 {
            AppWindows.showMain()
            await wait(1.2)
            closeMainWindow()
            await wait(1.2)
        }
        record("10× open/close window", start: cycleStart)
        if engine.diagnostics.activeLoops != 1 { problems.append("Expected 1 sampling loop, found \(engine.diagnostics.activeLoops)") }
        if engine.diagnostics.loopStarts != 1 { problems.append("Sampling loop was started \(engine.diagnostics.loopStarts) times") }

        AppWindows.showMain()
        engine.section = .overview
        await wait(3)
        await measure("Window reopened · Overview", seconds: 20)
        capture(name: "overview-final")

        writeReport()
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }

    // MARK: Measurement

    private struct Mark {
        var time: Date
        var cpu: Double
        var footprint: Double
        var diagnostics: EngineDiagnostics
    }

    private func mark() -> Mark {
        Mark(time: Date(), cpu: Self.ownCPUSeconds(), footprint: Self.ownFootprintMB(), diagnostics: engine.diagnostics)
    }

    private func measure(_ name: String, seconds: Double) async {
        let start = mark()
        await wait(seconds)
        record(name, start: start)
    }

    private func record(_ name: String, start: Mark) {
        let end = mark()
        let wall = end.time.timeIntervalSince(start.time)
        let cpu = end.cpu - start.cpu
        phases.append(Phase(name: name, seconds: wall, cpuSeconds: cpu, averageCPUPercent: wall > 0 ? cpu / wall * 100 : 0,
                            footprintStartMB: start.footprint, footprintEndMB: end.footprint,
                            systemSamples: end.diagnostics.systemSamples - start.diagnostics.systemSamples,
                            processSamples: end.diagnostics.processSamples - start.diagnostics.processSamples,
                            aiRefreshes: end.diagnostics.aiRefreshes - start.diagnostics.aiRefreshes,
                            activeLoopsAtEnd: end.diagnostics.activeLoops, loopStartsAtEnd: end.diagnostics.loopStarts,
                            historyPoints: end.diagnostics.historyPoints))
        writeReport()
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func ownCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func ownFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    // MARK: Windows & screenshots

    private func closeMainWindow() {
        AppWindows.mainWindow?.close()
    }

    /// Captures the app's own main window (no screen-recording permission needed for own windows).
    private func capture(name: String) {
        guard let window = AppWindows.mainWindow, let content = window.contentView else {
            problems.append("No main window to capture for \(name)")
            return
        }
        let view = content.superview ?? content
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent("screen-\(name).png"))
        }
    }

    private func renderPopover() {
        let view = MenuBarPopover()
            .environment(engine)
            .environment(engine.settings)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent("screen-menubar-popover.png"))
        }
    }

    // MARK: Report

    private func writeReport() {
        let snapshot = engine.system
        let processes = engine.processes
        let report = Report(
            machine: snapshot.cpu.topology.brand,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            logicalCores: snapshot.cpu.topology.logicalCores,
            memoryGB: Double(snapshot.memory.total) / 1_073_741_824,
            phases: phases,
            collectors: engine.diagnostics.timings.map {
                Collector(name: $0.name, runs: $0.runs, averageCPUMilliseconds: $0.averageCPUMilliseconds,
                          lastWallMilliseconds: Double($0.lastWallNanoseconds) / 1_000_000)
            },
            gpuReported: snapshot.gpu.isAvailable,
            perProcessGPUSupported: engine.perProcessGPUSupported,
            processCount: processes.count,
            restrictedProcessCount: processes.filter { !$0.countersAvailable }.count,
            aiWorkloads: engine.ai.workloads.map { "\($0.runner.displayName): \($0.state.label)" },
            problems: problems)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: directory.appendingPathComponent("report.json"))
        }
        try? markdown(report).write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }

    private func markdown(_ r: Report) -> String {
        var lines = [
            "# SiliconPulse self-profile",
            "",
            "Machine: \(r.machine), \(r.logicalCores) logical cores, \(Format.fixed(r.memoryGB, 0)) GB, \(r.macOS)",
            "GPU utilization reported: \(r.gpuReported) · per-process GPU accounting: \(r.perProcessGPUSupported.map(String.init) ?? "unknown")",
            "Processes: \(r.processCount) (\(r.restrictedProcessCount) restricted)",
            "",
            "| Phase | Duration | CPU time | Avg CPU | Footprint start → end | System samples | Process samples | AI refreshes | Loops |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for p in r.phases {
            lines.append("| \(p.name) | \(Format.fixed(p.seconds, 0)) s | \(Format.fixed(p.cpuSeconds, 2)) s | \(Format.fixed(p.averageCPUPercent, 2))% | \(Format.fixed(p.footprintStartMB, 1)) → \(Format.fixed(p.footprintEndMB, 1)) MB | \(p.systemSamples) | \(p.processSamples) | \(p.aiRefreshes) | \(p.activeLoopsAtEnd) running / \(p.loopStartsAtEnd) started |")
        }
        lines += ["", "| Collector | Runs | Avg thread CPU | Last wall time |", "|---|---|---|---|"]
        for c in r.collectors {
            lines.append("| \(c.name) | \(c.runs) | \(Format.fixed(c.averageCPUMilliseconds, 3)) ms | \(Format.fixed(c.lastWallMilliseconds, 3)) ms |")
        }
        lines += ["", "AI workloads: " + (r.aiWorkloads.isEmpty ? "none" : r.aiWorkloads.joined(separator: ", ")),
                  "Problems: " + (r.problems.isEmpty ? "none" : r.problems.joined(separator: "; "))]
        return lines.joined(separator: "\n") + "\n"
    }
}
