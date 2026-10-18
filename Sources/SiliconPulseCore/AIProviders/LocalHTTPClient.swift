import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

public enum LocalHTTPError: Error, Equatable {
    /// SiliconPulse only ever talks to loopback addresses.
    case nonLocalHost(String)
    case transport(String)
    case badStatus(Int)
    case decoding(String)
}

/// Minimal HTTP abstraction so providers can be tested without a network.
public protocol LocalHTTPClient: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse
}

public enum LoopbackPolicy {
    public static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    /// Normalises a runner's bind address ("0.0.0.0", "*", "") to a loopback URL base.
    public static func baseURL(host: String?, port: Int) -> URL? {
        var h = (host ?? "127.0.0.1").trimmingCharacters(in: .whitespaces)
        if h.isEmpty || h == "0.0.0.0" || h == "*" || h == "::" || h == "[::]" || h == "localhost" { h = "127.0.0.1" }
        guard isLoopbackLiteral(h) else { return nil }
        return URL(string: "http://\(h):\(port)")
    }

    /// Parses OLLAMA_HOST-style values: "127.0.0.1:11434", "0.0.0.0", "http://localhost:8000", ":11500".
    public static func parseHostPort(_ value: String, defaultPort: Int) -> (host: String?, port: Int) {
        var v = value.trimmingCharacters(in: .whitespaces)
        if let range = v.range(of: "://") { v = String(v[range.upperBound...]) }
        if let slash = v.firstIndex(of: "/") { v = String(v[..<slash]) }
        if v.hasPrefix("[") , let close = v.firstIndex(of: "]") {
            let host = String(v[v.index(after: v.startIndex)..<close])
            let rest = v[v.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? defaultPort : defaultPort
            return (host, port)
        }
        if let colon = v.lastIndex(of: ":") {
            let host = String(v[..<colon])
            let port = Int(v[v.index(after: colon)...]) ?? defaultPort
            return (host.isEmpty ? nil : host, port)
        }
        return (v.isEmpty ? nil : v, defaultPort)
    }

    private static func isLoopbackLiteral(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.")
    }
}

/// URLSession-backed client restricted to loopback, with short timeouts, no cache, no cookies and no proxy.
public final class URLSessionLocalHTTPClient: LocalHTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.httpMaximumConnectionsPerHost = 2
        config.connectionProxyDictionary = [:]
        #if os(macOS)
        config.waitsForConnectivity = false
        #endif
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> HTTPResponse {
        guard LoopbackPolicy.isAllowed(url) else { throw LocalHTTPError.nonLocalHost(url.host ?? url.absoluteString) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: LocalHTTPError.transport(error.localizedDescription))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: HTTPResponse(status: status, body: data ?? Data()))
            }
            task.resume()
        }
    }
}

extension LocalHTTPClient {
    /// GET and decode JSON. Throws on transport errors, non-2xx status, or invalid JSON.
    func getJSON<T: Decodable>(_ type: T.Type, _ url: URL, timeout: TimeInterval) async throws -> T {
        let response = try await get(url, timeout: timeout)
        guard response.isSuccess else { throw LocalHTTPError.badStatus(response.status) }
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw LocalHTTPError.decoding(String(describing: error))
        }
    }

    func getText(_ url: URL, timeout: TimeInterval) async throws -> String {
        let response = try await get(url, timeout: timeout)
        guard response.isSuccess else { throw LocalHTTPError.badStatus(response.status) }
        return String(decoding: response.body, as: UTF8.self)
    }
}
