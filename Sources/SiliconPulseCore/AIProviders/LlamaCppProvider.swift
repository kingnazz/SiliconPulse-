import Foundation

/// llama.cpp tools: `llama-server` (HTTP API) and CLI tools such as `llama-cli`.
/// llama-server is the only common runner that exposes generation counters, so tokens/sec
/// is available when it runs with `--metrics` (or from `/slots`).
public struct LlamaCppProvider: AIProvider {
    public let runner = AIRunner.llamaCpp
    public static let defaultPort = 8080

    public init() {}

    static func isLlamaProcess(_ p: AIProcessInfo) -> Bool {
        let exe = p.executableName
        if exe.hasPrefix("llama-") && exe != "llama-swap" { return true }
        if exe == "server", let path = p.sample.executablePath, path.lowercased().contains("llama") { return true }
        return false
    }

    static func isServer(_ p: AIProcessInfo) -> Bool {
        let exe = p.executableName
        return exe == "llama-server" || exe == "server"
    }

    public func detect(in context: AIDetectionContext, claimed: Set<Int32>) async -> AIProviderResult {
        let processes = context.candidates.filter { Self.isLlamaProcess($0) && !claimed.contains($0.pid) }
        var workloads: [AIWorkload] = []
        var probedDefault = false

        for p in processes {
            let group = context.processGroup(roots: [p.pid])
            let argModel = Self.modelFromArguments(p)
            var evidence = ["Process “\(p.name)” (PID \(p.pid))"]
            if let path = p.argumentValue("-m", "--model") { evidence.append("Launched with model \(ProviderSupport.baseName(ofModelPath: path))") }

            if Self.isServer(p) {
                let argPort = p.argumentValue("--port").flatMap(Int.init)
                let ports = ProviderSupport.candidatePorts(preferred: [argPort ?? Self.defaultPort], listening: p.listeningPorts, limit: 2)
                let host = p.argumentValue("--host")
                var found: AIWorkload?
                for port in ports {
                    guard let base = LoopbackPolicy.baseURL(host: host, port: port) else { continue }
                    if port == Self.defaultPort { probedDefault = true }
                    if let w = await query(base: base, context: context, process: p, argModel: argModel) {
                        found = w
                        break
                    }
                }
                if var w = found {
                    w.primaryPIDs = [p.pid]
                    w.processPIDs = group
                    w.evidence = evidence + w.evidence
                    w.startTime = context.earliestStart(of: [p.pid])
                    workloads.append(w)
                } else {
                    workloads.append(AIWorkload(id: "llamacpp:pid:\(p.pid)", runner: .llamaCpp, state: .apiUnreachable,
                                                endpoint: ports.first.map { "127.0.0.1:\($0)" },
                                                models: argModel.map { [$0] } ?? [], primaryPIDs: [p.pid], processPIDs: group,
                                                evidence: evidence + ["llama-server API not answering"],
                                                startTime: context.earliestStart(of: [p.pid])))
                }
            } else {
                workloads.append(AIWorkload(id: "llamacpp:pid:\(p.pid)", runner: .llamaCpp, state: .processOnly, endpoint: nil,
                                            models: argModel.map { [$0] } ?? [], primaryPIDs: [p.pid], processPIDs: group,
                                            evidence: evidence + ["\(p.executableName) has no HTTP API; details come from its launch arguments"],
                                            startTime: context.earliestStart(of: [p.pid])))
            }
        }

        if processes.isEmpty, context.probeDefaultPorts, !probedDefault,
           let base = LoopbackPolicy.baseURL(host: nil, port: Self.defaultPort),
           var w = await query(base: base, context: context, process: nil, argModel: nil) {
            w.evidence.append("No llama.cpp process visible to SiliconPulse")
            workloads.append(w)
        }

        let summary: String
        if workloads.isEmpty {
            summary = "Not running"
        } else {
            let loaded = workloads.filter { $0.state == .modelLoaded || $0.state == .processOnly }.count
            summary = "\(workloads.count) instance\(workloads.count == 1 ? "" : "s")" + (loaded > 0 ? ", \(loaded) with a model" : "")
        }
        return AIProviderResult(workloads: workloads, status: AIProviderStatus(runner: .llamaCpp, summary: summary, detected: !workloads.isEmpty))
    }

    /// Requires `/props` to look like llama.cpp, so an unrelated server on 8080 is never mistaken for it.
    func query(base: URL, context: AIDetectionContext, process: AIProcessInfo?, argModel: AIModelInfo?) async -> AIWorkload? {
        guard let props = try? await context.http.getJSON(LlamaCppPropsResponse.self, ProviderSupport.url(base, "/props"), timeout: context.timeout),
              props.default_generation_settings != nil || props.model_path != nil || props.total_slots != nil else {
            return nil
        }
        let endpoint = ProviderSupport.endpointString(base)
        async let slotsCall = try? context.http.getJSON([LlamaCppSlot].self, ProviderSupport.url(base, "/slots"), timeout: context.timeout)
        async let metricsCall = try? context.http.getText(ProviderSupport.url(base, "/metrics"), timeout: context.timeout)
        async let modelsCall = try? context.http.getJSON(OpenAIModelsResponse.self, ProviderSupport.url(base, "/v1/models"), timeout: context.timeout)
        let slots = await slotsCall
        let metricsText = await metricsCall
        let openAIModels = await modelsCall

        var evidence = ["llama-server API answered at \(endpoint)"]
        if let build = props.build_info { evidence.append("Build \(build)") }

        let alias = props.model_alias ?? openAIModels?.data?.first?.id
        let pathName = props.model_path.map(ProviderSupport.baseName(ofModelPath:))
        let identifier = alias.map(ProviderSupport.baseName(ofModelPath:)) ?? pathName ?? argModel?.identifier ?? "Unknown model"
        let context_ = props.default_generation_settings?.n_ctx ?? slots?.first?.n_ctx ?? argModel?.contextLength
        let model = AIModelInfo(identifier: identifier, format: "gguf", contextLength: context_, gpuLayers: argModel?.gpuLayers,
                                source: alias != nil || pathName != nil ? "llama-server /props" : "launch arguments")

        var counters = AIRuntimeCounters()
        if let metricsText {
            let metrics = PrometheusParser.parse(metricsText)
            counters.tokensPredictedTotal = metrics["llamacpp:tokens_predicted_total"]
            counters.tokensPredictedSecondsTotal = metrics["llamacpp:tokens_predicted_seconds_total"]
            counters.requestsProcessing = metrics["llamacpp:requests_processing"]
            if counters.tokensPredictedTotal != nil { evidence.append("Generation counters from /metrics") }
        }
        if let slots {
            var decoded: [Int: Int] = [:]
            for (index, slot) in slots.enumerated() {
                decoded[slot.id ?? index] = slot.next_token?.n_decoded ?? 0
            }
            counters.slotDecoded = decoded
            counters.anySlotProcessing = slots.contains { $0.processing }
        }
        let hasCounters = counters.tokensPredictedTotal != nil || counters.slotDecoded != nil
        return AIWorkload(id: "llamacpp@\(endpoint)", runner: .llamaCpp, state: .modelLoaded, endpoint: endpoint,
                          runnerVersion: props.build_info, models: [model], evidence: evidence,
                          counters: hasCounters ? counters : nil)
    }

    static func modelFromArguments(_ p: AIProcessInfo) -> AIModelInfo? {
        let path = p.argumentValue("-m", "--model")
        let hf = p.argumentValue("-hf", "--hf-repo", "-hfr")
        let alias = p.argumentValue("-a", "--alias")
        guard let name = alias ?? path.map(ProviderSupport.baseName(ofModelPath:)) ?? hf else { return nil }
        let ctx = p.argumentValue("-c", "--ctx-size").flatMap(Int.init)
        let ngl = p.argumentValue("-ngl", "--n-gpu-layers", "--gpu-layers").flatMap(Int.init)
        return AIModelInfo(identifier: name, format: "gguf", contextLength: ctx, gpuLayers: ngl, source: "launch arguments")
    }
}
