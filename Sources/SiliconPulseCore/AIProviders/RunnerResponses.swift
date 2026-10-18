import Foundation

// Lenient Codable models for local runner APIs. Every field is optional so that
// a runner adding or dropping fields degrades gracefully instead of failing detection.

// MARK: Ollama

public struct OllamaPSResponse: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public struct Details: Decodable, Sendable {
            public var format: String?
            public var family: String?
            public var parameter_size: String?
            public var quantization_level: String?
        }
        public var name: String?
        public var model: String?
        public var size: UInt64?
        public var size_vram: UInt64?
        public var expires_at: String?
        public var context_length: Int?
        public var details: Details?
    }
    public var models: [Model]?
}

public struct OllamaVersionResponse: Decodable, Sendable {
    public var version: String?
}

// MARK: LM Studio

/// `GET /api/v0/models` (LM Studio REST API beta).
public struct LMStudioV0ModelsResponse: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public var id: String?
        public var type: String?
        public var publisher: String?
        public var arch: String?
        public var compatibility_type: String?
        public var quantization: String?
        public var state: String?
        public var max_context_length: Int?
        public var loaded_context_length: Int?
    }
    public var data: [Model]?
}

/// `GET /api/v1/models` (LM Studio REST API v1).
public struct LMStudioV1ModelsResponse: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public struct Quantization: Decodable, Sendable {
            public var name: String?
        }
        public struct Instance: Decodable, Sendable {
            public struct Config: Decodable, Sendable {
                public var context_length: Int?
            }
            public var id: String?
            public var config: Config?
        }
        public var type: String?
        public var key: String?
        public var display_name: String?
        public var architecture: String?
        public var format: String?
        public var params_string: String?
        public var size_bytes: UInt64?
        public var max_context_length: Int?
        public var quantization: Quantization?
        public var loaded_instances: [Instance]?

        enum CodingKeys: String, CodingKey {
            case type, key, display_name, architecture, format, params_string, size_bytes, max_context_length, quantization, loaded_instances
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            key = try? c.decodeIfPresent(String.self, forKey: .key)
            display_name = try? c.decodeIfPresent(String.self, forKey: .display_name)
            architecture = try? c.decodeIfPresent(String.self, forKey: .architecture)
            format = try? c.decodeIfPresent(String.self, forKey: .format)
            params_string = try? c.decodeIfPresent(String.self, forKey: .params_string)
            size_bytes = try? c.decodeIfPresent(UInt64.self, forKey: .size_bytes)
            max_context_length = try? c.decodeIfPresent(Int.self, forKey: .max_context_length)
            // Quantization has been both an object and a plain string across versions.
            if let q = try? c.decodeIfPresent(Quantization.self, forKey: .quantization) {
                quantization = q
            } else if let s = try? c.decodeIfPresent(String.self, forKey: .quantization) {
                quantization = Quantization(name: s)
            } else {
                quantization = nil
            }
            loaded_instances = try? c.decodeIfPresent([Instance].self, forKey: .loaded_instances)
        }
    }
    public var models: [Model]?
}

// MARK: OpenAI-compatible

/// `GET /v1/models`.
public struct OpenAIModelsResponse: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public var id: String?
        public var owned_by: String?
    }
    public var object: String?
    public var data: [Model]?
}

// MARK: llama.cpp server

/// `GET /props`.
public struct LlamaCppPropsResponse: Decodable, Sendable {
    public struct GenerationSettings: Decodable, Sendable {
        public var n_ctx: Int?
        public var model: String?
    }
    public var default_generation_settings: GenerationSettings?
    public var total_slots: Int?
    public var model_path: String?
    public var model_alias: String?
    public var build_info: String?
}

/// One element of `GET /slots`.
public struct LlamaCppSlot: Decodable, Sendable {
    public struct NextToken: Decodable, Sendable {
        public var n_decoded: Int?
    }
    public var id: Int?
    public var n_ctx: Int?
    public var is_processing: Bool?
    /// Older builds: 0 idle, 1 processing.
    public var state: Int?
    public var next_token: NextToken?

    enum CodingKeys: String, CodingKey { case id, n_ctx, is_processing, state, next_token }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        n_ctx = try? c.decodeIfPresent(Int.self, forKey: .n_ctx)
        is_processing = try? c.decodeIfPresent(Bool.self, forKey: .is_processing)
        state = try? c.decodeIfPresent(Int.self, forKey: .state)
        // next_token is an object in some builds and an array of objects in others.
        if let token = try? c.decodeIfPresent(NextToken.self, forKey: .next_token) {
            next_token = token
        } else if let tokens = try? c.decodeIfPresent([NextToken].self, forKey: .next_token) {
            next_token = tokens.first
        } else {
            next_token = nil
        }
    }

    public var processing: Bool { is_processing ?? (state.map { $0 != 0 } ?? false) }
}

// MARK: Prometheus text format (llama.cpp /metrics)

public enum PrometheusParser {
    /// Parses `name value` and `name{labels} value` lines, ignoring comments. Labels are dropped.
    public static func parse(_ text: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var name: Substring
            var rest: Substring
            if let brace = line.firstIndex(of: "{"), let close = line.firstIndex(of: "}"), brace < close {
                name = line[..<brace]
                rest = line[line.index(after: close)...]
            } else {
                guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
                name = line[..<space]
                rest = line[space...]
            }
            let fields = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first, let value = Double(first) else { continue }
            name = Substring(name.trimmingCharacters(in: .whitespaces))
            result[String(name)] = value
        }
        return result
    }
}

// MARK: Dates

public enum RFC3339 {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    /// Parses RFC 3339 timestamps with any number of fractional digits (Go emits nanoseconds).
    public static func parse(_ string: String) -> Date? {
        var base = string
        var fraction = 0.0
        if let dot = string.firstIndex(of: ".") {
            let afterDot = string.index(after: dot)
            let digitsEnd = string[afterDot...].firstIndex { !$0.isNumber } ?? string.endIndex
            let digits = string[afterDot..<digitsEnd]
            fraction = Double("0." + digits) ?? 0
            base = String(string[..<dot]) + String(string[digitsEnd...])
        }
        lock.lock()
        defer { lock.unlock() }
        guard let date = formatter.date(from: base) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}
