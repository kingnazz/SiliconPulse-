import Foundation

/// Static description of a metric: what it is, where it comes from and how good it is.
/// Mirrors docs/METRICS.md and backs the UI tooltips.
public struct MetricInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let scope: MetricScope
    public let quality: MetricQuality
    public let source: String
    public let note: String?

    public init(id: String, title: String, scope: MetricScope, quality: MetricQuality, source: String, note: String? = nil) {
        self.id = id
        self.title = title
        self.scope = scope
        self.quality = quality
        self.source = source
        self.note = note
    }

    /// Text for a hover tooltip.
    public var tooltip: String {
        var lines = ["\(title) · \(scope.label) · \(quality.label)", quality.explanation, "Source: \(source)"]
        if let note { lines.append(note) }
        return lines.joined(separator: "\n")
    }
}

public enum MetricCatalog {
    // CPU
    public static let cpuTotal = MetricInfo(id: "cpu.total", title: "CPU", scope: .system, quality: .calculated,
        source: "host_processor_info tick deltas", note: "100% means every core is fully busy.")
    public static let cpuUser = MetricInfo(id: "cpu.user", title: "User", scope: .system, quality: .calculated,
        source: "host_processor_info tick deltas")
    public static let cpuSystem = MetricInfo(id: "cpu.system", title: "System", scope: .system, quality: .calculated,
        source: "host_processor_info tick deltas")
    public static let cpuIdle = MetricInfo(id: "cpu.idle", title: "Idle", scope: .system, quality: .calculated,
        source: "host_processor_info tick deltas")
    public static let loadAverage = MetricInfo(id: "cpu.load", title: "Load average", scope: .system, quality: .systemReported,
        source: "getloadavg()", note: "Average number of runnable threads over 1, 5 and 15 minutes.")
    public static let coreTopology = MetricInfo(id: "cpu.topology", title: "Core layout", scope: .system, quality: .systemReported,
        source: "sysctl hw.perflevel* and IODeviceTree cluster-type")

    // GPU
    public static let gpuDevice = MetricInfo(id: "gpu.device", title: "GPU", scope: .system, quality: .systemReported,
        source: "IOAccelerator PerformanceStatistics “Device Utilization %”",
        note: "Whole-GPU utilization. It is not attributed to any single process.")
    public static let gpuRenderer = MetricInfo(id: "gpu.renderer", title: "Renderer", scope: .system, quality: .systemReported,
        source: "IOAccelerator “Renderer Utilization %”")
    public static let gpuTiler = MetricInfo(id: "gpu.tiler", title: "Tiler", scope: .system, quality: .systemReported,
        source: "IOAccelerator “Tiler Utilization %”")
    public static let gpuMemory = MetricInfo(id: "gpu.memory", title: "GPU memory in use", scope: .system, quality: .systemReported,
        source: "IOAccelerator “In use system memory”", note: "Unified memory the GPU currently has in use.")
    public static let gpuProcessTime = MetricInfo(id: "gpu.processTime", title: "GPU time share", scope: .process, quality: .estimated,
        source: "IOKit GPU user-client accounting (AppUsage.accumulatedGPUTime)",
        note: "Share of wall time this process had GPU work executing. Undocumented counters, so treat it as a strong hint, not a measurement.")

    // Neural Engine
    public static let ane = MetricInfo(id: "ane", title: "Neural Engine", scope: .system, quality: .unavailable,
        source: "None", note: "macOS has no public API for Neural Engine utilization. powermetrics reports ANE power only, and needs root.")

    // Memory
    public static let memoryInstalled = MetricInfo(id: "mem.installed", title: "Installed", scope: .system, quality: .exact,
        source: "sysctl hw.memsize")
    public static let memoryUsed = MetricInfo(id: "mem.used", title: "Memory used", scope: .system, quality: .calculated,
        source: "host_statistics64: app + wired + compressed", note: "Same formula as Activity Monitor.")
    public static let memoryAvailable = MetricInfo(id: "mem.available", title: "Available", scope: .system, quality: .calculated,
        source: "Installed − used")
    public static let memoryApp = MetricInfo(id: "mem.app", title: "App memory", scope: .system, quality: .calculated,
        source: "host_statistics64: internal − purgeable pages")
    public static let memoryWired = MetricInfo(id: "mem.wired", title: "Wired", scope: .system, quality: .systemReported,
        source: "host_statistics64 wire_count", note: "Memory that cannot be compressed or paged out, including GPU-wired model weights.")
    public static let memoryCompressed = MetricInfo(id: "mem.compressed", title: "Compressed", scope: .system, quality: .systemReported,
        source: "host_statistics64 compressor_page_count", note: "Physical memory the compressor occupies.")
    public static let memoryCached = MetricInfo(id: "mem.cached", title: "Cached files", scope: .system, quality: .calculated,
        source: "host_statistics64: external + purgeable pages", note: "Reclaimable file cache.")
    public static let memoryFree = MetricInfo(id: "mem.free", title: "Free", scope: .system, quality: .systemReported,
        source: "host_statistics64 free_count")
    public static let memoryPressure = MetricInfo(id: "mem.pressure", title: "Memory pressure", scope: .system, quality: .systemReported,
        source: "kern.memorystatus_vm_pressure_level + dispatch memory-pressure events")
    public static let memoryFreeLevel = MetricInfo(id: "mem.level", title: "Kernel free level", scope: .system, quality: .systemReported,
        source: "sysctl kern.memorystatus_level", note: "Percentage of memory the kernel considers available.")
    public static let swapUsed = MetricInfo(id: "mem.swap", title: "Swap used", scope: .system, quality: .systemReported,
        source: "sysctl vm.swapusage")
    public static let swapActivity = MetricInfo(id: "mem.swapActivity", title: "Swap activity", scope: .system, quality: .calculated,
        source: "host_statistics64 swapins/swapouts deltas", note: "Non-zero swap-outs mean macOS is writing memory to disk right now.")
    public static let compressionActivity = MetricInfo(id: "mem.compression", title: "Compression activity", scope: .system, quality: .calculated,
        source: "host_statistics64 compressions/decompressions deltas")
    public static let memoryHeadroom = MetricInfo(id: "mem.headroom", title: "Headroom", scope: .system, quality: .estimated,
        source: "Available − 10% of installed",
        note: "Rough amount you can allocate before macOS starts compressing aggressively. Not a guarantee.")

    // Thermal & power
    public static let thermalState = MetricInfo(id: "thermal", title: "Thermal state", scope: .system, quality: .systemReported,
        source: "ProcessInfo.thermalState", note: "macOS exposes thermal pressure, not temperatures.")
    public static let temperatures = MetricInfo(id: "thermal.temps", title: "Temperatures", scope: .system, quality: .unavailable,
        source: "None", note: "Temperatures need SMC or private sensor APIs. SiliconPulse does not use them.")
    public static let powerSource = MetricInfo(id: "power", title: "Power", scope: .system, quality: .systemReported,
        source: "IOPSCopyPowerSourcesInfo, ProcessInfo.isLowPowerModeEnabled")
    public static let energyImpact = MetricInfo(id: "energy", title: "Energy impact", scope: .process, quality: .unavailable,
        source: "None", note: "Activity Monitor's energy formula is proprietary.")

    // Disk & network
    public static let diskThroughput = MetricInfo(id: "disk", title: "Disk throughput", scope: .system, quality: .calculated,
        source: "IOBlockStorageDriver Statistics byte counters", note: "Mounted disk images may also count toward their host disk.")
    public static let networkThroughput = MetricInfo(id: "net", title: "Network throughput", scope: .system, quality: .calculated,
        source: "sysctl NET_RT_IFLIST2 64-bit interface counters", note: "Excludes loopback, tunnels and bridges to avoid double counting.")
    public static let processNetwork = MetricInfo(id: "net.process", title: "Per-process network", scope: .process, quality: .unavailable,
        source: "None", note: "Needs the private NetworkStatistics framework.")

    // Processes
    public static let processCPU = MetricInfo(id: "proc.cpu", title: "CPU", scope: .process, quality: .calculated,
        source: "proc_pidinfo PROC_PIDTASKINFO CPU-time deltas", note: "100% = one fully busy core. Processes owned by other users are restricted.")
    public static let processMemory = MetricInfo(id: "proc.mem", title: "Memory", scope: .process, quality: .systemReported,
        source: "proc_pid_rusage ri_phys_footprint", note: "Physical footprint, the same figure Activity Monitor shows.")
    public static let processDisk = MetricInfo(id: "proc.disk", title: "Disk I/O", scope: .process, quality: .calculated,
        source: "proc_pid_rusage ri_diskio_bytesread/written deltas")
    public static let processThreads = MetricInfo(id: "proc.threads", title: "Threads", scope: .process, quality: .systemReported,
        source: "proc_pidinfo pti_threadnum")
    public static let processArchitecture = MetricInfo(id: "proc.arch", title: "Architecture", scope: .process, quality: .exact,
        source: "kinfo_proc P_TRANSLATED flag")
    public static let restricted = MetricInfo(id: "proc.restricted", title: "Restricted", scope: .process, quality: .unavailable,
        source: "macOS process security policy",
        note: "macOS only lets an app read CPU, memory and disk counters for processes owned by the same user. System totals still include these processes.")

    // AI
    public static let aiTokensPerSecond = MetricInfo(id: "ai.tps", title: "Tokens/sec", scope: .model, quality: .calculated,
        source: "llama-server /metrics or /slots counter deltas",
        note: "Only runners that expose generation counters can report this. Ollama, LM Studio and MLX do not.")
    public static let aiModelMemory = MetricInfo(id: "ai.modelMemory", title: "Model memory", scope: .model, quality: .systemReported,
        source: "Runner API (Ollama size, LM Studio size_bytes)")
    public static let aiGPUOffload = MetricInfo(id: "ai.gpuOffload", title: "GPU offload", scope: .model, quality: .systemReported,
        source: "Ollama size_vram ÷ size, llama.cpp -ngl")
    public static let aiContext = MetricInfo(id: "ai.context", title: "Context", scope: .model, quality: .systemReported,
        source: "Runner API or launch arguments")
    public static let aiProcessCPU = MetricInfo(id: "ai.processCPU", title: "Runner CPU", scope: .process, quality: .calculated,
        source: "Sum of CPU over the runner's process tree")
    public static let aiProcessMemory = MetricInfo(id: "ai.processMemory", title: "Runner memory", scope: .process, quality: .systemReported,
        source: "Sum of physical footprint over the runner's process tree",
        note: "GPU-wired model weights may be counted under Wired memory rather than here.")
    public static let aiProcessGPU = MetricInfo(id: "ai.processGPU", title: "Runner GPU time", scope: .process, quality: .estimated,
        source: "IOKit GPU user-client accounting for the runner's processes")
    public static let aiInference = MetricInfo(id: "ai.inference", title: "Inference activity", scope: .model, quality: .estimated,
        source: "Runner slot state, token counters, keep-alive refresh or runner GPU/CPU activity",
        note: "The status names the evidence it is based on.")
    public static let aiRuntime = MetricInfo(id: "ai.runtime", title: "Runtime", scope: .process, quality: .exact,
        source: "Process start time")

    public static let all: [MetricInfo] = [
        cpuTotal, cpuUser, cpuSystem, cpuIdle, loadAverage, coreTopology,
        gpuDevice, gpuRenderer, gpuTiler, gpuMemory, gpuProcessTime, ane,
        memoryInstalled, memoryUsed, memoryAvailable, memoryApp, memoryWired, memoryCompressed, memoryCached,
        memoryFree, memoryPressure, memoryFreeLevel, swapUsed, swapActivity, compressionActivity, memoryHeadroom,
        thermalState, temperatures, powerSource, energyImpact,
        diskThroughput, networkThroughput, processNetwork,
        processCPU, processMemory, processDisk, processThreads, processArchitecture, restricted,
        aiTokensPerSecond, aiModelMemory, aiGPUOffload, aiContext, aiProcessCPU, aiProcessMemory, aiProcessGPU,
        aiInference, aiRuntime,
    ]

    public static func info(id: String) -> MetricInfo? { all.first { $0.id == id } }
}
