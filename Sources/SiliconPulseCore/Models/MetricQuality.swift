import Foundation

/// How much a displayed value can be trusted. See docs/METRICS.md.
public enum MetricQuality: String, Codable, CaseIterable, Sendable, Comparable {
    /// A precise fact (installed RAM, a PID, Rosetta translation).
    case exact
    /// Reported directly by macOS or by a local runner's API.
    case systemReported
    /// Derived by SiliconPulse from reported counters with a deterministic formula.
    case calculated
    /// A heuristic or approximation.
    case estimated
    /// Not exposed through interfaces SiliconPulse relies on.
    case unavailable

    public var label: String {
        switch self {
        case .exact: return "Exact"
        case .systemReported: return "Reported"
        case .calculated: return "Calculated"
        case .estimated: return "Estimated"
        case .unavailable: return "Unavailable"
        }
    }

    public var explanation: String {
        switch self {
        case .exact:
            return "A precise fact about the system, not a measurement."
        case .systemReported:
            return "Reported directly by macOS or by the runner's own API."
        case .calculated:
            return "Calculated by SiliconPulse from counters macOS reports."
        case .estimated:
            return "An approximation. Treat it as a hint, not a measurement."
        case .unavailable:
            return "macOS does not expose this through interfaces SiliconPulse relies on."
        }
    }

    private var rank: Int {
        switch self {
        case .exact: return 0
        case .systemReported: return 1
        case .calculated: return 2
        case .estimated: return 3
        case .unavailable: return 4
        }
    }

    /// Lower is more trustworthy.
    public static func < (lhs: MetricQuality, rhs: MetricQuality) -> Bool { lhs.rank < rhs.rank }

    /// The weaker of two qualities: a value derived from two inputs is only as good as the worse one.
    public static func weakest(_ a: MetricQuality, _ b: MetricQuality) -> MetricQuality { max(a, b) }
}

/// Who a value belongs to. A SYSTEM value is never presented as a PROCESS or MODEL value.
public enum MetricScope: String, Codable, Sendable, CaseIterable {
    case system, process, model

    public var label: String { rawValue.uppercased() }
}

/// A value together with its quality. `value == nil` always means unavailable.
public struct Measured<Value>: CustomStringConvertible {
    public var value: Value?
    public var quality: MetricQuality
    public var source: String
    public var note: String?

    public init(_ value: Value?, quality: MetricQuality, source: String, note: String? = nil) {
        self.value = value
        self.quality = value == nil ? .unavailable : quality
        self.source = source
        self.note = note
    }

    public static func unavailable(_ reason: String, source: String = "") -> Measured<Value> {
        Measured(nil, quality: .unavailable, source: source, note: reason)
    }

    public var isAvailable: Bool { value != nil }

    public var description: String {
        if let value { return "\(value) [\(quality.rawValue)]" }
        return "unavailable" + (note.map { " (\($0))" } ?? "")
    }
}

extension Measured: Equatable where Value: Equatable {}
extension Measured: Sendable where Value: Sendable {}
