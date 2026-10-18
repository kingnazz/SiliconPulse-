import SiliconPulseCore
import SwiftUI

/// A restrained palette: one hue per metric family, status colors reserved for states.
enum Theme {
    static let cpu = Color(red: 0.36, green: 0.55, blue: 0.97)
    static let gpu = Color(red: 0.60, green: 0.45, blue: 0.95)
    static let memory = Color(red: 0.22, green: 0.70, blue: 0.64)
    static let disk = Color(red: 0.91, green: 0.60, blue: 0.27)
    static let network = Color(red: 0.30, green: 0.66, blue: 0.90)
    static let ai = Color(red: 0.90, green: 0.47, blue: 0.62)

    static let good = Color(red: 0.27, green: 0.72, blue: 0.43)
    static let caution = Color(red: 0.93, green: 0.68, blue: 0.20)
    static let critical = Color(red: 0.92, green: 0.33, blue: 0.30)
    static let muted = Color.secondary

    static let separator = Color.primary.opacity(0.08)
    static let panelFill = Color(nsColor: .controlBackgroundColor).opacity(0.55)
    static let grid = Color.primary.opacity(0.06)

    static let panelRadius: CGFloat = 8
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18

    static func color(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return good
        case .warning: return caution
        case .critical: return critical
        case .unknown: return muted
        }
    }

    static func color(for thermal: ThermalLevel) -> Color {
        switch thermal {
        case .normal: return good
        case .elevated: return caution
        case .serious, .critical: return critical
        case .unknown: return muted
        }
    }

    static func color(for quality: MetricQuality) -> Color {
        switch quality {
        case .exact, .systemReported: return Color.secondary.opacity(0.55)
        case .calculated: return Color.secondary.opacity(0.55)
        case .estimated: return caution.opacity(0.9)
        case .unavailable: return Color.secondary.opacity(0.35)
        }
    }

    static func color(for state: AIWorkloadState) -> Color {
        switch state {
        case .modelLoaded, .processOnly: return good
        case .idle: return muted
        case .apiUnreachable: return caution
        }
    }

    /// Utilization-tinted color: neutral until load is high.
    static func load(_ fraction: Double, base: Color) -> Color {
        fraction >= 0.9 ? critical : (fraction >= 0.75 ? caution : base)
    }
}

extension Font {
    static let metricValue = Font.system(size: 26, weight: .semibold, design: .default).monospacedDigit()
    static let metricValueLarge = Font.system(size: 34, weight: .semibold, design: .default).monospacedDigit()
    static let metricUnit = Font.system(size: 13, weight: .medium)
    static let sectionLabel = Font.system(size: 10.5, weight: .semibold)
    static let numeric = Font.system(size: 12).monospacedDigit()
    static let numericMedium = Font.system(size: 12, weight: .medium).monospacedDigit()
}
