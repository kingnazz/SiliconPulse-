import Foundation

/// LM Studio desktop app (and its headless `llmster` / `lms` daemons).
/// The loaded model comes from the REST API (`/api/v1/models`, then `/api/v0/models`),
/// falling back to the OpenAI-compatible `/v1/models`, whose list does not say what is loaded.
public struct LMStudioProvider: AIProvider {
    public let runner = AIRunner.lmStudio
    public static let defaultPort = 1234

    public init() {}

    static func isLMStudioProcess(_ p: AIProcessInfo) -> Bool {
        let exe = p.executableName
        if exe == "lm studio" || exe.hasPrefix("lm studio helper") || exe == "llmster" { return true }
        if exe == "lms" { return true }
        if let path = p.sample.executablePath, path.contains("/LM Studio.app/") || path.contains("/.lmstudio/") { return true }
        return false
    }

    public func detect(in context: AIDetectionContext, claimed: Set<Int32>) async -> AIProviderResult {
        let processes = context.candidates.filter { Self.isLMStudioProcess($0) && !claimed.contains($0.pid) }
        let pids = Set(processes.map(\.pid))
        // Roots: LM Studio processes whose parent is not itself LM Studio.
        let roots = processes.filter { !pids.contains($0.sample.parentPID) }

        var workloads: [AIWorkload] = []
        var probedDefault = false

        if !roots.isEmpty {
            let rootPIDs = roots.map(\.pid)
            let group = context.processGroup(roots: rootPIDs)
            let listening = processes.flatMap(\.listeningPorts)
            let ports = ProviderSupport.candidatePorts(preferred: [Self.defaultPort], listening: listening, limit: 4)
            let evidence = roots.map { "Process “\($0.name)” (PID \($0.pid))" }

            var workload: AIWorkload?
            for port in ports {
                guard let base = LoopbackPolicy.baseURL(host: nil, port: port) else { continue }
                if port == Self.defaultPort { probedDefault = true }
                if var found = await query(base: base, context: context) {
                    found.primaryPIDs = rootPIDs
                    found.processPIDs = group
                    found.evidence = evidence + found.evidence
                    found.startTime = context.earliestStart(of: rootPIDs)
                    workload = found
                    break
                }
            }
            workloads.append(workload ?? AIWorkload(
                id: "lmstudio:pid:\(rootPIDs[0])", runner: .lmStudio, state: .apiUnreachable, endpoint: nil,
                primaryPIDs: rootPIDs, processPIDs: group,
                evidence: evidence + ["LM Studio's local server is not answering. Turn it on in LM Studio's Developer tab to see the loaded model."],
                startTime: context.earliestStart(of: rootPIDs)))
        }

        if roots.isEmpty, context.probeDefaultPorts, !probedDefault,
           let base = LoopbackPolicy.baseURL(host: nil, port: Self.defaultPort),
           var found = await query(base: base, context: context, requireNativeAPI: true) {
            found.evidence.append("No LM Studio process visible to SiliconPulse")
            workloads.append(found)
        }

        let summary: String
        if let w = workloads.first {
            summary = w.state == .modelLoaded ? "\(w.models.count) model\(w.models.count == 1 ? "" : "s") loaded" : w.state.label
        } else {
            summary = "Not running"
        }
        return AIProviderResult(workloads: workloads, status: AIProviderStatus(runner: .lmStudio, summary: summary, detected: !workloads.isEmpty))
    }

    /// - Parameter requireNativeAPI: without a visible process, only LM Studio's own REST API counts as
    ///   evidence; a bare `/v1/models` on port 1234 could be any server.
    func query(base: URL, context: AIDetectionContext, requireNativeAPI: Bool = false) async -> AIWorkload? {
        let endpoint = ProviderSupport.endpointString(base)

        if let v1 = try? await context.http.getJSON(LMStudioV1ModelsResponse.self, ProviderSupport.url(base, "/api/v1/models"), timeout: context.timeout),
           let list = v1.models, list.isEmpty || list.contains(where: { $0.loaded_instances != nil }) {
            let models = Self.loadedModels(fromV1: list)
            return AIWorkload(id: "lmstudio@\(endpoint)", runner: .lmStudio, state: models.isEmpty ? .idle : .modelLoaded,
                              endpoint: endpoint, models: models, evidence: ["LM Studio REST API (v1) answered at \(endpoint)"])
        }
        if let v0 = try? await context.http.getJSON(LMStudioV0ModelsResponse.self, ProviderSupport.url(base, "/api/v0/models"), timeout: context.timeout),
           let list = v0.data {
            let models = Self.loadedModels(fromV0: list)
            return AIWorkload(id: "lmstudio@\(endpoint)", runner: .lmStudio, state: models.isEmpty ? .idle : .modelLoaded,
                              endpoint: endpoint, models: models, evidence: ["LM Studio REST API (v0) answered at \(endpoint)"])
        }
        guard !requireNativeAPI else { return nil }
        if let openAI = try? await context.http.getJSON(OpenAIModelsResponse.self, ProviderSupport.url(base, "/v1/models"), timeout: context.timeout),
           let list = openAI.data {
            let models = list.compactMap { m -> AIModelInfo? in
                guard let id = m.id, !id.isEmpty else { return nil }
                return AIModelInfo(identifier: id, source: "LM Studio /v1/models", isConfirmedLoaded: false)
            }
            // /v1/models may list downloaded models (JIT loading), so loaded state is not confirmed.
            return AIWorkload(id: "lmstudio@\(endpoint)", runner: .lmStudio, state: .idle, endpoint: endpoint, models: models,
                              evidence: ["OpenAI-compatible API answered at \(endpoint); load state unknown"])
        }
        return nil
    }

    static func loadedModels(fromV0 list: [LMStudioV0ModelsResponse.Model]) -> [AIModelInfo] {
        list.compactMap { m in
            guard let id = m.id, m.state?.lowercased() == "loaded" else { return nil }
            return AIModelInfo(identifier: id, family: m.arch, quantization: m.quantization, format: m.compatibility_type,
                               contextLength: m.loaded_context_length ?? m.max_context_length, source: "LM Studio /api/v0/models")
        }
    }

    static func loadedModels(fromV1 list: [LMStudioV1ModelsResponse.Model]) -> [AIModelInfo] {
        var result: [AIModelInfo] = []
        for m in list {
            guard let instances = m.loaded_instances, !instances.isEmpty, let key = m.key else { continue }
            for instance in instances {
                result.append(AIModelInfo(identifier: instance.id ?? key, displayName: m.display_name, family: m.architecture,
                                          parameterSize: m.params_string, quantization: m.quantization?.name, format: m.format,
                                          contextLength: instance.config?.context_length, sizeBytes: m.size_bytes,
                                          source: "LM Studio /api/v1/models"))
            }
        }
        return result
    }
}
