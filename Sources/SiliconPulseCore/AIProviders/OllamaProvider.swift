import Foundation

/// Ollama: `ollama serve` (standalone or inside Ollama.app) with runner subprocesses.
/// Loaded models, sizes, GPU offload and context come from `GET /api/ps`.
/// Ollama does not expose live tokens/sec to observers.
public struct OllamaProvider: AIProvider {
    public let runner = AIRunner.ollama
    public static let defaultPort = 11434

    public init() {}

    static func isOllamaProcess(_ p: AIProcessInfo) -> Bool {
        let exe = p.executableName
        return exe == "ollama" || exe == "ollama_llama_server"
    }

    /// Runner subprocesses ("ollama runner …", legacy "ollama_llama_server").
    static func isRunnerProcess(_ p: AIProcessInfo) -> Bool {
        if p.executableName == "ollama_llama_server" { return true }
        return p.executableName == "ollama" && p.arguments.dropFirst().first == "runner"
    }

    public func detect(in context: AIDetectionContext, claimed: Set<Int32>) async -> AIProviderResult {
        let all = context.candidates.filter { Self.isOllamaProcess($0) && !claimed.contains($0.pid) }
        let runnerPIDs = Set(all.filter(Self.isRunnerProcess).map(\.pid))
        var servers = all.filter { !runnerPIDs.contains($0.pid) }
        // A server whose parent is also an Ollama server process is not a separate instance.
        let serverPIDs = Set(servers.map(\.pid))
        servers.removeAll { serverPIDs.contains($0.sample.parentPID) }
        // Ollama.app GUI process (capital O, inside the bundle) counts as evidence but is not the server.
        let guiApps = context.candidates.filter {
            !claimed.contains($0.pid) && ($0.sample.executablePath?.hasSuffix("Ollama.app/Contents/MacOS/Ollama") ?? false)
        }

        var workloads: [AIWorkload] = []
        var probedPorts = Set<Int>()

        for server in servers {
            let envHost = server.environment["OLLAMA_HOST"]
            let parsed = envHost.map { LoopbackPolicy.parseHostPort($0, defaultPort: Self.defaultPort) }
            let ports = ProviderSupport.candidatePorts(preferred: [parsed?.port ?? Self.defaultPort], listening: server.listeningPorts, limit: 2)
            var evidence = ["Process “\(server.name)” (PID \(server.pid))" + (server.arguments.contains("serve") ? " running `ollama serve`" : "")]
            if let envHost { evidence.append("OLLAMA_HOST=\(envHost)") }

            var group = context.processGroup(roots: [server.pid])
            for runner in runnerPIDs where !group.contains(runner) && context.samples[runner]?.parentPID == server.pid {
                group.append(runner)
            }
            let roots = [server.pid] + guiApps.map(\.pid)
            group += guiApps.map(\.pid).filter { !group.contains($0) }

            var workload: AIWorkload?
            for port in ports {
                guard let base = LoopbackPolicy.baseURL(host: parsed?.host, port: port) else { continue }
                probedPorts.insert(port)
                if var found = await query(base: base, context: context) {
                    found.primaryPIDs = roots
                    found.processPIDs = group
                    found.evidence = evidence + found.evidence
                    found.startTime = context.earliestStart(of: [server.pid])
                    workload = found
                    break
                }
            }
            if workload == nil {
                var w = AIWorkload(id: "ollama:pid:\(server.pid)", runner: .ollama, state: .apiUnreachable,
                                   endpoint: ports.first.map { "127.0.0.1:\($0)" }, primaryPIDs: roots, processPIDs: group,
                                   evidence: evidence + ["No answer from the Ollama API"], startTime: context.earliestStart(of: [server.pid]))
                w.models = Self.modelsFromRunnerArguments(context.candidates.filter { group.contains($0.pid) && Self.isRunnerProcess($0) })
                workload = w
            }
            if let workload { workloads.append(workload) }
        }

        // Runner visible only via its API (other user, container, or process list unavailable).
        if servers.isEmpty, context.probeDefaultPorts, !probedPorts.contains(Self.defaultPort),
           let base = LoopbackPolicy.baseURL(host: nil, port: Self.defaultPort),
           var found = await query(base: base, context: context) {
            found.evidence.append("No Ollama process visible to SiliconPulse (it may run as another user or in a container)")
            workloads.append(found)
        }

        let summary: String
        if let w = workloads.first {
            summary = w.state == .modelLoaded ? "\(w.models.count) model\(w.models.count == 1 ? "" : "s") loaded" : w.state.label
        } else {
            summary = "Not running"
        }
        return AIProviderResult(workloads: workloads, status: AIProviderStatus(runner: .ollama, summary: summary, detected: !workloads.isEmpty))
    }

    func query(base: URL, context: AIDetectionContext) async -> AIWorkload? {
        async let psCall = try? context.http.getJSON(OllamaPSResponse.self, ProviderSupport.url(base, "/api/ps"), timeout: context.timeout)
        async let versionCall = try? context.http.getJSON(OllamaVersionResponse.self, ProviderSupport.url(base, "/api/version"), timeout: context.timeout)
        guard let ps = await psCall else { return nil }
        let version = await versionCall
        let models = Self.models(from: ps)
        let endpoint = ProviderSupport.endpointString(base)
        var evidence = ["Ollama API answered at \(endpoint)"]
        if let v = version?.version { evidence.append("Ollama \(v)") }
        return AIWorkload(id: "ollama@\(endpoint)", runner: .ollama, state: models.isEmpty ? .idle : .modelLoaded,
                          endpoint: endpoint, runnerVersion: version?.version, models: models, evidence: evidence)
    }

    static func models(from response: OllamaPSResponse) -> [AIModelInfo] {
        (response.models ?? []).compactMap { m in
            guard let id = m.name ?? m.model, !id.isEmpty else { return nil }
            return AIModelInfo(identifier: id, family: m.details?.family, parameterSize: m.details?.parameter_size,
                               quantization: m.details?.quantization_level, format: m.details?.format,
                               contextLength: m.context_length, sizeBytes: m.size, gpuBytes: m.size_vram,
                               expiresAt: m.expires_at.flatMap(RFC3339.parse), source: "Ollama /api/ps")
        }
    }

    /// When the API is down, runner subprocess arguments may still name the model blob.
    static func modelsFromRunnerArguments(_ runners: [AIProcessInfo]) -> [AIModelInfo] {
        runners.compactMap { r in
            guard let path = r.argumentValue("--model", "-m") else { return nil }
            let ctx = r.argumentValue("--ctx-size", "-c").flatMap(Int.init)
            return AIModelInfo(identifier: ProviderSupport.baseName(ofModelPath: path), contextLength: ctx,
                               source: "runner launch arguments", isConfirmedLoaded: true)
        }
    }
}
