import Foundation
@testable import SiliconPulseCore

/// Serves canned responses keyed by "host:port/path". Unknown URLs behave like a closed port.
final class MockHTTPClient: LocalHTTPClient, @unchecked Sendable {
    enum Reply {
        case json(String)
        case text(String)
        case status(Int)
        /// A non-2xx status that still carries a JSON body (oMLX answers 503 with its health while preloading).
        case statusJSON(Int, String)
        case timeout
    }

    private let lock = NSLock()
    private var routes: [String: Reply] = [:]
    private(set) var requested: [String] = []

    init(_ routes: [String: Reply] = [:]) {
        self.routes = routes
    }

    func set(_ key: String, _ reply: Reply?) {
        lock.withLock { routes[key] = reply }
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse {
        guard LoopbackPolicy.isAllowed(url) else { throw LocalHTTPError.nonLocalHost(url.host ?? "") }
        let key = "\(url.host ?? ""):\(url.port ?? 80)\(url.path)"
        let reply: Reply? = lock.withLock {
            requested.append(key)
            return routes[key]
        }
        switch reply {
        case .json(let body), .text(let body):
            return HTTPResponse(status: 200, body: Data(body.utf8))
        case .status(let code):
            return HTTPResponse(status: code, body: Data())
        case .statusJSON(let code, let body):
            return HTTPResponse(status: code, body: Data(body.utf8))
        case .timeout:
            throw LocalHTTPError.transport("timed out")
        case nil:
            throw LocalHTTPError.transport("Could not connect to the server.")
        }
    }
}

enum Fixtures {
    static let ollamaPSOneModel = """
    {"models":[{"name":"qwen3:30b-a3b","model":"qwen3:30b-a3b","size":19532111872,"digest":"abc",
      "details":{"parent_model":"","format":"gguf","family":"qwen3moe","families":["qwen3moe"],"parameter_size":"30.5B","quantization_level":"Q4_K_M"},
      "expires_at":"2026-10-18T06:05:00.123456789-07:00","size_vram":19532111872,"context_length":8192}]}
    """
    static let ollamaPSEmpty = #"{"models":[]}"#
    static let ollamaPSPartialOffload = """
    {"models":[{"name":"llama3.1:70b","size":42000000000,"size_vram":21000000000,"details":{"parameter_size":"70.6B"}}]}
    """
    static let ollamaVersion = #"{"version":"0.12.6"}"#

    static let lmStudioV0 = """
    {"object":"list","data":[
      {"id":"qwen3-30b-a3b","object":"model","type":"llm","publisher":"qwen","arch":"qwen3moe","compatibility_type":"gguf","quantization":"Q4_K_M","state":"loaded","max_context_length":32768,"loaded_context_length":8192},
      {"id":"text-embedding-nomic","object":"model","type":"embeddings","state":"not-loaded","max_context_length":2048}
    ]}
    """
    static let lmStudioV0NoneLoaded = """
    {"object":"list","data":[{"id":"qwen3-30b-a3b","type":"llm","state":"not-loaded","max_context_length":32768}]}
    """
    static let lmStudioV1 = """
    {"models":[
      {"type":"llm","publisher":"qwen","key":"qwen/qwen3-30b-a3b","display_name":"Qwen3 30B A3B","architecture":"qwen3moe",
       "quantization":{"name":"Q4_K_M","bits_per_weight":4},"size_bytes":18556685248,"params_string":"30B",
       "loaded_instances":[{"id":"qwen/qwen3-30b-a3b","config":{"context_length":8192}}],"max_context_length":40960,"format":"gguf"},
      {"type":"llm","key":"google/gemma-3-12b","display_name":"Gemma 3 12B","loaded_instances":[]}
    ]}
    """
    static let openAIModels = #"{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"local"}]}"#

    static let llamaProps = """
    {"default_generation_settings":{"n_ctx":8192,"model":"/models/Qwen3-30B-A3B-Q4_K_M.gguf"},"total_slots":1,
     "model_path":"/models/Qwen3-30B-A3B-Q4_K_M.gguf","build_info":"b6700-abcdef"}
    """
    static func llamaSlots(decoded: Int, processing: Bool) -> String {
        #"[{"id":0,"n_ctx":8192,"is_processing":\#(processing),"next_token":{"has_next_token":true,"n_remain":-1,"n_decoded":\#(decoded)}}]"#
    }
    static func llamaMetrics(tokens: Double, seconds: Double, processing: Double = 0) -> String {
        """
        # HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.
        # TYPE llamacpp:prompt_tokens_total counter
        llamacpp:prompt_tokens_total 120
        llamacpp:tokens_predicted_total \(tokens)
        llamacpp:tokens_predicted_seconds_total \(seconds)
        llamacpp:requests_processing \(processing)
        llamacpp:predicted_tokens_seconds{slot="0"} 37.5
        """
    }
}

extension AIProcessInfo {
    static func make(pid: Int32, parent: Int32 = 1, name: String, path: String? = nil, args: [String] = [],
                     env: [String: String] = [:], ports: [UInt16] = [], cpu: Double? = nil, memory: UInt64? = nil,
                     gpu: Double? = nil, start: TimeInterval = 1_000) -> AIProcessInfo {
        AIProcessInfo(sample: ProcessSample(pid: pid, parentPID: parent, name: name, executablePath: path, startTime: start,
                                            cpuPercent: cpu, memoryFootprint: memory, gpuTimeShare: gpu),
                      arguments: args, environment: env, listeningPorts: ports)
    }
}
