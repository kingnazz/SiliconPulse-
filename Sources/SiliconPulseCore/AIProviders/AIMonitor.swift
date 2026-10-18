import Foundation

/// Turns runner counters into tokens/sec. Never reports a rate it did not observe.
public struct ThroughputTracker: Sendable {
    struct MetricsReading: Sendable { var tokens: Double; var seconds: Double; var time: Date }
    struct SlotsReading: Sendable { var decoded: [Int: Int]; var time: Date }

    private var metrics: [String: MetricsReading] = [:]
    private var slots: [String: SlotsReading] = [:]
    private var lastRate: [String: (value: Double, time: Date)] = [:]

    /// How long a finished generation's rate is still shown (marked "last request").
    public static let lastRateRetention: TimeInterval = 120

    public init() {}

    public struct Result: Equatable, Sendable {
        public var rate: Measured<Double>
        /// true when tokens were generated during the last interval.
        public var isLive: Bool
        /// true when the counters advanced during the last interval.
        public var countersAdvanced: Bool
    }

    public mutating func update(id: String, runner: AIRunner, counters: AIRuntimeCounters?, now: Date) -> Result {
        let unavailable = Result(rate: .unavailable("\(runner.displayName) does not expose live generation counters."),
                                 isLive: false, countersAdvanced: false)
        guard let counters else { return unavailable }

        // Preferred: decode-time counters (`/metrics`), which exclude prompt processing and idle time.
        if let tokens = counters.tokensPredictedTotal, let seconds = counters.tokensPredictedSecondsTotal {
            defer { metrics[id] = MetricsReading(tokens: tokens, seconds: seconds, time: now) }
            if let previous = metrics[id], tokens >= previous.tokens, seconds >= previous.seconds {
                let dTokens = tokens - previous.tokens
                let dSeconds = seconds - previous.seconds
                if dTokens > 0, dSeconds > 0 {
                    let rate = dTokens / dSeconds
                    lastRate[id] = (rate, now)
                    return Result(rate: Measured(rate, quality: .calculated, source: "llama-server /metrics"), isLive: true, countersAdvanced: true)
                }
            }
            return retained(id: id, now: now, source: "llama-server /metrics")
        }

        // Fallback: decoded tokens per slot over wall time (`/slots`).
        if let decoded = counters.slotDecoded {
            defer { slots[id] = SlotsReading(decoded: decoded, time: now) }
            if let previous = slots[id] {
                let elapsed = now.timeIntervalSince(previous.time)
                var delta = 0
                for (slot, value) in decoded {
                    let old = previous.decoded[slot] ?? 0
                    // n_decoded resets for each request; after a reset the new value is all new tokens.
                    delta += value >= old ? value - old : value
                }
                if elapsed > 0, delta > 0 {
                    let rate = Double(delta) / elapsed
                    lastRate[id] = (rate, now)
                    return Result(rate: Measured(rate, quality: .calculated, source: "llama-server /slots",
                                                 note: "Wall-clock rate; includes prompt processing time."),
                                  isLive: true, countersAdvanced: true)
                }
            }
            return retained(id: id, now: now, source: "llama-server /slots")
        }
        return unavailable
    }

    private func retained(id: String, now: Date, source: String) -> Result {
        if let last = lastRate[id], now.timeIntervalSince(last.time) <= Self.lastRateRetention {
            let ago = Int(now.timeIntervalSince(last.time))
            return Result(rate: Measured(last.value, quality: .calculated, source: source, note: "Last generation, \(ago)s ago"),
                          isLive: false, countersAdvanced: false)
        }
        return Result(rate: Measured(nil, quality: .calculated, source: source, note: "No generation since SiliconPulse started watching"),
                      isLive: false, countersAdvanced: false)
    }

    public mutating func forget(except ids: Set<String>) {
        metrics = metrics.filter { ids.contains($0.key) }
        slots = slots.filter { ids.contains($0.key) }
        lastRate = lastRate.filter { ids.contains($0.key) }
    }
}

public struct AIMonitorResult: Sendable {
    public var workloads: [AIWorkload]
    public var statuses: [AIProviderStatus]
    /// Inference-activity history per workload id (0 idle, 0.5 likely, 1 active).
    public var timelines: [String: HistorySeries]
    public var timestamp: Date
    public var duration: TimeInterval

    public static let empty = AIMonitorResult(workloads: [], statuses: [], timelines: [:], timestamp: .distantPast, duration: 0)

    /// How long a workload stays featured after its last inference activity, so the Overview card and
    /// menu bar do not flip between runners every time one pauses between requests.
    public static let featuredStickiness: TimeInterval = 60

    /// The workload to feature in Overview and the menu bar: the most recently active loaded model,
    /// else any loaded model, else any detected runner.
    public var featured: AIWorkload? {
        let loaded = workloads.filter { $0.state == .modelLoaded || ($0.state == .processOnly && !$0.models.isEmpty) }
        let recent = loaded.compactMap { w -> (AIWorkload, Date)? in
            guard let last = w.lastActivity, timestamp.timeIntervalSince(last) <= Self.featuredStickiness else { return nil }
            return (w, last)
        }
        if let mostRecent = recent.max(by: { $0.1 < $1.1 }) { return mostRecent.0 }
        return loaded.first ?? workloads.first
    }

    public var aiPIDs: Set<Int32> { Set(workloads.flatMap(\.processPIDs)) }
}

/// Runs all providers, de-duplicates their claims, and adds derived values.
/// An actor so slow or failing local APIs never block system sampling or the UI.
public actor AIMonitor {
    public static func defaultProviders() -> [AIProvider] {
        [OllamaProvider(), LMStudioProvider(), LlamaCppProvider(), MLXProvider()]
    }

    private let providers: [AIProvider]
    private let generic: AIProvider
    private let http: LocalHTTPClient
    private var throughput = ThroughputTracker()
    private var timelines: [String: HistorySeries] = [:]
    private var lastSeen: [String: Date] = [:]
    private var ollamaExpiry: [String: Date] = [:]
    private var lastActivity: [String: Date] = [:]

    /// GPU time share of a runner's processes above which it is considered busy.
    public static let gpuBusyThreshold = 0.10
    /// Runner CPU (percent of one core) above which it is considered busy when no better evidence exists.
    public static let cpuBusyThreshold = 100.0

    public init(http: LocalHTTPClient, providers: [AIProvider] = AIMonitor.defaultProviders(), generic: AIProvider = GenericInferenceProvider()) {
        self.http = http
        self.providers = providers
        self.generic = generic
    }

    public func refresh(candidates: [AIProcessInfo], samples: [ProcessSample], probeDefaultPorts: Bool = true,
                        customEndpoints: [URL] = [], now: Date = Date()) async -> AIMonitorResult {
        let started = Date()
        let context = AIDetectionContext(candidates: candidates, samples: samples, http: http,
                                         probeDefaultPorts: probeDefaultPorts, customEndpoints: customEndpoints)

        // Specialised providers match disjoint process names, so they can run concurrently.
        let specialised: [AIProviderResult] = await withTaskGroup(of: (Int, AIProviderResult).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.detect(in: context, claimed: [])) }
            }
            var results: [(Int, AIProviderResult)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var workloads: [AIWorkload] = []
        var claimed = Set<Int32>()
        for result in specialised {
            for workload in result.workloads {
                // A process claimed by an earlier provider wins.
                let pids = workload.primaryPIDs
                if !pids.isEmpty, pids.allSatisfy({ claimed.contains($0) }) { continue }
                if workloads.contains(where: { $0.id == workload.id }) { continue }
                claimed.formUnion(workload.processPIDs)
                workloads.append(workload)
            }
        }
        let genericResult = await generic.detect(in: context, claimed: claimed)
        workloads += genericResult.workloads.filter { w in !workloads.contains { $0.id == w.id } }

        workloads = workloads.map { enrich($0, samples: context.samples, now: now) }
        workloads.sort(by: Self.displayOrder)

        let ids = Set(workloads.map(\.id))
        for id in ids { lastSeen[id] = now }
        // Keep timelines of workloads that disappeared for up to 30 minutes, then drop them.
        for (id, seen) in lastSeen where !ids.contains(id) && now.timeIntervalSince(seen) > HistoryWindow.thirtyMinutes.duration {
            lastSeen[id] = nil
            timelines[id] = nil
            lastActivity[id] = nil
        }
        throughput.forget(except: Set(lastSeen.keys))
        ollamaExpiry = ollamaExpiry.filter { key, _ in lastSeen.keys.contains { key.hasPrefix($0) } }

        let statuses = specialised.map(\.status) + [genericResult.status]
        return AIMonitorResult(workloads: workloads, statuses: statuses, timelines: timelines, timestamp: now,
                               duration: Date().timeIntervalSince(started))
    }

    static func displayOrder(_ a: AIWorkload, _ b: AIWorkload) -> Bool {
        func rank(_ w: AIWorkload) -> Int {
            switch w.state {
            case .modelLoaded: return 0
            case .processOnly: return 1
            case .idle: return 2
            case .apiUnreachable: return 3
            }
        }
        if a.activity.level != b.activity.level { return a.activity.level > b.activity.level }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return (a.processCPUPercent ?? 0) > (b.processCPUPercent ?? 0)
    }

    private func enrich(_ input: AIWorkload, samples: [Int32: ProcessSample], now: Date) -> AIWorkload {
        var w = input
        let processes = w.processPIDs.compactMap { samples[$0] }
        let cpu = processes.compactMap(\.cpuPercent)
        let memory = processes.compactMap(\.memoryFootprint)
        let gpu = processes.compactMap(\.gpuTimeShare)
        w.processCPUPercent = cpu.isEmpty ? nil : cpu.reduce(0, +)
        w.processMemory = memory.isEmpty ? nil : memory.reduce(0, +)
        w.processGPUTimeShare = gpu.isEmpty ? nil : gpu.reduce(0, +)

        let tps = throughput.update(id: w.id, runner: w.runner, counters: w.counters, now: now)
        w.tokensPerSecond = tps.rate

        // Ollama refreshes a model's expires_at whenever it serves a request.
        var keepAliveRefreshed = false
        if w.runner == .ollama {
            for model in w.models {
                guard let expiry = model.expiresAt else { continue }
                let key = w.id + "|" + model.identifier
                if let previous = ollamaExpiry[key], expiry.timeIntervalSince(previous) > 0.5 { keepAliveRefreshed = true }
                ollamaExpiry[key] = expiry
            }
        }

        w.activity = Self.activity(for: w, throughput: tps, keepAliveRefreshed: keepAliveRefreshed)
        if w.activity.isBusy { lastActivity[w.id] = now }
        w.lastActivity = lastActivity[w.id]

        var series = timelines[w.id] ?? HistorySeries()
        series.append(w.activity.level, at: now)
        timelines[w.id] = series
        return w
    }

    static func activity(for w: AIWorkload, throughput: ThroughputTracker.Result, keepAliveRefreshed: Bool) -> InferenceActivity {
        if w.counters?.anySlotProcessing == true {
            return .active(evidence: "llama-server reports a slot generating")
        }
        if (w.counters?.requestsProcessing ?? 0) > 0 {
            return .active(evidence: "llama-server reports \(Int(w.counters!.requestsProcessing!)) request(s) processing")
        }
        if throughput.isLive {
            return .active(evidence: "Token counters advanced")
        }
        if keepAliveRefreshed {
            return .likely(evidence: "Ollama refreshed the model's keep-alive timer, so a request was just served")
        }
        guard w.state != .apiUnreachable || !w.processPIDs.isEmpty else { return .unknown }
        if let gpu = w.processGPUTimeShare, gpu >= gpuBusyThreshold {
            return .likely(evidence: "Runner processes have GPU work running \(Format.percent(min(gpu, 1))) of the time")
        }
        if let cpu = w.processCPUPercent, cpu >= cpuBusyThreshold, w.runner != .lmStudio {
            return .likely(evidence: "Runner processes are using \(Format.processCPU(cpu))% CPU")
        }
        if w.counters?.anySlotProcessing == false { return .idle }
        if w.state == .modelLoaded || w.state == .processOnly || w.state == .idle { return .idle }
        return .unknown
    }
}
