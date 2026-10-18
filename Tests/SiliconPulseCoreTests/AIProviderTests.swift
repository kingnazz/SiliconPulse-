import XCTest
@testable import SiliconPulseCore

final class AIProviderTests: XCTestCase {
    private func monitor(_ http: MockHTTPClient) -> AIMonitor { AIMonitor(http: http) }

    private func samples(_ candidates: [AIProcessInfo]) -> [ProcessSample] { candidates.map(\.sample) }

    // MARK: No AI

    func testNoServicesRunning() async {
        let http = MockHTTPClient()
        let unrelated = [AIProcessInfo.make(pid: 10, name: "Python", path: "/usr/bin/python3", args: ["python3", "manage.py", "runserver"])]
        let result = await monitor(http).refresh(candidates: unrelated, samples: samples(unrelated))
        XCTAssertTrue(result.workloads.isEmpty)
        XCTAssertNil(result.featured)
        XCTAssertEqual(result.statuses.first { $0.runner == .ollama }?.summary, "Not running")
        XCTAssertTrue(result.statuses.allSatisfy { !$0.detected })
    }

    func testDefaultPortProbingCanBeDisabled() async {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .json(Fixtures.ollamaPSOneModel)])
        let result = await monitor(http).refresh(candidates: [], samples: [], probeDefaultPorts: false)
        XCTAssertTrue(result.workloads.isEmpty)
        XCTAssertTrue(http.requested.isEmpty, "no requests when probing is off and nothing is running")
    }

    // MARK: Ollama

    func testOllamaRunningNoModelLoaded() async throws {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .json(Fixtures.ollamaPSEmpty),
                                   "127.0.0.1:11434/api/version": .json(Fixtures.ollamaVersion)])
        let serve = AIProcessInfo.make(pid: 600, name: "ollama", path: "/opt/homebrew/bin/ollama", args: ["ollama", "serve"], ports: [11434])
        let result = await monitor(http).refresh(candidates: [serve], samples: samples([serve]))
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.runner, .ollama)
        XCTAssertEqual(w.state, .idle)
        XCTAssertTrue(w.models.isEmpty)
        XCTAssertEqual(w.runnerVersion, "0.12.6")
        XCTAssertEqual(w.activity, .idle)
        XCTAssertFalse(w.tokensPerSecond.isAvailable, "Ollama exposes no live throughput")
        XCTAssertEqual(w.tokensPerSecond.quality, .unavailable)
    }

    func testOllamaOneModelLoaded() async throws {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .json(Fixtures.ollamaPSOneModel),
                                   "127.0.0.1:11434/api/version": .json(Fixtures.ollamaVersion)])
        let serve = AIProcessInfo.make(pid: 600, name: "ollama", path: "/opt/homebrew/bin/ollama", args: ["ollama", "serve"],
                                       ports: [11434], cpu: 2, memory: 150_000_000, start: 1_000)
        let runner = AIProcessInfo.make(pid: 601, parent: 600, name: "ollama", path: "/opt/homebrew/bin/ollama",
                                        args: ["ollama", "runner", "--model", "/Users/me/.ollama/models/blobs/sha256-abc", "--port", "50123"],
                                        ports: [50123], cpu: 40, memory: 18_000_000_000, gpu: 0.9, start: 1_100)
        let result = await monitor(http).refresh(candidates: [serve, runner], samples: samples([serve, runner]))
        XCTAssertEqual(result.workloads.count, 1, "runner subprocess must not become a second workload")
        let w = try XCTUnwrap(result.featured)
        XCTAssertEqual(w.state, .modelLoaded)
        XCTAssertEqual(Set(w.processPIDs), [600, 601])
        let model = try XCTUnwrap(w.primaryModel)
        XCTAssertEqual(model.identifier, "qwen3:30b-a3b")
        XCTAssertEqual(model.parameterSize, "30.5B")
        XCTAssertEqual(model.quantization, "Q4_K_M")
        XCTAssertEqual(model.contextLength, 8192)
        XCTAssertEqual(model.sizeBytes, 19_532_111_872)
        XCTAssertEqual(model.gpuOffloadFraction, 1)
        XCTAssertNotNil(model.expiresAt)
        XCTAssertEqual(model.shortName, "qwen3")
        // PROCESS-scope sums over the tree
        XCTAssertEqual(w.processCPUPercent, 42)
        XCTAssertEqual(w.processMemory, 18_150_000_000)
        XCTAssertEqual(w.processGPUTimeShare!, 0.9, accuracy: 1e-9)
        // GPU-time evidence makes inference "likely", never "active", without runner counters.
        guard case .likely = w.activity else { return XCTFail("expected likely, got \(w.activity)") }
        XCTAssertEqual(w.runtime(now: Date(timeIntervalSince1970: 1_600)), 600)
        XCTAssertTrue(w.evidence.contains { $0.contains("answered") })
    }

    func testOllamaPartialGPUOffload() {
        let response = try! JSONDecoder().decode(OllamaPSResponse.self, from: Data(Fixtures.ollamaPSPartialOffload.utf8))
        let model = OllamaProvider.models(from: response)[0]
        XCTAssertEqual(model.gpuOffloadFraction!, 0.5, accuracy: 1e-9)
        XCTAssertNil(model.contextLength, "missing fields stay nil, not zero")
    }

    func testOllamaKeepAliveRefreshMeansRequestServed() async throws {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .json(Fixtures.ollamaPSOneModel)])
        let serve = AIProcessInfo.make(pid: 600, name: "ollama", path: "/opt/homebrew/bin/ollama", args: ["ollama", "serve"], cpu: 0)
        let m = monitor(http)
        _ = await m.refresh(candidates: [serve], samples: samples([serve]))
        http.set("127.0.0.1:11434/api/ps", .json(Fixtures.ollamaPSOneModel.replacingOccurrences(of: "06:05:00", with: "06:06:30")))
        let second = await m.refresh(candidates: [serve], samples: samples([serve]))
        let w = try XCTUnwrap(second.workloads.first)
        guard case .likely(let evidence) = w.activity else { return XCTFail("expected likely, got \(w.activity)") }
        XCTAssertTrue(evidence.contains("keep-alive"))
        XCTAssertNotNil(w.lastActivity)
    }

    func testOllamaAPIUnreachable() async throws {
        let http = MockHTTPClient()  // every request fails like a closed port
        let serve = AIProcessInfo.make(pid: 600, name: "ollama", path: "/opt/homebrew/bin/ollama", args: ["ollama", "serve"])
        let result = await monitor(http).refresh(candidates: [serve], samples: samples([serve]))
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.state, .apiUnreachable)
        XCTAssertTrue(w.models.isEmpty)
        XCTAssertEqual(result.statuses.first { $0.runner == .ollama }?.summary, "API not responding")
    }

    func testOllamaRespectsOLLAMA_HOST() async throws {
        let http = MockHTTPClient(["127.0.0.1:11500/api/ps": .json(Fixtures.ollamaPSOneModel)])
        let serve = AIProcessInfo.make(pid: 600, name: "ollama", path: "/usr/local/bin/ollama", args: ["ollama", "serve"],
                                       env: ["OLLAMA_HOST": "0.0.0.0:11500"])
        let result = await monitor(http).refresh(candidates: [serve], samples: samples([serve]))
        XCTAssertEqual(result.workloads.first?.endpoint, "127.0.0.1:11500")
        XCTAssertEqual(result.workloads.first?.state, .modelLoaded)
    }

    func testOllamaInvalidJSONTreatedAsUnreachable() async throws {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .text("<html>not json</html>")])
        let serve = AIProcessInfo.make(pid: 600, name: "ollama", args: ["ollama", "serve"])
        let result = await monitor(http).refresh(candidates: [serve], samples: samples([serve]))
        XCTAssertEqual(result.workloads.first?.state, .apiUnreachable)
    }

    func testOllamaWrongStatusTreatedAsUnreachable() async {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .status(500)])
        let serve = AIProcessInfo.make(pid: 600, name: "ollama", args: ["ollama", "serve"])
        let result = await monitor(http).refresh(candidates: [serve], samples: samples([serve]))
        XCTAssertEqual(result.workloads.first?.state, .apiUnreachable)
    }

    func testOllamaVisibleOnlyThroughAPI() async throws {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .json(Fixtures.ollamaPSOneModel)])
        let result = await monitor(http).refresh(candidates: [], samples: [])
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.runner, .ollama)
        XCTAssertTrue(w.processPIDs.isEmpty)
        XCTAssertTrue(w.evidence.contains { $0.contains("No Ollama process visible") })
    }

    func testOllamaTimeoutDoesNotBlockOtherProviders() async throws {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .timeout,
                                   "127.0.0.1:1234/api/v0/models": .json(Fixtures.lmStudioV0)])
        let serve = AIProcessInfo.make(pid: 600, name: "ollama", args: ["ollama", "serve"])
        let lms = AIProcessInfo.make(pid: 900, name: "LM Studio", path: "/Applications/LM Studio.app/Contents/MacOS/LM Studio")
        let result = await monitor(http).refresh(candidates: [serve, lms], samples: samples([serve, lms]))
        XCTAssertEqual(Set(result.workloads.map(\.runner)), [.ollama, .lmStudio])
        XCTAssertEqual(result.workloads.first { $0.runner == .lmStudio }?.state, .modelLoaded)
    }

    // MARK: LM Studio

    func testLMStudioV0OneModelLoaded() async throws {
        let http = MockHTTPClient(["127.0.0.1:1234/api/v0/models": .json(Fixtures.lmStudioV0)])
        let app = AIProcessInfo.make(pid: 900, name: "LM Studio", path: "/Applications/LM Studio.app/Contents/MacOS/LM Studio", memory: 500_000_000)
        let helper = AIProcessInfo.make(pid: 901, parent: 900, name: "LM Studio Helper",
                                        path: "/Applications/LM Studio.app/Contents/Frameworks/LM Studio Helper.app/Contents/MacOS/LM Studio Helper",
                                        memory: 17_000_000_000)
        let result = await monitor(http).refresh(candidates: [app, helper], samples: samples([app, helper]))
        XCTAssertEqual(result.workloads.count, 1)
        let w = try XCTUnwrap(result.featured)
        XCTAssertEqual(w.runner, .lmStudio)
        XCTAssertEqual(w.state, .modelLoaded)
        XCTAssertEqual(w.models.map(\.identifier), ["qwen3-30b-a3b"], "not-loaded models are excluded")
        XCTAssertEqual(w.primaryModel?.contextLength, 8192)
        XCTAssertEqual(w.primaryModel?.quantization, "Q4_K_M")
        XCTAssertEqual(w.processMemory, 17_500_000_000)
        XCTAssertFalse(w.tokensPerSecond.isAvailable)
    }

    func testLMStudioV1PreferredWithDisplayName() async throws {
        let http = MockHTTPClient(["127.0.0.1:1234/api/v1/models": .json(Fixtures.lmStudioV1),
                                   "127.0.0.1:1234/api/v0/models": .json(Fixtures.lmStudioV0NoneLoaded)])
        let app = AIProcessInfo.make(pid: 900, name: "LM Studio", path: "/Applications/LM Studio.app/Contents/MacOS/LM Studio")
        let result = await monitor(http).refresh(candidates: [app], samples: samples([app]))
        let model = try XCTUnwrap(result.featured?.primaryModel)
        XCTAssertEqual(model.displayName, "Qwen3 30B A3B")
        XCTAssertEqual(model.shortName, "Qwen3")
        XCTAssertEqual(model.parameterSize, "30B")
        XCTAssertEqual(model.contextLength, 8192)
        XCTAssertEqual(model.sizeBytes, 18_556_685_248)
        XCTAssertEqual(result.featured?.models.count, 1, "models without loaded instances are excluded")
    }

    func testLMStudioRunningNoModel() async throws {
        let http = MockHTTPClient(["127.0.0.1:1234/api/v0/models": .json(Fixtures.lmStudioV0NoneLoaded)])
        let app = AIProcessInfo.make(pid: 900, name: "LM Studio", path: "/Applications/LM Studio.app/Contents/MacOS/LM Studio")
        let result = await monitor(http).refresh(candidates: [app], samples: samples([app]))
        XCTAssertEqual(result.workloads.first?.state, .idle)
        XCTAssertEqual(result.workloads.first?.models.count, 0)
    }

    func testLMStudioServerOff() async throws {
        let http = MockHTTPClient()
        let app = AIProcessInfo.make(pid: 900, name: "LM Studio", path: "/Applications/LM Studio.app/Contents/MacOS/LM Studio")
        let result = await monitor(http).refresh(candidates: [app], samples: samples([app]))
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.state, .apiUnreachable)
        XCTAssertTrue(w.evidence.contains { $0.contains("Developer tab") })
    }

    func testLMStudioOpenAIFallbackDoesNotClaimLoaded() async throws {
        let http = MockHTTPClient(["127.0.0.1:1234/v1/models": .json(Fixtures.openAIModels)])
        let app = AIProcessInfo.make(pid: 900, name: "LM Studio", path: "/Applications/LM Studio.app/Contents/MacOS/LM Studio")
        let result = await monitor(http).refresh(candidates: [app], samples: samples([app]))
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.state, .idle)
        XCTAssertEqual(w.models.first?.isConfirmedLoaded, false)
    }

    func testPort1234WithoutLMStudioProcessNeedsNativeAPI() async {
        // A generic OpenAI server on 1234 must not be labeled LM Studio.
        let http = MockHTTPClient(["127.0.0.1:1234/v1/models": .json(Fixtures.openAIModels)])
        let result = await monitor(http).refresh(candidates: [], samples: [])
        XCTAssertFalse(result.workloads.contains { $0.runner == .lmStudio })
    }

    // MARK: llama.cpp

    func testLlamaServerThroughputFromMetrics() async throws {
        let http = MockHTTPClient(["127.0.0.1:8080/props": .json(Fixtures.llamaProps),
                                   "127.0.0.1:8080/slots": .json(Fixtures.llamaSlots(decoded: 10, processing: true)),
                                   "127.0.0.1:8080/metrics": .text(Fixtures.llamaMetrics(tokens: 1_000, seconds: 25))])
        let server = AIProcessInfo.make(pid: 800, name: "llama-server", path: "/opt/homebrew/bin/llama-server",
                                        args: ["llama-server", "-m", "/models/Qwen3-30B-A3B-Q4_K_M.gguf", "-c", "8192", "-ngl", "99", "--metrics"],
                                        ports: [8080])
        let m = monitor(http)
        let first = await m.refresh(candidates: [server], samples: samples([server]), now: Date(timeIntervalSince1970: 2_000))
        let w1 = try XCTUnwrap(first.workloads.first)
        XCTAssertEqual(w1.state, .modelLoaded)
        XCTAssertEqual(w1.primaryModel?.identifier, "Qwen3-30B-A3B-Q4_K_M")
        XCTAssertEqual(w1.primaryModel?.contextLength, 8192)
        XCTAssertEqual(w1.primaryModel?.gpuLayers, 99)
        XCTAssertFalse(w1.tokensPerSecond.isAvailable, "needs two readings")
        guard case .active = w1.activity else { return XCTFail("slot processing should be active") }

        // 400 more tokens over 10 s of decode time = 40 tok/s.
        http.set("127.0.0.1:8080/metrics", .text(Fixtures.llamaMetrics(tokens: 1_400, seconds: 35)))
        let second = await m.refresh(candidates: [server], samples: samples([server]), now: Date(timeIntervalSince1970: 2_005))
        let w2 = try XCTUnwrap(second.workloads.first)
        XCTAssertEqual(w2.tokensPerSecond.value!, 40, accuracy: 1e-9)
        XCTAssertEqual(w2.tokensPerSecond.quality, .calculated)

        // Idle afterwards: the last rate is kept but labeled, and activity becomes idle.
        http.set("127.0.0.1:8080/slots", .json(Fixtures.llamaSlots(decoded: 410, processing: false)))
        let third = await m.refresh(candidates: [server], samples: samples([server]), now: Date(timeIntervalSince1970: 2_010))
        let w3 = try XCTUnwrap(third.workloads.first)
        XCTAssertEqual(w3.activity, .idle)
        XCTAssertEqual(w3.tokensPerSecond.value!, 40, accuracy: 1e-9)
        XCTAssertTrue(w3.tokensPerSecond.note?.contains("Last generation") ?? false)

        // Timeline records activity.
        let timeline = try XCTUnwrap(third.timelines[w3.id])
        XCTAssertEqual(timeline.maximum(in: .fiveMinutes), 1)
    }

    func testLlamaServerThroughputFromSlotsWithoutMetrics() async throws {
        let http = MockHTTPClient(["127.0.0.1:8080/props": .json(Fixtures.llamaProps),
                                   "127.0.0.1:8080/slots": .json(Fixtures.llamaSlots(decoded: 100, processing: true)),
                                   "127.0.0.1:8080/metrics": .status(501)])
        let server = AIProcessInfo.make(pid: 800, name: "llama-server", path: "/opt/homebrew/bin/llama-server", args: ["llama-server", "-m", "m.gguf"])
        let m = monitor(http)
        _ = await m.refresh(candidates: [server], samples: samples([server]), now: Date(timeIntervalSince1970: 100))
        http.set("127.0.0.1:8080/slots", .json(Fixtures.llamaSlots(decoded: 300, processing: true)))
        let r = await m.refresh(candidates: [server], samples: samples([server]), now: Date(timeIntervalSince1970: 105))
        XCTAssertEqual(r.workloads.first?.tokensPerSecond.value ?? 0, 40, accuracy: 1e-9)
        // New request: n_decoded reset to a smaller value counts as new tokens, never negative.
        http.set("127.0.0.1:8080/slots", .json(Fixtures.llamaSlots(decoded: 50, processing: true)))
        let r2 = await m.refresh(candidates: [server], samples: samples([server]), now: Date(timeIntervalSince1970: 110))
        XCTAssertEqual(r2.workloads.first?.tokensPerSecond.value ?? 0, 10, accuracy: 1e-9)
    }

    func testLlamaServerUnreachableKeepsArgumentModel() async throws {
        let http = MockHTTPClient()
        let server = AIProcessInfo.make(pid: 800, name: "llama-server", path: "/opt/homebrew/bin/llama-server",
                                        args: ["llama-server", "--model", "/m/Llama-3.2-3B.gguf", "--port", "9001"])
        let result = await monitor(http).refresh(candidates: [server], samples: samples([server]))
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.state, .apiUnreachable)
        XCTAssertEqual(w.endpoint, "127.0.0.1:9001")
        XCTAssertEqual(w.primaryModel?.identifier, "Llama-3.2-3B")
        XCTAssertEqual(w.primaryModel?.source, "launch arguments")
    }

    func testUnrelatedServerOn8080IsNotLlamaCpp() async {
        let http = MockHTTPClient(["127.0.0.1:8080/props": .json(#"{"name":"some other app"}"#)])
        let result = await monitor(http).refresh(candidates: [], samples: [])
        XCTAssertTrue(result.workloads.isEmpty)
    }

    func testLlamaCLIProcessOnly() async throws {
        let cli = AIProcessInfo.make(pid: 810, name: "llama-cli", path: "/opt/homebrew/bin/llama-cli",
                                     args: ["llama-cli", "-hf", "ggml-org/gemma-3-1b-it-GGUF"], cpu: 300)
        let result = await monitor(MockHTTPClient()).refresh(candidates: [cli], samples: samples([cli]))
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.state, .processOnly)
        XCTAssertEqual(w.primaryModel?.identifier, "ggml-org/gemma-3-1b-it-GGUF")
        guard case .likely = w.activity else { return XCTFail("high CPU is likely inference") }
    }

    // MARK: MLX & generic

    func testMLXServerDetectedFromArguments() async throws {
        let http = MockHTTPClient(["127.0.0.1:8080/v1/models": .json(Fixtures.openAIModels)])
        let mlx = AIProcessInfo.make(pid: 1200, name: "Python", path: "/opt/homebrew/bin/python3.12",
                                     args: ["/opt/homebrew/bin/python3.12", "/Users/me/.venv/bin/mlx_lm.server", "--model", "mlx-community/Qwen3-8B-4bit"],
                                     ports: [8080], gpu: 0.4)
        let result = await monitor(http).refresh(candidates: [mlx], samples: samples([mlx]))
        let w = try XCTUnwrap(result.workloads.first)
        XCTAssertEqual(w.runner, .mlx)
        XCTAssertEqual(w.state, .modelLoaded)
        XCTAssertEqual(w.primaryModel?.identifier, "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(w.primaryModel?.displayName, "Qwen3-8B-4bit")
        XCTAssertEqual(result.workloads.count, 1, "the generic provider must not claim the MLX process again")
        guard case .likely = w.activity else { return XCTFail() }
    }

    func testMultiplePythonProcessesAndChildrenFolded() async throws {
        let parent = AIProcessInfo.make(pid: 1300, name: "python3", path: "/usr/bin/python3",
                                        args: ["python3", "serve.py", "--model", "meta-llama/Llama-3.1-8B", "--use-transformers"], start: 10)
        let worker = AIProcessInfo.make(pid: 1301, parent: 1300, name: "python3", path: "/usr/bin/python3",
                                        args: ["python3", "-c", "from multiprocessing import transformers_worker"], start: 11)
        let other = AIProcessInfo.make(pid: 1400, name: "python3", path: "/usr/bin/python3",
                                       args: ["python3", "-m", "vllm.entrypoints.openai.api_server"], ports: [8000], start: 12)
        let unrelated = AIProcessInfo.make(pid: 1500, name: "python3", path: "/usr/bin/python3", args: ["python3", "-m", "http.server"], start: 13)
        let http = MockHTTPClient(["127.0.0.1:8000/v1/models": .json(#"{"data":[{"id":"Qwen/Qwen2.5-7B-Instruct"}]}"#)])
        let all = [parent, worker, other, unrelated]
        let result = await monitor(http).refresh(candidates: all, samples: samples(all))
        XCTAssertEqual(result.workloads.count, 2)
        let hf = try XCTUnwrap(result.workloads.first { $0.primaryPIDs == [1300] })
        XCTAssertEqual(hf.runner, .pythonInference)
        XCTAssertEqual(Set(hf.processPIDs), [1300, 1301])
        XCTAssertEqual(hf.primaryModel?.identifier, "meta-llama/Llama-3.1-8B")
        let vllm = try XCTUnwrap(result.workloads.first { $0.primaryPIDs == [1400] })
        XCTAssertEqual(vllm.runner, .openAICompatible)
        XCTAssertEqual(vllm.state, .modelLoaded)
        XCTAssertEqual(vllm.primaryModel?.identifier, "Qwen/Qwen2.5-7B-Instruct")
        XCTAssertFalse(result.aiPIDs.contains(1500))
    }

    func testCustomEndpoint() async throws {
        let http = MockHTTPClient(["127.0.0.1:5001/v1/models": .json(Fixtures.openAIModels)])
        let result = await monitor(http).refresh(candidates: [], samples: [], probeDefaultPorts: false,
                                                 customEndpoints: [URL(string: "http://127.0.0.1:5001")!, URL(string: "http://example.com:5001")!])
        XCTAssertEqual(result.workloads.count, 1)
        XCTAssertEqual(result.workloads.first?.runner, .openAICompatible)
        XCTAssertFalse(http.requested.contains { $0.hasPrefix("example.com") }, "non-loopback endpoints are never contacted")
    }

    func testMultipleRunnersOrderedByActivity() async throws {
        let http = MockHTTPClient(["127.0.0.1:11434/api/ps": .json(Fixtures.ollamaPSEmpty),
                                   "127.0.0.1:8080/props": .json(Fixtures.llamaProps),
                                   "127.0.0.1:8080/slots": .json(Fixtures.llamaSlots(decoded: 5, processing: true))])
        let ollama = AIProcessInfo.make(pid: 600, name: "ollama", args: ["ollama", "serve"])
        let llama = AIProcessInfo.make(pid: 800, name: "llama-server", path: "/opt/homebrew/bin/llama-server", args: ["llama-server", "-m", "a.gguf"])
        let result = await monitor(http).refresh(candidates: [ollama, llama], samples: samples([ollama, llama]))
        XCTAssertEqual(result.workloads.map(\.runner), [.llamaCpp, .ollama])
        XCTAssertEqual(result.featured?.runner, .llamaCpp)
    }

    // MARK: Policy

    func testLoopbackPolicy() {
        XCTAssertTrue(LoopbackPolicy.isAllowed(URL(string: "http://127.0.0.1:11434/api/ps")!))
        XCTAssertTrue(LoopbackPolicy.isAllowed(URL(string: "http://localhost:1234")!))
        XCTAssertTrue(LoopbackPolicy.isAllowed(URL(string: "http://[::1]:8080")!))
        XCTAssertFalse(LoopbackPolicy.isAllowed(URL(string: "http://192.168.1.10:11434")!))
        XCTAssertFalse(LoopbackPolicy.isAllowed(URL(string: "https://api.example.com")!))
        XCTAssertFalse(LoopbackPolicy.isAllowed(URL(string: "file:///etc/passwd")!))
        // Bind addresses normalise to loopback; remote hosts are refused.
        XCTAssertEqual(LoopbackPolicy.baseURL(host: "0.0.0.0", port: 11434)?.absoluteString, "http://127.0.0.1:11434")
        XCTAssertNil(LoopbackPolicy.baseURL(host: "10.0.0.5", port: 11434))
    }

    func testHostPortParsing() {
        XCTAssertEqual(LoopbackPolicy.parseHostPort("127.0.0.1:11500", defaultPort: 11434).port, 11500)
        XCTAssertEqual(LoopbackPolicy.parseHostPort("0.0.0.0", defaultPort: 11434).port, 11434)
        XCTAssertEqual(LoopbackPolicy.parseHostPort("http://localhost:8000/", defaultPort: 1).port, 8000)
        XCTAssertNil(LoopbackPolicy.parseHostPort(":11600", defaultPort: 1).host)
        XCTAssertEqual(LoopbackPolicy.parseHostPort("[::1]:9999", defaultPort: 1).host, "::1")
    }

    func testRealClientRefusesRemoteHosts() async {
        let client = URLSessionLocalHTTPClient()
        do {
            _ = try await client.get(URL(string: "http://example.com/")!, timeout: 1)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? LocalHTTPError, .nonLocalHost("example.com"))
        }
    }

    func testRealClientHandlesClosedPort() async {
        // Port 9 (discard) is essentially never open; the client must fail fast, not hang.
        let client = URLSessionLocalHTTPClient()
        let start = Date()
        do {
            _ = try await client.get(URL(string: "http://127.0.0.1:9/")!, timeout: 1)
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}

final class FeaturedWorkloadTests: XCTestCase {
    private func workload(_ id: String, state: AIWorkloadState = .modelLoaded, lastActivity: Date?) -> AIWorkload {
        var w = AIWorkload(id: id, runner: .ollama, state: state, models: [AIModelInfo(identifier: id, source: "test")])
        w.lastActivity = lastActivity
        return w
    }

    func testFeaturedPrefersMostRecentlyActiveAndStaysPut() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        // Both loaded; b was active 20 s ago, a 50 s ago: b stays featured while it pauses between requests.
        let result = AIMonitorResult(workloads: [workload("a", lastActivity: now.addingTimeInterval(-50)),
                                                 workload("b", lastActivity: now.addingTimeInterval(-20))],
                                     statuses: [], timelines: [:], timestamp: now, duration: 0)
        XCTAssertEqual(result.featured?.id, "b")
    }

    func testFeaturedFallsBackToLoadedThenAny() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let stale = AIMonitorResult(workloads: [workload("idle", state: .idle, lastActivity: nil),
                                                workload("loaded", lastActivity: now.addingTimeInterval(-600))],
                                    statuses: [], timelines: [:], timestamp: now, duration: 0)
        XCTAssertEqual(stale.featured?.id, "loaded")
        let none = AIMonitorResult(workloads: [workload("idle", state: .apiUnreachable, lastActivity: nil)],
                                   statuses: [], timelines: [:], timestamp: now, duration: 0)
        XCTAssertEqual(none.featured?.id, "idle")
        XCTAssertNil(AIMonitorResult.empty.featured)
    }
}
