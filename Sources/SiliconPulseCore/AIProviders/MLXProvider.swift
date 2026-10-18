import Foundation

/// Apple MLX tooling: `mlx_lm.server`, `mlx_lm.generate`, `mlx_lm.chat`, `mlx_vlm` and friends.
/// MLX has no status API, so the model comes from launch arguments and activity from process GPU time.
public struct MLXProvider: AIProvider {
    public let runner = AIRunner.mlx
    public static let defaultPort = 8080
    static let markers = ["mlx_lm", "mlx-lm", "mlx_vlm", "mlx-vlm", "mlx_whisper", "mlx-whisper", "mlx_audio", "mlx-audio"]

    public init() {}

    static func marker(in p: AIProcessInfo) -> String? {
        let exe = p.executableName
        if exe.hasPrefix("mlx_") || exe.hasPrefix("mlx-") { return exe }
        for arg in p.arguments.prefix(4) {
            let lower = arg.lowercased()
            if let marker = markers.first(where: { lower.contains($0) }) {
                return (lower as NSString).lastPathComponent.contains(marker) ? (lower as NSString).lastPathComponent : marker
            }
        }
        return nil
    }

    public func detect(in context: AIDetectionContext, claimed: Set<Int32>) async -> AIProviderResult {
        var workloads: [AIWorkload] = []
        let processes = context.candidates.filter { !claimed.contains($0.pid) && Self.marker(in: $0) != nil }
        let pids = Set(processes.map(\.pid))

        for p in processes where !pids.contains(p.sample.parentPID) {
            let tool = Self.marker(in: p) ?? "mlx"
            let group = context.processGroup(roots: [p.pid])
            var evidence = ["Process “\(p.name)” (PID \(p.pid)) running \(tool)"]
            let modelArg = p.argumentValue("--model", "-m")
            let model = modelArg.map {
                AIModelInfo(identifier: $0, displayName: ($0 as NSString).lastPathComponent, format: "mlx",
                            contextLength: p.argumentValue("--max-kv-size").flatMap(Int.init), source: "launch arguments")
            }
            if let modelArg { evidence.append("Launched with --model \(modelArg)") }

            var state: AIWorkloadState = .processOnly
            var endpoint: String?
            if tool.contains("server") {
                let port = p.argumentValue("--port").flatMap(Int.init) ?? Self.defaultPort
                let ports = ProviderSupport.candidatePorts(preferred: [port], listening: p.listeningPorts, limit: 2)
                state = .apiUnreachable
                for candidate in ports {
                    guard let base = LoopbackPolicy.baseURL(host: p.argumentValue("--host"), port: candidate) else { continue }
                    if (try? await context.http.getJSON(OpenAIModelsResponse.self, ProviderSupport.url(base, "/v1/models"), timeout: context.timeout)) != nil {
                        endpoint = ProviderSupport.endpointString(base)
                        evidence.append("OpenAI-compatible API answered at \(endpoint!)")
                        state = model == nil ? .idle : .modelLoaded
                        break
                    }
                }
                if state == .apiUnreachable { evidence.append("Server API not answering yet") }
            }
            workloads.append(AIWorkload(id: "mlx:pid:\(p.pid)", runner: .mlx, state: state, endpoint: endpoint,
                                        models: model.map { [$0] } ?? [], primaryPIDs: [p.pid], processPIDs: group,
                                        evidence: evidence, startTime: context.earliestStart(of: [p.pid])))
        }

        let summary = workloads.isEmpty ? "Not running" : "\(workloads.count) process\(workloads.count == 1 ? "" : "es")"
        return AIProviderResult(workloads: workloads, status: AIProviderStatus(runner: .mlx, summary: summary, detected: !workloads.isEmpty))
    }
}

/// Python inference scripts, other named runners, and any OpenAI-compatible server
/// (candidate processes' listening ports and user-configured endpoints).
public struct GenericInferenceProvider: AIProvider {
    public let runner = AIRunner.pythonInference

    static let pythonKeywords = [
        "transformers", "vllm", "diffusers", "huggingface", "hf_hub", "sentence_transformers", "llama_cpp", "llama-cpp",
        "exllama", "text_generation", "text-generation", "ctransformers", "mlc_llm", "optimum", "accelerate launch",
        "torchrun", "gguf", "whisper",
    ]
    static let namedRunners: [String: String] = [
        "koboldcpp": "KoboldCpp", "llamafile": "llamafile", "local-ai": "LocalAI", "localai": "LocalAI", "jan": "Jan",
        "gpt4all": "GPT4All", "vllm": "vLLM", "tabbyapi": "TabbyAPI", "text-generation-launcher": "TGI",
        "llama-swap": "llama-swap", "lemonade": "Lemonade", "msty": "Msty",
    ]

    public init() {}

    static func keyword(in p: AIProcessInfo) -> String? {
        guard p.executableName.hasPrefix("python") else { return nil }
        let line = p.arguments.dropFirst().joined(separator: " ").lowercased()
        return pythonKeywords.first { line.contains($0) }
    }

    public func detect(in context: AIDetectionContext, claimed: Set<Int32>) async -> AIProviderResult {
        var workloads: [AIWorkload] = []
        var claimedHere = claimed
        var probedPorts = Set<Int>()

        let ordered = context.candidates.sorted { ($0.sample.startTime, $0.pid) < ($1.sample.startTime, $1.pid) }
        for p in ordered where !claimedHere.contains(p.pid) {
            let named = Self.namedRunners[p.executableName]
            let keyword = Self.keyword(in: p)
            guard named != nil || keyword != nil else { continue }
            // Skip children of another matched process; they are folded into its group.
            if let parent = context.samples[p.sample.parentPID], claimedHere.contains(parent.pid) { continue }
            let group = context.processGroup(roots: [p.pid])
            claimedHere.formUnion(group)

            var evidence = ["Process “\(p.name)” (PID \(p.pid))"]
            if let keyword { evidence.append("Command line mentions “\(keyword)”") }
            let modelArg = p.argumentValue("--model", "-m", "--model-id", "--model_name_or_path", "--model-path")

            var models: [AIModelInfo] = modelArg.map {
                [AIModelInfo(identifier: $0, displayName: ($0 as NSString).lastPathComponent, source: "launch arguments")]
            } ?? []
            var state: AIWorkloadState = .processOnly
            var endpoint: String?
            var runner: AIRunner = named != nil ? .openAICompatible : .pythonInference

            for port in p.listeningPorts.prefix(3).map(Int.init) {
                guard let base = LoopbackPolicy.baseURL(host: nil, port: port) else { continue }
                probedPorts.insert(port)
                if let served = await Self.openAIModels(base: base, context: context) {
                    endpoint = ProviderSupport.endpointString(base)
                    runner = .openAICompatible
                    evidence.append("OpenAI-compatible API answered at \(endpoint!)")
                    if !served.isEmpty { models = served }
                    state = models.isEmpty ? .idle : .modelLoaded
                    break
                }
            }
            if let named { evidence.insert("\(named) runner", at: 1) }
            workloads.append(AIWorkload(id: "generic:pid:\(p.pid)", runner: runner, state: state, endpoint: endpoint,
                                        models: models, primaryPIDs: [p.pid], processPIDs: group, evidence: evidence,
                                        startTime: context.earliestStart(of: [p.pid])))
        }

        for url in context.customEndpoints where LoopbackPolicy.isAllowed(url) {
            let port = url.port ?? 80
            guard !probedPorts.contains(port) else { continue }
            let base = URL(string: "\(url.scheme ?? "http")://\(url.host ?? "127.0.0.1"):\(port)") ?? url
            let endpoint = ProviderSupport.endpointString(base)
            if let served = await Self.openAIModels(base: base, context: context) {
                let owner = context.candidates.first { $0.listeningPorts.contains(UInt16(clamping: port)) }
                let pids = owner.map { context.processGroup(roots: [$0.pid]) } ?? []
                workloads.append(AIWorkload(id: "custom@\(endpoint)", runner: .openAICompatible, state: served.isEmpty ? .idle : .modelLoaded,
                                            endpoint: endpoint, models: served, primaryPIDs: owner.map { [$0.pid] } ?? [], processPIDs: pids,
                                            evidence: ["Custom endpoint \(endpoint) answered /v1/models"],
                                            startTime: owner.flatMap { context.earliestStart(of: [$0.pid]) }))
            }
        }

        let summary = workloads.isEmpty ? "None found" : "\(workloads.count) found"
        return AIProviderResult(workloads: workloads, status: AIProviderStatus(runner: .pythonInference, summary: summary, detected: !workloads.isEmpty))
    }

    static func openAIModels(base: URL, context: AIDetectionContext) async -> [AIModelInfo]? {
        guard let response = try? await context.http.getJSON(OpenAIModelsResponse.self, ProviderSupport.url(base, "/v1/models"), timeout: context.timeout),
              let data = response.data else { return nil }
        return data.compactMap { m in
            guard let id = m.id, !id.isEmpty else { return nil }
            return AIModelInfo(identifier: id, displayName: (id as NSString).lastPathComponent, source: "/v1/models")
        }
    }
}
