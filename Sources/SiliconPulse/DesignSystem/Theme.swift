import AppKit
import SiliconPulseCore
import SwiftUI

/// Design tokens. Most of the interface is neutral; color is reserved for data series,
/// the active AI workload, warnings and interaction.
enum Theme {
    // MARK: Resource hues (data series)

    static let cpu = adaptive(light: (0.20, 0.45, 0.93), dark: (0.42, 0.62, 1.00))
    static let gpu = adaptive(light: (0.53, 0.33, 0.90), dark: (0.68, 0.52, 1.00))
    static let memory = adaptive(light: (0.10, 0.60, 0.53), dark: (0.30, 0.80, 0.70))
    static let disk = adaptive(light: (0.87, 0.52, 0.12), dark: (0.98, 0.68, 0.30))
    static let network = adaptive(light: (0.10, 0.56, 0.82), dark: (0.35, 0.74, 0.98))
    /// The local-AI accent: a warm magenta that no resource series uses.
    static let ai = adaptive(light: (0.86, 0.24, 0.52), dark: (1.00, 0.45, 0.66))

    // MARK: Status

    static let good = adaptive(light: (0.16, 0.62, 0.32), dark: (0.36, 0.82, 0.50))
    static let caution = adaptive(light: (0.86, 0.55, 0.05), dark: (1.00, 0.74, 0.28))
    static let critical = adaptive(light: (0.86, 0.22, 0.20), dark: (1.00, 0.42, 0.38))
    static let muted = Color.secondary

    // MARK: Surfaces (three levels)

    /// Level 1: the page itself, slightly lifted from the sidebar.
    static let page = Color(nsColor: NSColor(name: "SP.page") { appearance in
        appearance.isDark ? NSColor(white: 0.115, alpha: 1) : NSColor(white: 0.985, alpha: 1)
    })
    /// Level 2: a section that groups related content (used sparingly).
    static let raised = Color(nsColor: NSColor(name: "SP.raised") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.045) : NSColor(white: 0, alpha: 0.028)
    })
    /// Level 3: emphasized or interactive surfaces (hover, the active-model hero).
    static let emphasized = Color(nsColor: NSColor(name: "SP.emphasized") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.05)
    })
    static let hairline = Color(nsColor: NSColor(name: "SP.hairline") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)
    })
    static let grid = Color(nsColor: NSColor(name: "SP.grid") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.055)
    })
    /// Track behind bars and meters.
    static let track = Color(nsColor: NSColor(name: "SP.track") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.07)
    })

    // Legacy names kept for the few places that still use them.
    static let separator = hairline
    static let panelFill = raised

    // MARK: Geometry

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 5
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }

    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 28
    static let panelRadius = Radius.large

    // MARK: Motion

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.15)
        static let standard = Animation.easeInOut(duration: 0.25)
        /// Period of the live-inference pulse.
        static let pulsePeriod: CFTimeInterval = 1.8
    }

    // MARK: Status helpers

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

    static func color(for state: AIWorkloadState) -> Color {
        switch state {
        case .modelLoaded, .processOnly: return good
        case .idle: return muted
        case .apiUnreachable: return caution
        }
    }

    /// Utilization-tinted color: neutral until load is genuinely high.
    static func load(_ fraction: Double, base: Color) -> Color {
        fraction >= 0.9 ? critical : (fraction >= 0.75 ? caution : base)
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Type scale. SF Pro via system fonts; changing numbers use monospaced digits.
extension Font {
    static let pageTitle = Font.system(size: 22, weight: .semibold)
    static let heroTitle = Font.system(size: 24, weight: .semibold)
    static let heroMetric = Font.system(size: 34, weight: .semibold).monospacedDigit()
    static let metricLarge = Font.system(size: 28, weight: .semibold).monospacedDigit()
    static let metric = Font.system(size: 20, weight: .semibold).monospacedDigit()
    static let metricSmall = Font.system(size: 15, weight: .semibold).monospacedDigit()
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let body13 = Font.system(size: 13)
    static let label = Font.system(size: 12, weight: .medium)
    static let meta = Font.system(size: 11)
    static let metaMedium = Font.system(size: 11, weight: .medium)
    /// Small caps label, used sparingly (hero "LOCAL AI", popover columns).
    static let overline = Font.system(size: 10, weight: .semibold)
    static let numeric = Font.system(size: 12).monospacedDigit()
    static let numericMedium = Font.system(size: 12, weight: .medium).monospacedDigit()

    // Legacy names.
    static let metricValue = metricLarge
    static let metricValueLarge = heroMetric
    static let metricUnit = Font.system(size: 13, weight: .medium)
    static let sectionLabel = overline
}
