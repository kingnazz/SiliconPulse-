import Foundation

/// oMLX (github.com/jundot/omlx): an MLX inference server for Apple Silicon with an OpenAI-compatible API,
/// run as `omlx serve` (CLI or Homebrew service) or managed by the oMLX menu bar app.
///
/// Process evidence: the server sets its process title to `omlx-server`; launched as `omlx serve` or
/// `python -m omlx.cli serve`; the app is `oMLX.app` and runs the server from its bundled Python.
/// Because the process title overwrites argv on macOS, the port usually comes from the server's
/// listening sockets rather than its arguments.
///
/// API (all read-only, none of them intercept requests):
/// - `GET /health` — identifies oMLX (`engine_pool`), loaded/available counts; 503 while preloading.
/// - `GET /v1/models/status` — every model with `loaded`, `is_loading`, sizes and context length.
/// - `GET /api/status` — active and waiting requests, and server-side generation averages.
/// The last two require the API key when one is configured; detection then falls back to `/health`.
public struct OMLXProvider: AIProvider {
    public let runner = AIRunner.omlx
    public static let defaultPort = 8000
    static let processTitle = "omlx-server"

    public init() {}

    enum Role { case app, server }

    static func role(of p: AIProcessInfo) -> Role? {
        let path = p.sample.executablePath ?? ""
        if path.hasSuffix("/oMLX.app/Contents/MacOS/oMLX") { return .app }
        let args = p.arguments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = args.first, (first as NSString).lastPathComponent == processTitle { return .server }
        if p.sample.name == processTitle { return .server }
        let serves = args.contains("serve")
        if serves, let index = args.firstIndex(of: "-m"), index + 1 < args.count, args[index + 1] == "omlx.cli" { return .server }
        if serves, args.prefix(2).contains(where: { ($0 as NSString).lastPathComponent == "omlx" }) { return .server }
        // The app's bundled interpreter only ever runs the oMLX server.
        if path.contains("/oMLX.app/Contents/"), p.executableName.hasPrefix("python") { return .server }
        return nil
    }

    public func detect(in context: AIDetectionContext, claimed: Set<Int32>) async -> AIProviderResult {
        let matched = context.candidates.filter { !claimed.contains($0.pid) }.compactMap { p in Self.role(of: p).map { (p, $0) } }
        let apps = matched.filter { $0.1 == .app }.map(\.0)
        let serverPIDs = Set(matched.filter { $0.1 == .server }.map(\.0.pid))
        // A server started by another matched server (worker processes) belongs to that server.
        let servers = matched.filter { $0.1 == .server && !serverPIDs.contains($0.0.sample.parentPID) }.map(\.0)

        var workloads: [AIWorkload] = []
        var probedPorts = Set<Int>()
        var appsWithServer = Set<Int32>()

        for server in servers {
            let app = apps.first { $0.pid == server.sample.parentPID }
            if let app { appsWithServer.insert(app.pid) }
            let roots = (app.map { [$0.pid] } ?? []) + [server.pid]
            let group = context.processGroup(roots: roots)
            var evidence = ["Process “\(server.name)” (PID \(server.pid)) is the oMLX server"]
            if let app { evidence.append("Managed by the oMLX app (PID \(app.pid))") }

            let argPort = server.argumentValue("--port").flatMap(Int.init)
            let envPort = server.environment["OMLX_PORT"].flatMap(Int.init)
            let listening = group.compactMap { pid in context.candidates.first { $0.pid == pid } }.flatMap(\.listeningPorts)
            let ports = ProviderSupport.candidatePorts(preferred: [argPort, envPort].compactMap { $0 }, listening: listening, limit: 3)
                + (listening.isEmpty && argPort == nil && envPort == nil ? [Self.defaultPort] : [])

            var found: AIWorkload?
            for port in ports {
                guard let base = LoopbackPolicy.baseURL(host: server.argumentValue("--host"), port: port) else { continue }
                probedPorts.insert(port)
                if let w = await query(base: base, context: context, requireSignature: false) {
                    found = w
                    break
                }
            }
            var w = found ?? AIWorkload(id: "omlx:pid:\(server.pid)", runner: .omlx, state: .apiUnreachable,
                                        endpoint: ports.first.map { "127.0.0.1:\($0)" },
                                        evidence: ["oMLX API not answering yet"])
            w.primaryPIDs = roots
            w.processPIDs = group
            w.evidence = evidence + w.evidence
            w.startTime = context.earliestStart(of: [server.pid])
            workloads.append(w)
        }

        // The app is running but its server is stopped.
        for app in apps where !appsWithServer.contains(app.pid) {
            workloads.append(AIWorkload(id: "omlx:pid:\(app.pid)", runner: .omlx, state: .apiUnreachable,
                                        primaryPIDs: [app.pid], processPIDs: context.processGroup(roots: [app.pid]),
                                        evidence: ["oMLX app running (PID \(app.pid))", "Its server is not running"],
                                        startTime: context.earliestStart(of: [app.pid])))
        }

        // A server owned by another user or running elsewhere: only trust a response that is clearly oMLX.
        if servers.isEmpty, context.probeDefaultPorts, !probedPorts.contains(Self.defaultPort),
           let base = LoopbackPolicy.baseURL(host: nil, port: Self.defaultPort),
           var w = await query(base: base, context: context, requireSignature: true) {
            w.evidence.append("No oMLX process visible to SiliconPulse")
            workloads.append(w)
        }

        let summary: String
        if workloads.isEmpty {
            summary = "Not running"
        } else {
            let loaded = workloads.reduce(0) { $0 + $1.models.filter(\.isConfirmedLoaded).count }
            summary = "\(workloads.count) server\(workloads.count == 1 ? "" : "s")" + (loaded > 0 ? ", \(loaded) model\(loaded == 1 ? "" : "s") loaded" : "")
        }
        return AIProviderResult(workloads: workloads, status: AIProviderStatus(runner: .omlx, summary: summary, detected: !workloads.isEmpty))
    }

    /// Reads `/health`, then model status and server status when the API allows it.
    /// - Parameter requireSignature: without process evidence, accept only a `/health` that carries oMLX's `engine_pool`.
    func query(base: URL, context: AIDetectionContext, requireSignature: Bool) async -> AIWorkload? {
        guard let response = try? await context.http.get(ProviderSupport.url(base, "/health"), timeout: context.timeout),
              response.isSuccess || response.status == 503,
              let health = try? JSONDecoder().decode(OMLXHealthResponse.self, from: response.body),
              health.status != nil else { return nil }
        if requireSignature && health.engine_pool == nil { return nil }

        let endpoint = ProviderSupport.endpointString(base)
        async let statusCall = try? context.http.getJSON(OMLXModelsStatusResponse.self, ProviderSupport.url(base, "/v1/models/status"), timeout: context.timeout)
        async let serverCall = try? context.http.getJSON(OMLXServerStatusResponse.self, ProviderSupport.url(base, "/api/status"), timeout: context.timeout)
        let modelsStatus = await statusCall
        let server = await serverCall

        var evidence = ["oMLX API answered at \(endpoint)"]
        if let version = server?.version { evidence.append("oMLX \(version)") }
        if health.status == "loading" { evidence.append("Server is still preloading pinned models") }

        var models: [AIModelInfo] = []
        var available: Int?
        if let entries = modelsStatus?.models {
            available = entries.count
            for entry in entries where entry.loaded == true {
                guard let id = entry.id, !id.isEmpty else { continue }
                let size = (entry.actual_size ?? 0) > 0 ? entry.actual_size : entry.estimated_size
                models.append(AIModelInfo(identifier: id, displayName: entry.model_alias ?? (id as NSString).lastPathComponent,
                                          family: entry.config_model_type ?? entry.model_type, format: "mlx",
                                          contextLength: entry.model_context_length ?? entry.max_context_window,
                                          sizeBytes: size, source: "oMLX /v1/models/status"))
            }
            let loading = entries.filter { $0.is_loading == true }.compactMap(\.id)
            if !loading.isEmpty { evidence.append("Loading \(loading.joined(separator: ", "))") }
            evidence.append("\(models.count) of \(entries.count) model\(entries.count == 1 ? "" : "s") loaded")
        } else if let loadedIDs = server?.loaded_models {
            // /api/status names loaded models but without sizes.
            models = loadedIDs.map { AIModelInfo(identifier: $0, displayName: ($0 as NSString).lastPathComponent, format: "mlx", source: "oMLX /api/status") }
            available = server?.models_discovered
        } else {
            available = health.engine_pool?.model_count
            if let loaded = health.engine_pool?.loaded_count, loaded > 0 {
                evidence.append("\(loaded) model\(loaded == 1 ? "" : "s") loaded; names need the oMLX API key")
            } else {
                evidence.append("Model details need the oMLX API key; only /health is readable")
            }
        }

        var counters = AIRuntimeCounters()
        if let server {
            counters.requestsProcessing = server.active_requests.map(Double.init)
            if let avg = server.avg_generation_tps, avg > 0, (server.total_requests ?? 0) > 0 {
                counters.reportedAverageTokensPerSecond = avg
            }
            evidence.append("Request counts from /api/status")
        }

        let loadedCount = models.isEmpty ? (health.engine_pool?.loaded_count ?? 0) : models.count
        var w = AIWorkload(id: "omlx@\(endpoint)", runner: .omlx, state: loadedCount > 0 ? .modelLoaded : .idle, endpoint: endpoint,
                           runnerVersion: server?.version, models: models, evidence: evidence,
                           counters: server == nil ? nil : counters)
        w.availableModelCount = available
        return w
    }
}

// MARK: - oMLX API responses

public struct OMLXHealthResponse: Decodable, Sendable {
    public struct Pool: Decodable, Sendable {
        public var model_count: Int?
        public var loaded_count: Int?
        public var current_model_memory: UInt64?
    }
    public var status: String?
    public var default_model: String?
    public var engine_pool: Pool?
}

public struct OMLXModelsStatusResponse: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public var id: String?
        public var model_alias: String?
        public var loaded: Bool?
        public var is_loading: Bool?
        public var actual_size: UInt64?
        public var estimated_size: UInt64?
        public var model_type: String?
        public var config_model_type: String?
        public var model_context_length: Int?
        public var max_context_window: Int?
        public var pinned: Bool?
    }
    public var models: [Model]?
    public var loaded_count: Int?
    public var model_count: Int?
}

public struct OMLXServerStatusResponse: Decodable, Sendable {
    public var status: String?
    public var version: String?
    public var models_discovered: Int?
    public var models_loaded: Int?
    public var loaded_models: [String]?
    public var active_requests: Int?
    public var waiting_requests: Int?
    public var total_requests: Int?
    public var total_completion_tokens: Int?
    public var avg_generation_tps: Double?
    public var model_memory_used: UInt64?
}
