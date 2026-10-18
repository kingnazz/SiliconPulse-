import Foundation

/// Allocation-light formatting for values that refresh every second.
public enum Format {
    /// Memory sizes use binary units with the labels macOS uses (1 GB = 1024³ bytes), like Activity Monitor.
    public static func bytes(_ value: UInt64, decimals: Int? = nil) -> String {
        bytes(Double(value), decimals: decimals)
    }

    public static func bytes(_ value: Double, decimals: Int? = nil) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, value)
        var unit = 0
        while v >= 1024, unit < units.count - 1 {
            v /= 1024
            unit += 1
        }
        let places = decimals ?? (unit >= 3 ? 1 : 0)
        return fixed(v, places) + " " + units[unit]
    }

    /// Compact form for the menu bar: "21.8G", "512M".
    public static func compactBytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 100 { return fixed(gb, 0) + "G" }
        if gb >= 1 { return fixed(gb, 1) + "G" }
        return fixed(Double(value) / 1_048_576, 0) + "M"
    }

    /// Throughput in decimal units: "12.3 MB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = max(0, bytesPerSecond)
        var unit = 0
        while v >= 1000, unit < units.count - 1 {
            v /= 1000
            unit += 1
        }
        let places = unit == 0 ? 0 : (v < 10 ? 1 : 0)
        return fixed(v, places) + " " + units[unit]
    }

    /// Fraction 0...1 as a percentage: "23%", or "4.2%" below 10% when `precise`.
    public static func percent(_ fraction: Double, precise: Bool = false) -> String {
        let p = max(0, fraction * 100)
        if precise && p < 10 && p > 0 { return fixed(p, 1) + "%" }
        return fixed(p, 0) + "%"
    }

    /// Process CPU, already a percentage of one core: "12.3".
    public static func processCPU(_ percent: Double) -> String {
        fixed(max(0, percent), percent >= 100 ? 0 : 1)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let days = s / 86_400, hours = (s % 86_400) / 3_600, minutes = (s % 3_600) / 60, secs = s % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h " + pad2(minutes) + "m" }
        if minutes > 0 { return "\(minutes)m " + pad2(secs) + "s" }
        return "\(secs)s"
    }

    public static func integer(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (offset, char) in digits.enumerated() {
            if offset > 0 && (digits.count - offset) % 3 == 0 { result.append(",") }
            result.append(char)
        }
        return value < 0 ? "-" + result : result
    }

    public static func tokensPerSecond(_ value: Double) -> String {
        fixed(value, value >= 100 ? 0 : 1) + " tok/s"
    }

    public static func fixed(_ value: Double, _ places: Int) -> String {
        guard value.isFinite else { return "—" }
        if places <= 0 { return String(Int(value.rounded())) }
        var multiplier = 1.0
        for _ in 0..<places { multiplier *= 10 }
        let scaled = Int((value * multiplier).rounded())
        let whole = scaled / Int(multiplier)
        var fraction = String(abs(scaled % Int(multiplier)))
        while fraction.count < places { fraction = "0" + fraction }
        let sign = (scaled < 0 && whole == 0) ? "-" : ""
        return sign + String(whole) + "." + fraction
    }

    private static func pad2(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
}
