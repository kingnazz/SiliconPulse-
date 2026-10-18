import XCTest
@testable import SiliconPulseCore

/// End-to-end detection over real HTTP against scripts/mock-runners.py.
/// Runs only when SILICONPULSE_MOCK_RUNNERS=1 (CI starts the mock first).
final class MockRunnerIntegrationTests: XCTestCase {
    func testDetectsMockOllamaAndLlamaServerOverRealHTTP() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SILICONPULSE_MOCK_RUNNERS"] == "1",
                          "Set SILICONPULSE_MOCK_RUNNERS=1 with scripts/mock-runners.py running")
        let monitor = AIMonitor(http: URLSessionLocalHTTPClient())
        _ = await monitor.refresh(candidates: [], samples: [])
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let result = await monitor.refresh(candidates: [], samples: [])

        let ollama = try XCTUnwrap(result.workloads.first { $0.runner == .ollama })
        XCTAssertEqual(ollama.state, .modelLoaded)
        XCTAssertEqual(ollama.primaryModel?.identifier, "mock-qwen3:30b-a3b")
        XCTAssertEqual(ollama.primaryModel?.gpuOffloadFraction, 1)
        XCTAssertFalse(ollama.tokensPerSecond.isAvailable, "Ollama exposes no throughput, even from a mock")

        let llama = try XCTUnwrap(result.workloads.first { $0.runner == .llamaCpp })
        XCTAssertEqual(llama.state, .modelLoaded)
        XCTAssertEqual(llama.primaryModel?.contextLength, 8192)
        if llama.activity.isBusy {
            // The mock generates ~40 tok/s in bursts; a live reading must be in that range.
            let tps = try XCTUnwrap(llama.tokensPerSecond.value)
            XCTAssertEqual(tps, 40, accuracy: 2)
        }
    }
}
