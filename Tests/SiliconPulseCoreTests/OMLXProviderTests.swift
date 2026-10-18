import XCTest
@testable import SiliconPulseCore

/// oMLX fixtures follow the shapes of oMLX's `/health`, `/v1/models/status` and `/api/status` handlers.
enum OMLXFixtures {
    static func health(status: String = "healthy", models: Int = 3, loaded: Int = 1) -> String {
        #"{"status":"\#(status)","default_model":"Qwen3-8B-4bit","engine_pool":{"model_count":\#(models),"loaded_count":\#(loaded),"final_ceiling":0,"current_model_memory":5033164800},"mcp":null}"#
    }

    static let modelsStatusOneLoaded = """
    {"final_ceiling":0,"current_model_memory":5033164800,"model_count":3,"loaded_count":1,"models":[
      {"id":"Qwen3-8B-4bit","model_path":"/Users/me/.omlx/models/Qwen3-8B-4bit","loaded":true,"is_loading":false,
       "estimated_size":4900000000,"actual_size":5033164800,"pinned":false,"engine_type":"batched","model_type":"llm",
       "config_model_type":"qwen3","model_context_length":40960,"max_context_window":32768,"is_helper":false},
      {"id":"gemma-3-12b-it-4bit","loaded":false,"is_loading":false,"estimated_size":7100000000,"actual_size":null,"model_type":"vlm"},
      {"id":"bge-m3","loaded":false,"is_loading":false,"estimated_size":600000000,"model_type":"embedding"}
    ]}
    """

    static let modelsStatusNoneLoaded = """
    {"model_count":2,"loaded_count":0,"models":[
      {"id":"Qwen3-8B-4bit","loaded":false,"is_loading":false,"estimated_size":4900000000},
      {"id":"bge-m3","loaded":false,"is_loading":false,"estimated_size":600000000}
    ]}
    """

    static func apiStatus(active: Int = 0, requests: Int = 0, averageTPS: Double = 0) -> String {
        """
        {"status":"ok","version":"0.6.3","uptime_seconds":812.4,"models_discovered":3,"models_loaded":1,"models_loading":0,
         "default_model":"Qwen3-8B-4bit","loaded_models":["Qwen3-8B-4bit"],"total_requests":\(requests),
         "active_requests":\(active),"waiting_requests":0,"total_prompt_tokens":1200,"total_completion_tokens":3400,
         "total_cached_tokens":0,"cache_efficiency":0.0,"avg_prefill_tps":820.5,"avg_generation_tps":\(averageTPS),
         "model_memory_used":5033164800,"model_memory_max":null}
        """
    }
}

final class OMLXProviderTests: XCTestCase {
    private func samples(_ candidates: [AIProcessInfo]) -> [ProcessSample] { candidates.map(\.sample) }

    /// `omlx serve` after `setproctitle("omlx-server")`: argv is overwritten, so only the title and the
    /// listening socket identify the server.
    private func cliServer(port: UInt16 = 8000, gpu: Double? = nil) -> AIProcessInfo {
        .make(pid: 4100, name: "Python", path: "/opt/homebrew/Cellar/omlx/0.6.3/libexec/bin/python3.11",
              args: ["omlx-server"], ports: [port], cpu: 3, memory: 5_400_000_000, gpu: gpu)
    }

    func testProcessRoles() {
        XCTAssertEqual(OMLXProvider.role(of: cliServer()), .server)
        let preTitle = AIProcessInfo.make(pid: 1, name: "python3.11", path: "/opt/homebrew/bin/python3.11",
                                          args: ["/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/omlx", "serve", "--port", "8123"])
        XCTAssertEqual(OMLXProvider.role(of: preTitle), .server)
        let module = AIProcessInfo.make(pid: 2, name: "python3", path: "/Applications/oMLX.app/Contents/Resources/Python/cpython-3.11/bin/python3",
                                        args: ["python3", "-m", "omlx.cli", "serve", "--base-path", "/Users/me/.omlx", "--port", "8000"])
        XCTAssertEqual(OMLXProvider.role(of: module), .server)
        let app = AIProcessInfo.make(pid: 3, name: "oMLX", path: "/Applications/oMLX.app/Contents/MacOS/oMLX")
        XCTAssertEqual(OMLXProvider.role(of: app), .app)
        let download = AIProcessInfo.make(pid: 4, name: "python3.11", path: "/opt/homebrew/bin/python3.11",
                                          args: ["python3.11", "/opt/homebrew/bin/omlx", "download", "Qwen3-8B"])
        XCTAssertNil(OMLXProvider.role(of: download), "only the server is a workload")
        let mlxLM = AIProcessInfo.make(pid: 5, name: "Python", path: "/usr/bin/python3",
                                       args: ["python3", "-m", "mlx_lm.server", "--model", "x"])
        XCTAssertNil(OMLXProvider.role(of: mlxLM))
        XCTAssertTrue(AICandidateFilter.isCandidate(app.sample))
    }

    func testCLIServerWithLoadedModel() async throws {
        let http = MockHTTPClient(["127.0.0.1:8000/health": .json(OMLXFixtures.health()),
                                   "127.0.0.1:8000/v1/models/status": .json(OMLXFixtures.modelsStatusOneLoaded),
                                   "127.0.0.1:8000/api/status": .json(OMLXFixtures.apiStatus())])
        let server = cliServer()
        let result = await AIMonitor(http: http).refresh(candidates: [server], samples: samples([server]))
        XCTAssertEqual(result.workloads.count, 1, "the generic provider must not list oMLX again")
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.runner, .omlx)
        XCTAssertEqual(w.runner.displayName, "oMLX")
        XCTAssertEqual(w.state, .modelLoaded)
        XCTAssertEqual(w.endpoint, "127.0.0.1:8000")
        XCTAssertEqual(w.runnerVersion, "0.6.3")
        XCTAssertEqual(w.models.map(\.identifier), ["Qwen3-8B-4bit"], "only loaded models are listed as loaded")
        XCTAssertEqual(w.availableModelCount, 3)
        XCTAssertEqual(w.primaryModel?.sizeBytes, 5_033_164_800)
        XCTAssertEqual(w.primaryModel?.contextLength, 40960)
        XCTAssertEqual(w.primaryModel?.family, "qwen3")
        XCTAssertEqual(w.primaryPIDs, [4100])
        XCTAssertEqual(w.processMemory, 5_400_000_000)
        XCTAssertEqual(w.activity, .idle)
        XCTAssertFalse(w.tokensPerSecond.isAvailable, "no completed requests yet: no rate")
    }

    func testActiveRequestsMeanInferenceAndAverageIsNotLive() async throws {
        let http = MockHTTPClient(["127.0.0.1:8000/health": .json(OMLXFixtures.health()),
                                   "127.0.0.1:8000/v1/models/status": .json(OMLXFixtures.modelsStatusOneLoaded),
                                   "127.0.0.1:8000/api/status": .json(OMLXFixtures.apiStatus(active: 2, requests: 14, averageTPS: 61.4))])
        let server = cliServer()
        let monitor = AIMonitor(http: http)
        let result = await monitor.refresh(candidates: [server], samples: samples([server]))
        let w = try XCTUnwrap(result.workloads.first)
        guard case .active(let evidence) = w.activity else { return XCTFail("active_requests > 0 is inference") }
        XCTAssertTrue(evidence.hasPrefix("oMLX reports 2 request"))
        XCTAssertEqual(w.tokensPerSecond.value, 61.4)
        XCTAssertEqual(w.tokensPerSecond.quality, .systemReported, "the runner's own figure, not calculated by SiliconPulse")
        XCTAssertEqual(w.tokensPerSecond.note, "Session average reported by oMLX")

        // Requests finish: idle, and the average stays labeled as an average.
        http.set("127.0.0.1:8000/api/status", .json(OMLXFixtures.apiStatus(active: 0, requests: 15, averageTPS: 60.9)))
        let idleResult = await monitor.refresh(candidates: [server], samples: samples([server]))
        let idle = try XCTUnwrap(idleResult.workloads.first)
        XCTAssertEqual(idle.activity, .idle)
        XCTAssertEqual(idle.tokensPerSecond.value, 60.9)
        XCTAssertNotNil(idle.lastActivity)
    }

    func testModelUnloadedLeavesServerIdle() async throws {
        let http = MockHTTPClient(["127.0.0.1:8000/health": .json(OMLXFixtures.health(models: 2, loaded: 0)),
                                   "127.0.0.1:8000/v1/models/status": .json(OMLXFixtures.modelsStatusNoneLoaded)])
        let server = cliServer()
        let wResult = await AIMonitor(http: http).refresh(candidates: [server], samples: samples([server]))
        let w = try XCTUnwrap(wResult.workloads.first)
        XCTAssertEqual(w.state, .idle)
        XCTAssertTrue(w.models.isEmpty)
        XCTAssertEqual(w.title, "oMLX")
        XCTAssertEqual(w.availableModelCount, 2)
        XCTAssertNil(w.counters, "no /api/status: no request counts")
    }

    func testServerExitRemovesWorkload() async throws {
        let http = MockHTTPClient(["127.0.0.1:8000/health": .json(OMLXFixtures.health()),
                                   "127.0.0.1:8000/v1/models/status": .json(OMLXFixtures.modelsStatusOneLoaded)])
        let server = cliServer()
        let monitor = AIMonitor(http: http)
        let running = await monitor.refresh(candidates: [server], samples: samples([server]))
        XCTAssertEqual(running.workloads.count, 1)
        http.set("127.0.0.1:8000/health", nil)
        http.set("127.0.0.1:8000/v1/models/status", nil)
        let exited = await monitor.refresh(candidates: [], samples: [])
        XCTAssertTrue(exited.workloads.isEmpty)
        XCTAssertNil(exited.featured)
    }

    func testCustomPortFromListeningSocket() async throws {
        let http = MockHTTPClient(["127.0.0.1:8123/health": .json(OMLXFixtures.health()),
                                   "127.0.0.1:8123/v1/models/status": .json(OMLXFixtures.modelsStatusOneLoaded)])
        let server = cliServer(port: 8123)
        let wResult = await AIMonitor(http: http).refresh(candidates: [server], samples: samples([server]))
        let w = try XCTUnwrap(wResult.workloads.first)
        XCTAssertEqual(w.endpoint, "127.0.0.1:8123")
        XCTAssertFalse(http.requested.contains("127.0.0.1:8000/health"), "the socket the server listens on is used, not the default")
    }

    func testAppAndBundledServerAreOneWorkload() async throws {
        let http = MockHTTPClient(["127.0.0.1:8000/health": .json(OMLXFixtures.health()),
                                   "127.0.0.1:8000/v1/models/status": .json(OMLXFixtures.modelsStatusOneLoaded)])
        let app = AIProcessInfo.make(pid: 4000, name: "oMLX", path: "/Applications/oMLX.app/Contents/MacOS/oMLX", memory: 80_000_000)
        let server = AIProcessInfo.make(pid: 4001, parent: 4000, name: "python3",
                                        path: "/Applications/oMLX.app/Contents/Resources/Python/cpython-3.11/bin/python3",
                                        args: ["omlx-server"], ports: [8000], memory: 5_000_000_000)
        let worker = AIProcessInfo.make(pid: 4002, parent: 4001, name: "python3",
                                        path: "/Applications/oMLX.app/Contents/Resources/Python/cpython-3.11/bin/python3",
                                        args: ["python3", "-m", "omlx._hf_download_worker"], memory: 20_000_000)
        let all = [app, server, worker]
        let result = await AIMonitor(http: http).refresh(candidates: all, samples: samples(all))
        XCTAssertEqual(result.workloads.count, 1)
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.primaryPIDs, [4000, 4001])
        XCTAssertEqual(Set(w.processPIDs), [4000, 4001, 4002])
        XCTAssertEqual(w.processMemory, 5_100_000_000)
        XCTAssertTrue(w.evidence.contains { $0.contains("Managed by the oMLX app") })
    }

    func testAppWithStoppedServer() async throws {
        let app = AIProcessInfo.make(pid: 4000, name: "oMLX", path: "/Applications/oMLX.app/Contents/MacOS/oMLX")
        let result = await AIMonitor(http: MockHTTPClient()).refresh(candidates: [app], samples: samples([app]))
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.runner, .omlx)
        XCTAssertEqual(w.state, .apiUnreachable)
    }

    func testAPIKeyRequiredFallsBackToHealth() async throws {
        let http = MockHTTPClient(["127.0.0.1:8000/health": .json(OMLXFixtures.health(loaded: 2)),
                                   "127.0.0.1:8000/v1/models/status": .status(401),
                                   "127.0.0.1:8000/api/status": .status(401)])
        let server = cliServer()
        let wResult = await AIMonitor(http: http).refresh(candidates: [server], samples: samples([server]))
        let w = try XCTUnwrap(wResult.workloads.first)
        XCTAssertEqual(w.runner, .omlx)
        XCTAssertEqual(w.state, .modelLoaded, "/health still says two models are loaded")
        XCTAssertTrue(w.models.isEmpty, "names are not invented")
        XCTAssertTrue(w.evidence.contains { $0.contains("API key") })
    }

    func testPreloadingServerAnswers503() async throws {
        let http = MockHTTPClient(["127.0.0.1:8000/health": .statusJSON(503, OMLXFixtures.health(status: "loading", loaded: 0)),
                                   "127.0.0.1:8000/v1/models/status": .json(OMLXFixtures.modelsStatusNoneLoaded)])
        let server = cliServer()
        let wResult = await AIMonitor(http: http).refresh(candidates: [server], samples: samples([server]))
        let w = try XCTUnwrap(wResult.workloads.first)
        XCTAssertEqual(w.runner, .omlx)
        XCTAssertEqual(w.state, .idle)
        XCTAssertTrue(w.evidence.contains { $0.contains("preloading") })
    }

    func testDefaultPortProbeRequiresOMLXSignature() async throws {
        // vLLM and other servers also default to port 8000; a bare /health must not be taken for oMLX.
        let other = MockHTTPClient(["127.0.0.1:8000/health": .json(#"{"status":"ok"}"#)])
        let none = await AIMonitor(http: other).refresh(candidates: [], samples: [])
        XCTAssertFalse(none.workloads.contains { $0.runner == .omlx })

        let omlx = MockHTTPClient(["127.0.0.1:8000/health": .json(OMLXFixtures.health()),
                                   "127.0.0.1:8000/v1/models/status": .json(OMLXFixtures.modelsStatusOneLoaded)])
        let found = await AIMonitor(http: omlx).refresh(candidates: [], samples: [])
        let w = try XCTUnwrap(found.workloads.first { $0.runner == .omlx })
        XCTAssertTrue(w.processPIDs.isEmpty)
        XCTAssertTrue(w.evidence.contains("No oMLX process visible to SiliconPulse"))
    }

    func testCustomEndpointPointingAtOMLXIsNotDuplicated() async throws {
        let http = MockHTTPClient(["127.0.0.1:8000/health": .json(OMLXFixtures.health()),
                                   "127.0.0.1:8000/v1/models/status": .json(OMLXFixtures.modelsStatusOneLoaded),
                                   "127.0.0.1:8000/v1/models": .json(#"{"object":"list","data":[{"id":"Qwen3-8B-4bit","owned_by":"omlx"}]}"#)])
        let server = cliServer()
        let result = await AIMonitor(http: http).refresh(candidates: [server], samples: samples([server]),
                                                         customEndpoints: [URL(string: "http://127.0.0.1:8000")!])
        XCTAssertEqual(result.workloads.map(\.runner), [.omlx])
    }
}
