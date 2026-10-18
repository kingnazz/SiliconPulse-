import Foundation

/// Everything a provider may look at during one detection pass.
public struct AIDetectionContext: Sendable {
    /// Candidate processes with arguments, selected environment and listening ports.
    public var candidates: [AIProcessInfo]
    /// The full process table, for descendants and start times.
    public var tree: ProcessTree
    public var samples: [Int32: ProcessSample]
    public var http: LocalHTTPClient
    public var timeout: TimeInterval
    /// Also ask the default ports of known runners when no matching process is visible
    /// (runner owned by another user, or running in a container).
    public var probeDefaultPorts: Bool
    /// User-configured OpenAI-compatible endpoints.
    public var customEndpoints: [URL]

    public init(candidates: [AIProcessInfo], samples: [ProcessSample], http: LocalHTTPClient, timeout: TimeInterval = 1.5,
                probeDefaultPorts: Bool = true, customEndpoints: [URL] = []) {
        self.candidates = candidates
        self.tree = ProcessTree(samples)
        var map: [Int32: ProcessSample] = [:]
        for s in samples { map[s.pid] = s }
        for c in candidates where map[c.pid] == nil { map[c.pid] = c.sample }
        self.samples = map
        self.http = http
        self.timeout = timeout
        self.probeDefaultPorts = probeDefaultPorts
        self.customEndpoints = customEndpoints
    }

    /// Roots plus all descendants, de-duplicated, roots first.
    public func processGroup(roots: [Int32]) -> [Int32] {
        var seen = Set<Int32>()
        var result: [Int32] = []
        for pid in roots + roots.flatMap({ tree.descendants(of: $0) }) where seen.insert(pid).inserted {
            result.append(pid)
        }
        return result
    }

    public func earliestStart(of pids: [Int32]) -> TimeInterval? {
        pids.compactMap { samples[$0]?.startTime }.filter { $0 > 0 }.min()
    }
}

public struct AIProviderResult: Sendable {
    public var workloads: [AIWorkload]
    public var status: AIProviderStatus

    public init(workloads: [AIWorkload], status: AIProviderStatus) {
        self.workloads = workloads
        self.status = status
    }
}

/// A detector for one family of local runners.
public protocol AIProvider: Sendable {
    var runner: AIRunner { get }
    /// - Parameter claimed: PIDs already attributed to another provider; must not be claimed again.
    func detect(in context: AIDetectionContext, claimed: Set<Int32>) async -> AIProviderResult
}

/// Cheap first-pass filter deciding which processes deserve argument and socket inspection.
public enum AICandidateFilter {
    static let names: Set<String> = [
        "ollama", "ollama_llama_server", "lm studio", "llmster", "lms", "koboldcpp", "llamafile", "local-ai", "localai",
        "jan", "gpt4all", "vllm", "tabbyapi", "text-generation-launcher", "llama-swap", "lemonade", "msty",
        "omlx", "omlx-server",
    ]

    public static func isCandidate(_ sample: ProcessSample) -> Bool {
        let name = sample.name.lowercased()
        let exe = (sample.executablePath.map { ($0 as NSString).lastPathComponent } ?? sample.name).lowercased()
        if names.contains(name) || names.contains(exe) { return true }
        if exe.hasPrefix("python") || name.hasPrefix("python") { return true }
        if exe.hasPrefix("llama-") || exe.hasPrefix("llama.") || exe.hasPrefix("mlx") || exe.hasPrefix("lm studio") { return true }
        if let path = sample.executablePath {
            if path.contains("/LM Studio.app/") || path.contains("/Ollama.app/") || path.contains("/.lmstudio/") { return true }
            if path.contains("/oMLX.app/") { return true }
            if exe == "server" && path.lowercased().contains("llama") { return true }
        }
        return false
    }
}

enum ProviderSupport {
    static func url(_ base: URL, _ path: String) -> URL {
        URL(string: base.absoluteString + path) ?? base
    }

    static func endpointString(_ base: URL) -> String {
        base.absoluteString.replacingOccurrences(of: "http://", with: "")
    }

    /// Ports to try: explicit/expected ports first, then whatever the processes listen on.
    static func candidatePorts(preferred: [Int], listening: [UInt16], limit: Int = 4) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for port in preferred + listening.map(Int.init) where port > 0 && seen.insert(port).inserted {
            result.append(port)
        }
        return Array(result.prefix(limit))
    }

    static func baseName(ofModelPath path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(5)) }
        return name
    }
}
