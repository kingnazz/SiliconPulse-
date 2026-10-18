import AppKit
import Foundation
import Observation
import SiliconPulseCore
import SiliconPulseSystem

/// The single owner of all sampling. Views never start timers; they read snapshots from here.
///
/// One loop drives every tier (system, processes, AI, slow). It sleeps until the next tier is due and is
/// woken early when demand rises (window opened, screen changed), so there is never more than one loop,
/// however often windows open and close or screens change.
@MainActor
@Observable
final class MonitorEngine {
    // MARK: Published state

    private(set) var system: SystemSnapshot = .empty
    private(set) var processes: [ProcessSample] = []
    private(set) var processesByPID: [Int32: ProcessSample] = [:]
    private(set) var ai: AIMonitorResult = .empty
    private(set) var history = MetricHistory()
    private(set) var diagnostics = EngineDiagnostics()
    private(set) var menuBarTitle = ""
    private(set) var inspected: InspectedProcess?
    private(set) var perProcessGPUSupported: Bool?
    private(set) var isRunning = false
    private(set) var hasSystemSample = false

    /// Section the main window shows; set by the sidebar.
    var section: AppSection = .overview {
        didSet { if section != oldValue { updateDemand() } }
    }

    // MARK: Internals

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private let aiMonitor = AIMonitor(http: URLSessionLocalHTTPClient())
    @ObservationIgnored private let apps = RunningAppsRegistry()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var aiTask: Task<Void, Never>?
    @ObservationIgnored private var inspectorTask: Task<Void, Never>?
    @ObservationIgnored private var wakeContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var wakeTimer: Task<Void, Never>?
    @ObservationIgnored private var due: [Tier: Date] = [:]
    @ObservationIgnored private var visibleDashboards = Set<ObjectIdentifier>()
    @ObservationIgnored private var visiblePopovers = Set<ObjectIdentifier>()
    @ObservationIgnored private var demand = MonitoringDemand()
    @ObservationIgnored private(set) var ownPID: Int32 = getpid()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private enum Tier: CaseIterable { case system, processes, ai, slow }

    init(settings: AppSettings) {
        self.settings = settings
        demand.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDemand() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestImmediate(.system) }
        })
    }

    var schedule: SamplingSchedule { SamplingPolicy.schedule(for: demand, base: settings.samplingInterval) }

    var isDashboardVisible: Bool { !visibleDashboards.isEmpty }

    // MARK: Lifecycle

    /// Starts the single sampling loop. Calling it again is a no-op.
    func start() {
        guard loopTask == nil else { return }
        apps.start()
        isRunning = true
        diagnostics.loopStarts += 1
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        wake()
        isRunning = false
    }

    private func runLoop() async {
        diagnostics.activeLoops += 1
        defer { diagnostics.activeLoops -= 1 }
        updateDemand()
        while !Task.isCancelled {
            let now = Date()
            let schedule = self.schedule
            diagnostics.schedule = schedule

            if isDue(.slow, now) {
                let power = await sampler.samplePower()
                system.thermal.power = power
                markDone(.slow, interval: schedule.slow)
            }
            if isDue(.system, now) {
                await sampleSystem()
                markDone(.system, interval: schedule.system)
            }
            if isDue(.processes, now) {
                await sampleProcesses()
                markDone(.processes, interval: schedule.processes)
            }
            if isDue(.ai, now) {
                startAIRefresh()
                markDone(.ai, interval: schedule.aiDiscovery)
            }
            if Task.isCancelled { break }
            let next = due.values.min() ?? now.addingTimeInterval(1)
            await sleep(seconds: max(0.05, next.timeIntervalSinceNow))
        }
    }

    private func isDue(_ tier: Tier, _ now: Date) -> Bool { (due[tier] ?? .distantPast) <= now }

    private func markDone(_ tier: Tier, interval: TimeInterval) { due[tier] = Date().addingTimeInterval(interval) }

    /// Interruptible sleep: `wake()` resumes it early. Only ever one sleeper, on the main actor.
    private func sleep(seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wakeContinuation = continuation
            wakeTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.wake()
            }
        }
    }

    private func wake() {
        wakeTimer?.cancel()
        wakeTimer = nil
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        }
    }

    private func requestImmediate(_ tiers: Tier...) {
        for tier in tiers { due[tier] = .distantPast }
        wake()
    }

    // MARK: Demand

    func setDashboardVisible(_ visible: Bool, token: ObjectIdentifier) {
        let changed = visible ? visibleDashboards.insert(token).inserted : visibleDashboards.remove(token) != nil
        if changed { updateDemand() }
    }

    func setPopoverVisible(_ visible: Bool, token: ObjectIdentifier) {
        let changed = visible ? visiblePopovers.insert(token).inserted : visiblePopovers.remove(token) != nil
        if changed { updateDemand() }
    }

    func settingsChanged() {
        updateDemand()
        updateMenuBarTitle()
    }

    private func updateDemand() {
        let old = schedule
        demand = MonitoringDemand(dashboardVisible: !visibleDashboards.isEmpty, popoverVisible: !visiblePopovers.isEmpty,
                                  section: section, menuBarShowsLiveValues: settings.menuBarShowsLiveValues,
                                  lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        let new = schedule
        diagnostics.schedule = new
        // Pull tiers forward when they should now run sooner, then wake the loop.
        let now = Date()
        var pulled = false
        func pull(_ tier: Tier, _ newInterval: TimeInterval, _ oldInterval: TimeInterval) {
            guard newInterval < oldInterval else { return }
            let target = now.addingTimeInterval(newInterval)
            if (due[tier] ?? .distantPast) > target {
                due[tier] = now
                pulled = true
            }
        }
        pull(.system, new.system, old.system)
        pull(.processes, new.processes, old.processes)
        pull(.ai, new.aiDiscovery, old.aiDiscovery)
        if pulled { wake() }
    }

    // MARK: Sampling

    private func sampleSystem() async {
        let snapshot = await sampler.sampleSystem(previous: system)
        guard !Task.isCancelled else { return }
        var updated = snapshot
        updated.thermal.power = system.thermal.power
        system = updated
        hasSystemSample = true
        history.record(updated)
        diagnostics.systemSamples += 1
        diagnostics.historyPoints = history.storedPointCount
        updateMenuBarTitle()
    }

    private func sampleProcesses() async {
        let samples = await sampler.sampleProcesses(apps: apps.snapshot)
        guard !Task.isCancelled else { return }
        processes = samples
        var map: [Int32: ProcessSample] = [:]
        map.reserveCapacity(samples.count)
        for sample in samples { map[sample.pid] = sample }
        processesByPID = map
        perProcessGPUSupported = await sampler.perProcessGPUSupported
        diagnostics.processSamples += 1
        if let me = map[ownPID] {
            diagnostics.selfCPUPercent = me.cpuPercent
            diagnostics.selfFootprint = me.memoryFootprint
        }
        diagnostics.timings = await sampler.collectorTimings()
        updateInspectedHistory()
    }

    private func startAIRefresh() {
        guard aiTask == nil else {
            diagnostics.aiRefreshesSkippedBusy += 1
            return
        }
        let samples = processes
        let probe = settings.probeDefaultPorts
        let endpoints = settings.customEndpointURLs
        aiTask = Task { [weak self, sampler, aiMonitor] in
            let candidates = await sampler.aiCandidates(from: samples)
            let result = await aiMonitor.refresh(candidates: candidates, samples: samples, probeDefaultPorts: probe,
                                                 customEndpoints: endpoints)
            guard let self else { return }
            self.ai = result
            self.aiTask = nil
            self.diagnostics.aiRefreshes += 1
            self.diagnostics.lastAIRefreshDuration = result.duration
            self.updateMenuBarTitle()
        }
    }

    /// Re-run AI detection now (e.g. the user just started a runner).
    func refreshAINow() { requestImmediate(.processes, .ai) }

    private func updateMenuBarTitle() {
        let title = MenuBarFormatter.title(items: Array(settings.menuBarItems), snapshot: system, featured: ai.featured,
                                           preferAI: settings.menuBarPrefersAI)
        if title != menuBarTitle { menuBarTitle = title }
    }

    // MARK: AI helpers

    /// PROCESS-scope aggregates for a workload, from the latest process sample (fresher than the AI tier).
    func liveProcessMetrics(for workload: AIWorkload) -> (cpu: Double?, memory: UInt64?, gpu: Double?) {
        let samples = workload.processPIDs.compactMap { processesByPID[$0] }
        let cpu = samples.compactMap(\.cpuPercent)
        let memory = samples.compactMap(\.memoryFootprint)
        let gpu = samples.compactMap(\.gpuTimeShare)
        return (cpu.isEmpty ? workload.processCPUPercent : cpu.reduce(0, +),
                memory.isEmpty ? workload.processMemory : memory.reduce(0, +),
                gpu.isEmpty ? workload.processGPUTimeShare : gpu.reduce(0, +))
    }

    // MARK: Inspector

    /// Starts collecting deeper metrics for one process. Only the selected process is inspected.
    func inspect(_ identity: ProcessIdentity?) {
        guard identity != inspected?.identity else { return }
        inspectorTask?.cancel()
        guard let identity else {
            inspected = nil
            return
        }
        inspected = InspectedProcess(identity: identity)
        updateInspectedHistory()
        inspectorTask = Task { [weak self, sampler] in
            while !Task.isCancelled {
                let details = await sampler.details(for: identity)
                guard let self, !Task.isCancelled, self.inspected?.identity == identity else { return }
                self.inspected?.details = details
                // Listening sockets and open files change slowly.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func updateInspectedHistory() {
        guard var current = inspected, let sample = processesByPID[current.identity.pid],
              sample.startTime == current.identity.startTime else { return }
        let now = Date()
        if let cpu = sample.cpuPercent { current.cpu.append(cpu, at: now) }
        if let memory = sample.memoryFootprint { current.memory.append(Double(memory), at: now) }
        inspected = current
    }

    func icon(for sample: ProcessSample) -> NSImage? { apps.icon(for: sample) }

    // MARK: Profiling support

    func collectorTimings() async -> [CollectorTiming] { await sampler.collectorTimings() }
}

/// State kept only for the process shown in the inspector.
struct InspectedProcess: Equatable {
    var identity: ProcessIdentity
    var details: ProcessDetails?
    var cpu = HistorySeries()
    var memory = HistorySeries()

    static func == (lhs: InspectedProcess, rhs: InspectedProcess) -> Bool {
        lhs.identity == rhs.identity && lhs.details == rhs.details && lhs.cpu.latest == rhs.cpu.latest
            && lhs.memory.latest == rhs.memory.latest && lhs.cpu.storedPointCount == rhs.cpu.storedPointCount
    }
}
