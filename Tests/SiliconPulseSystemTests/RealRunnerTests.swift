import Darwin
import Foundation
import XCTest
@testable import SiliconPulseCore
@testable import SiliconPulseSystem

/// Lifecycle check against a real local runner serving a real model, driven by the `real-runner` CI job:
/// detection → generation (activity) → idle → model unload → server exit.
///
/// Environment (all required, otherwise skipped):
/// - `SILICONPULSE_REAL_RUNNER`: `ollama` or `omlx`
/// - `SILICONPULSE_REAL_BASE`: e.g. `http://127.0.0.1:11434`
/// - `SILICONPULSE_REAL_MODEL`: the model id the runner serves
/// - `SILICONPULSE_REAL_SERVER_PID`: the server process to stop at the end
///
/// SiliconPulse itself only reads; generation and unload requests here come from the test, standing in for a user.
final class RealRunnerTests: XCTestCase {
    private struct Config {
        var runner: AIRunner
        var base: URL
        var model: String
        var serverPID: Int32
    }

    private var config: Config? {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["SILICONPULSE_REAL_RUNNER"], let runner = AIRunner(rawValue: name),
              let base = env["SILICONPULSE_REAL_BASE"].flatMap(URL.init(string:)),
              let model = env["SILICONPULSE_REAL_MODEL"],
              let pid = env["SILICONPULSE_REAL_SERVER_PID"].flatMap(Int32.init) else { return nil }
        return Config(runner: runner, base: base, model: model, serverPID: pid)
    }

    private let sampler = SystemSampler()
    private let monitor = AIMonitor(http: URLSessionLocalHTTPClient())

    private func pass() async -> AIMonitorResult {
        let processes = await sampler.sampleProcesses(apps: [:])
        let candidates = await sampler.aiCandidates(from: processes)
        return await monitor.refresh(candidates: candidates, samples: processes, probeDefaultPorts: false)
    }

    private func log(_ step: String, _ w: AIWorkload?) {
        guard let w else { return print("REAL-RUNNER \(step): no workload") }
        let tps = w.tokensPerSecond.value.map { String(format: "%.1f tok/s [%@]", $0, w.tokensPerSecond.quality.rawValue) } ?? "tok/s unavailable"
        print("REAL-RUNNER \(step): \(w.runner.displayName) · \(w.state.label) · models \(w.models.map(\.identifier)) · "
              + "endpoint \(w.endpoint ?? "-") · PIDs \(w.processPIDs) · CPU \(w.processCPUPercent.map { String(format: "%.0f%%", $0) } ?? "-") · "
              + "memory \(w.processMemory.map { Format.bytes($0) } ?? "-") · GPU time \(w.processGPUTimeShare.map { Format.percent($0) } ?? "-") · "
              + "\(w.activity.label)\(w.activity.evidence.map { " (\($0))" } ?? "") · \(tps)")
    }

    private func post(_ path: String, json: [String: Any], timeout: TimeInterval = 120) async throws -> Int {
        guard let config else { return 0 }
        var request = URLRequest(url: config.base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func generate(tokens: Int) async throws -> Int {
        guard let config else { return 0 }
        let prompt = "Write a long, detailed story about a lighthouse keeper. Keep going."
        switch config.runner {
        case .ollama:
            return try await post("api/generate", json: ["model": config.model, "prompt": prompt, "stream": false,
                                                         "options": ["num_predict": tokens]])
        default:
            return try await post("v1/chat/completions", json: ["model": config.model, "max_tokens": tokens,
                                                                "messages": [["role": "user", "content": prompt]]])
        }
    }

    private func unload() async throws -> Int {
        guard let config else { return 0 }
        switch config.runner {
        case .ollama: return try await post("api/generate", json: ["model": config.model, "keep_alive": 0])
        default: return try await post("v1/models/\(config.model)/unload", json: [:])
        }
    }

    private func poll(_ label: String, seconds: Int, until done: (AIWorkload?) -> Bool) async -> AIWorkload? {
        var last: AIWorkload?
        for _ in 0..<seconds {
            let result = await pass()
            last = result.workloads.first { $0.runner == config?.runner }
            if done(last) { log(label, last); return last }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        log(label + " (timed out)", last)
        return last
    }

    func testRealRunnerLifecycle() async throws {
        guard let config else { throw XCTSkip("Set SILICONPULSE_REAL_RUNNER, _BASE, _MODEL and _SERVER_PID (real-runner CI job)") }

        // Warm up so the model is resident, then let CPU and GPU deltas settle.
        let warm = try await generate(tokens: 8)
        XCTAssertEqual(warm, 200, "warm-up generation")
        _ = await pass()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 1. Detection and attribution.
        let loaded = await poll("loaded", seconds: 15) { $0?.state == .modelLoaded && !($0?.models.isEmpty ?? true) }
        let w = try XCTUnwrap(loaded, "\(config.runner.displayName) with a loaded model")
        XCTAssertTrue(w.models.contains { $0.identifier.contains(config.model) || config.model.contains($0.identifier) },
                      "model \(w.models.map(\.identifier)) should match \(config.model)")
        XCTAssertTrue(w.processPIDs.contains(config.serverPID), "server PID \(config.serverPID) attributed: \(w.processPIDs)")
        XCTAssertGreaterThan(w.processMemory ?? 0, 50_000_000, "runner memory includes the model")
        XCTAssertNotNil(w.endpoint)

        // 2. Activity while a real generation runs.
        let generation = Task { try await self.generate(tokens: 400) }
        let busy = await poll("generating", seconds: 25) { $0?.activity.isBusy == true }
        XCTAssertEqual(busy?.activity.isBusy, true, "inference should be visible while generating")
        let status = try await generation.value
        XCTAssertEqual(status, 200)

        // 3. Back to idle once it finishes.
        let idle = await poll("idle", seconds: 30) { $0?.activity.isBusy == false }
        XCTAssertEqual(idle?.activity.isBusy, false, "activity should return to idle")
        if config.runner == .ollama {
            XCTAssertFalse(idle?.tokensPerSecond.isAvailable ?? true, "Ollama exposes no throughput; none may be shown")
        }

        // 4. Model unload.
        let unloadStatus = try await unload()
        XCTAssertEqual(unloadStatus, 200, "unload request")
        let unloaded = await poll("unloaded", seconds: 30) { $0 != nil && $0?.state != .modelLoaded }
        XCTAssertNotNil(unloaded, "the runner stays detected without a model")
        XCTAssertEqual(unloaded?.state, .idle, "no model loaded")

        // 5. Server exit.
        kill(config.serverPID, SIGTERM)
        let gone = await poll("exited", seconds: 30) { $0 == nil }
        XCTAssertNil(gone, "the workload disappears when the server exits")
    }
}
