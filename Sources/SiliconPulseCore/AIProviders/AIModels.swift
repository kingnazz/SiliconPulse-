import Foundation

public enum AIRunner: String, CaseIterable, Sendable, Codable, Identifiable {
    case ollama, lmStudio, llamaCpp, mlx, pythonInference, openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .llamaCpp: return "llama.cpp"
        case .mlx: return "MLX"
        case .pythonInference: return "Python inference"
        case .openAICompatible: return "OpenAI-compatible server"
        }
    }
}

/// One process that may belong to a local AI workload, enriched with the data detection needs.
public struct AIProcessInfo: Sendable, Equatable {
    public var sample: ProcessSample
    /// Launch arguments (argv), empty when unavailable.
    public var arguments: [String]
    /// Only the few environment variables providers care about (for example OLLAMA_HOST).
    public var environment: [String: String]
    public var listeningPorts: [UInt16]

    public init(sample: ProcessSample, arguments: [String] = [], environment: [String: String] = [:], listeningPorts: [UInt16] = []) {
        self.sample = sample
        self.arguments = arguments
        self.environment = environment
        self.listeningPorts = listeningPorts
    }

    public var pid: Int32 { sample.pid }
    public var name: String { sample.name }

    /// Lowercased executable file name, from the path when known.
    public var executableName: String {
        let base = sample.executablePath.map { ($0 as NSString).lastPathComponent } ?? sample.name
        return base.lowercased()
    }

    public var commandLine: String { arguments.joined(separator: " ") }

    /// Value following `--flag` or `--flag=value`, for any of the given spellings.
    public func argumentValue(_ flags: String...) -> String? {
        ArgumentParsing.value(in: arguments, flags: flags)
    }

    public func hasArgument(_ flags: String...) -> Bool {
        arguments.contains { arg in flags.contains { arg == $0 || arg.hasPrefix($0 + "=") } }
    }
}

public enum ArgumentParsing {
    public static func value(in arguments: [String], flags: [String]) -> String? {
        for (index, arg) in arguments.enumerated() {
            for flag in flags {
                if arg == flag, index + 1 < arguments.count { return arguments[index + 1] }
                if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
            }
        }
        return nil
    }
}

public struct AIModelInfo: Identifiable, Equatable, Sendable {
    public var id: String { identifier }
    /// Name the runner uses for the model (e.g. "qwen3:30b-a3b").
    public var identifier: String
    /// Human-readable name when the runner provides one (LM Studio display_name), else the identifier.
    public var displayName: String
    public var family: String?
    public var parameterSize: String?
    public var quantization: String?
    public var format: String?
    public var contextLength: Int?
    /// Model memory as reported by the runner.
    public var sizeBytes: UInt64?
    /// Bytes resident in GPU-accessible memory (Ollama size_vram).
    public var gpuBytes: UInt64?
    /// llama.cpp `-ngl` value when given on the command line.
    public var gpuLayers: Int?
    public var expiresAt: Date?
    /// Where the model identity came from, shown as evidence.
    public var source: String
    /// false when the runner only lists the model and cannot say whether it is loaded.
    public var isConfirmedLoaded: Bool

    public init(identifier: String, displayName: String? = nil, family: String? = nil, parameterSize: String? = nil,
                quantization: String? = nil, format: String? = nil, contextLength: Int? = nil, sizeBytes: UInt64? = nil,
                gpuBytes: UInt64? = nil, gpuLayers: Int? = nil, expiresAt: Date? = nil, source: String,
                isConfirmedLoaded: Bool = true) {
        self.identifier = identifier
        self.displayName = displayName ?? identifier
        self.family = family
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.format = format
        self.contextLength = contextLength
        self.sizeBytes = sizeBytes
        self.gpuBytes = gpuBytes
        self.gpuLayers = gpuLayers
        self.expiresAt = expiresAt
        self.source = source
        self.isConfirmedLoaded = isConfirmedLoaded
    }

    /// Fraction of the model in GPU memory, when the runner reports both figures.
    public var gpuOffloadFraction: Double? {
        guard let sizeBytes, sizeBytes > 0, let gpuBytes else { return nil }
        return min(1, Double(gpuBytes) / Double(sizeBytes))
    }

    /// Short name for the menu bar: "Qwen3-30B-A3B" → "Qwen3", "qwen3:30b-a3b" → "qwen3".
    public var shortName: String { AIModelInfo.shortName(for: displayName) }

    public static func shortName(for name: String) -> String {
        var base = (name as NSString).lastPathComponent
        if base.lowercased().hasSuffix(".gguf") { base = String(base.dropLast(5)) }
        if let colon = base.firstIndex(of: ":") { base = String(base[..<colon]) }
        let separators: Set<Character> = ["-", "_", " ", "."]
        if let cut = base.firstIndex(where: { separators.contains($0) }), cut != base.startIndex {
            base = String(base[..<cut])
        }
        return base.isEmpty ? name : base
    }
}

/// Runner-reported generation counters, turned into tokens/sec by `ThroughputTracker`.
public struct AIRuntimeCounters: Equatable, Sendable {
    /// llama.cpp `llamacpp:tokens_predicted_total`.
    public var tokensPredictedTotal: Double?
    /// llama.cpp `llamacpp:tokens_predicted_seconds_total`.
    public var tokensPredictedSecondsTotal: Double?
    /// llama.cpp `llamacpp:requests_processing`.
    public var requestsProcessing: Double?
    /// llama.cpp `/slots` decoded tokens per slot id (resets per request).
    public var slotDecoded: [Int: Int]?
    /// Any slot currently processing (llama.cpp `/slots`).
    public var anySlotProcessing: Bool?

    public init(tokensPredictedTotal: Double? = nil, tokensPredictedSecondsTotal: Double? = nil, requestsProcessing: Double? = nil,
                slotDecoded: [Int: Int]? = nil, anySlotProcessing: Bool? = nil) {
        self.tokensPredictedTotal = tokensPredictedTotal
        self.tokensPredictedSecondsTotal = tokensPredictedSecondsTotal
        self.requestsProcessing = requestsProcessing
        self.slotDecoded = slotDecoded
        self.anySlotProcessing = anySlotProcessing
    }
}

public enum AIWorkloadState: String, Sendable, Equatable {
    /// The runner's API confirmed at least one loaded model.
    case modelLoaded
    /// Runner present and responding, nothing loaded.
    case idle
    /// Runner process found but its API did not answer.
    case apiUnreachable
    /// Detected from process evidence only; this runner has no API to ask.
    case processOnly

    public var label: String {
        switch self {
        case .modelLoaded: return "Running"
        case .idle: return "No model loaded"
        case .apiUnreachable: return "API not responding"
        case .processOnly: return "Running"
        }
    }
}

public enum InferenceActivity: Equatable, Sendable {
    /// The runner itself says it is generating, or token counters moved.
    case active(evidence: String)
    /// Indirect evidence (GPU or CPU activity of the runner, keep-alive refresh).
    case likely(evidence: String)
    case idle
    case unknown

    public var label: String {
        switch self {
        case .active: return "Inference active"
        case .likely: return "Likely inferring"
        case .idle: return "Idle"
        case .unknown: return "Activity unknown"
        }
    }

    public var evidence: String? {
        switch self {
        case .active(let e), .likely(let e): return e
        case .idle, .unknown: return nil
        }
    }

    public var quality: MetricQuality {
        switch self {
        case .active: return .systemReported
        case .likely: return .estimated
        case .idle: return .estimated
        case .unknown: return .unavailable
        }
    }

    /// 0 idle/unknown, 0.5 likely, 1 active. Used by the timeline.
    public var level: Double {
        switch self {
        case .active: return 1
        case .likely: return 0.5
        case .idle, .unknown: return 0
        }
    }

    public var isBusy: Bool { level > 0 }
}

/// A detected local AI runtime.
public struct AIWorkload: Identifiable, Equatable, Sendable {
    public var id: String
    public var runner: AIRunner
    public var state: AIWorkloadState
    public var endpoint: String?
    public var runnerVersion: String?
    public var models: [AIModelInfo]
    /// Root processes claimed by this workload.
    public var primaryPIDs: [Int32]
    /// Roots plus descendants: used for PROCESS-scope sums.
    public var processPIDs: [Int32]
    public var evidence: [String]
    public var counters: AIRuntimeCounters?
    public var startTime: TimeInterval?

    // Filled in by AIMonitor after detection.
    public var tokensPerSecond: Measured<Double>
    public var activity: InferenceActivity
    public var lastActivity: Date?
    public var processCPUPercent: Double?
    public var processMemory: UInt64?
    public var processGPUTimeShare: Double?

    public init(id: String, runner: AIRunner, state: AIWorkloadState, endpoint: String? = nil, runnerVersion: String? = nil,
                models: [AIModelInfo] = [], primaryPIDs: [Int32] = [], processPIDs: [Int32] = [], evidence: [String] = [],
                counters: AIRuntimeCounters? = nil, startTime: TimeInterval? = nil) {
        self.id = id
        self.runner = runner
        self.state = state
        self.endpoint = endpoint
        self.runnerVersion = runnerVersion
        self.models = models
        self.primaryPIDs = primaryPIDs
        self.processPIDs = processPIDs.isEmpty ? primaryPIDs : processPIDs
        self.evidence = evidence
        self.counters = counters
        self.startTime = startTime
        self.tokensPerSecond = .unavailable("\(runner.displayName) does not expose live generation counters.")
        self.activity = .unknown
    }

    public var primaryModel: AIModelInfo? { models.first }

    public var title: String { primaryModel?.displayName ?? runner.displayName }

    public func runtime(now: Date) -> TimeInterval? {
        startTime.map { max(0, now.timeIntervalSince1970 - $0) }
    }
}

/// What a provider found during one detection pass.
public struct AIProviderStatus: Identifiable, Equatable, Sendable {
    public var id: AIRunner { runner }
    public var runner: AIRunner
    public var summary: String
    public var detected: Bool

    public init(runner: AIRunner, summary: String, detected: Bool) {
        self.runner = runner
        self.summary = summary
        self.detected = detected
    }
}
