import AppKit
import QuartzCore
import SiliconPulseCore
import SwiftUI

// MARK: - Page scaffolding

/// Scrolling page on the level-1 surface, with consistent padding and a comfortable maximum width.
struct Page<Content: View>: View {
    var spacing: CGFloat = Theme.sectionSpacing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 22)
            .padding(.bottom, Theme.pagePadding)
            .frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.page)
    }
}

/// Large in-page title with an optional one-line subtitle and trailing controls.
struct PageHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.pageTitle)
                if let subtitle {
                    Text(subtitle).font(.body13).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.l)
            accessory
        }
    }
}

/// Section title: hierarchy from type and spacing, not boxes.
struct SectionHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title).font(.sectionTitle)
            if let subtitle {
                Text(subtitle).font(.meta).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.m)
            accessory
        }
    }
}

/// Small uppercase label. Used sparingly: hero section markers and compact column labels.
struct Overline: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(.overline)
            .tracking(0.7)
            .foregroundStyle(color)
    }
}

/// Kept for call sites that want a quiet label; now sentence case.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text).font(.metaMedium).foregroundStyle(.secondary)
    }
}

// MARK: - Surfaces

enum SurfaceLevel {
    case raised, emphasized
}

extension View {
    /// Level-2/3 surface: a fill with a continuous corner; a hairline only on emphasized surfaces.
    func surface(_ level: SurfaceLevel = .raised, radius: CGFloat = Theme.Radius.large, padding: CGFloat? = Theme.Space.l) -> some View {
        self
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(level == .raised ? Theme.raised : Theme.emphasized,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if level == .emphasized {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline)
                }
            }
    }

    /// Hairline separator under a view.
    func hairlineBelow() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// Column divider for metric strips.
    func stripDivider() -> some View {
        overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 2)
        }
    }

    /// Hover tooltip describing how a metric is measured.
    func metricHelp(_ info: MetricInfo, quality: MetricQuality? = nil) -> some View {
        help(MetricHelp.text(info, quality: quality))
    }
}

/// A quiet container kept for secondary groups (settings-like lists, limitations).
struct Panel<Content: View>: View {
    var title: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.sectionTitle) }
                    Spacer(minLength: Theme.Space.s)
                    if let accessory { accessory }
                }
            }
            content
        }
        .surface(.raised)
    }
}

// MARK: - Quality & scope

enum MetricHelp {
    static func text(_ info: MetricInfo, quality: MetricQuality?) -> String {
        guard let quality, quality != info.quality else { return info.tooltip }
        return "\(info.title) · \(info.scope.label) · \(quality.label)\n\(quality.explanation)\nSource: \(info.source)"
            + (info.note.map { "\n" + $0 } ?? "")
    }
}

/// Quality marker with a deliberately quiet rule:
/// exact, reported and calculated values show nothing (hover the value for its source);
/// estimated values say "Estimated"; unavailable values say why on hover.
struct QualityBadge: View {
    var info: MetricInfo
    var quality: MetricQuality?

    var body: some View {
        let q = quality ?? info.quality
        if q == .estimated {
            Text("Estimated")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.caution)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.caution.opacity(0.12), in: Capsule())
                .help(MetricHelp.text(info, quality: q))
        }
    }
}

/// Whose value this is. Rendered as quiet text; the full meaning is in the tooltip.
struct ScopeTag: View {
    var scope: MetricScope

    var body: some View {
        Text(label)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .help(explanation)
    }

    private var label: String {
        switch scope {
        case .system: return "whole Mac"
        case .process: return "runner"
        case .model: return "model"
        }
    }

    private var explanation: String {
        switch scope {
        case .system: return "SYSTEM: measured for the whole Mac and shared by everything running."
        case .process: return "PROCESS: measured for the runner's own processes."
        case .model: return "MODEL: reported by the runner about the loaded model."
        }
    }
}

// MARK: - Metrics

/// Label over a large value. The building block of every readout.
struct MetricReadout: View {
    var label: String
    var value: String
    var unit: String?
    var caption: String?
    var info: MetricInfo?
    var quality: MetricQuality?
    var valueFont: Font = .metric
    var tint: Color = .primary
    var labelAccessory: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(label).font(.metaMedium).foregroundStyle(.secondary)
                if let labelAccessory { labelAccessory }
                if let info { QualityBadge(info: info, quality: quality) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit, value != "—" {
                    Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption).font(.meta).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OptionalHelp(info: info, quality: quality))
    }
}

private struct OptionalHelp: ViewModifier {
    var info: MetricInfo?
    var quality: MetricQuality?

    func body(content: Content) -> some View {
        if let info { content.metricHelp(info, quality: quality) } else { content }
    }
}

/// Kept for compatibility with older call sites.
struct MetricTile: View {
    var label: String
    var value: String
    var unit: String?
    var detail: String?
    var info: MetricInfo
    var quality: MetricQuality?
    var tint: Color = .primary
    var indicator: Color?

    var body: some View {
        MetricReadout(label: label, value: value, unit: unit, caption: detail, info: info, quality: quality,
                      valueFont: .metricLarge, tint: tint)
    }
}

/// Label/value row. Hairline-separated lists replace boxed panels.
struct StatRow: View {
    var label: String
    var value: String
    var info: MetricInfo?
    var quality: MetricQuality?
    var scope: MetricScope?
    var valueColor: Color = .primary
    var swatch: Color?

    var body: some View {
        HStack(spacing: 7) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8)
            }
            Text(label).foregroundStyle(.secondary)
            if let info { QualityBadge(info: info, quality: quality) }
            Spacer(minLength: Theme.Space.s)
            Text(value)
                .font(.numericMedium)
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.vertical, 5)
        .hairlineBelow()
        .contentShape(Rectangle())
        .modifier(OptionalHelp(info: info, quality: quality))
    }
}

/// State with a dot. Normal states are quiet text; abnormal states get a tinted capsule.
struct StatusPill: View {
    var text: String
    var color: Color
    var prominent = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? color : .secondary)
        }
        .padding(.horizontal, prominent ? 9 : 0)
        .padding(.vertical, prominent ? 3 : 0)
        .background(prominent ? color.opacity(0.13) : .clear, in: Capsule())
    }
}

/// Thin rounded usage bar.
struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

/// Muted one-line explanation, used where macOS does not expose something.
struct LimitationNote: View {
    var text: String
    var symbol = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.meta)
    }
}

/// Centered placeholder for empty states.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

/// Segmented picker for history windows.
struct WindowPicker: View {
    @Binding var selection: HistoryWindow

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(HistoryWindow.allCases) { window in Text(window.label).tag(window) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

// MARK: - Live indicator

/// A small dot that pulses while something is live. The pulse is a Core Animation layer animation,
/// so it runs in the render server without re-evaluating SwiftUI views every frame. It stops when
/// `isLive` is false and never animates when Reduce Motion is on.
struct PulseDot: NSViewRepresentable {
    var color: Color
    var isLive: Bool
    var size: CGFloat = 7

    func makeNSView(context: Context) -> PulseDotView {
        let view = PulseDotView()
        view.configure(color: NSColor(color), isLive: isLive, size: size)
        return view
    }

    func updateNSView(_ view: PulseDotView, context: Context) {
        view.configure(color: NSColor(color), isLive: isLive, size: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseDotView, context: Context) -> CGSize? {
        CGSize(width: size * 2.4, height: size * 2.4)
    }

    final class PulseDotView: NSView {
        private let dot = CALayer()
        private let ring = CALayer()
        private var live = false
        private var dotSize: CGFloat = 7
        private var nsColor: NSColor = .systemPink

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(ring)
            layer?.addSublayer(dot)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var intrinsicContentSize: NSSize { NSSize(width: dotSize * 2.4, height: dotSize * 2.4) }

        func configure(color: NSColor, isLive: Bool, size: CGFloat) {
            dotSize = size
            nsColor = color
            needsLayout = true
            let shouldAnimate = isLive && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if shouldAnimate != live {
                live = shouldAnimate
                updateAnimation()
            }
            updateColors()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }

        override func layout() {
            super.layout()
            let rect = CGRect(x: (bounds.width - dotSize) / 2, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = rect
            dot.cornerRadius = dotSize / 2
            ring.frame = rect
            ring.cornerRadius = dotSize / 2
            CATransaction.commit()
        }

        private func updateColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                dot.backgroundColor = nsColor.cgColor
                ring.backgroundColor = nsColor.withAlphaComponent(0.55).cgColor
            }
        }

        private func updateAnimation() {
            ring.removeAllAnimations()
            guard live else {
                ring.opacity = 0
                return
            }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.4
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.6
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = Theme.Motion.pulsePeriod
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.repeatCount = .infinity
            ring.opacity = 0
            ring.add(group, forKey: "pulse")
        }
    }
}

/// Text-only health summary used by the Overview header and the menu bar popover.
struct MachineHealth: Equatable {
    enum Level { case healthy, attention, critical }
    var level: Level
    var title: String
    var detail: String?

    var color: Color {
        switch level {
        case .healthy: return Theme.good
        case .attention: return Theme.caution
        case .critical: return Theme.critical
        }
    }

    static func evaluate(_ s: SystemSnapshot) -> MachineHealth {
        let m = s.memory
        if m.pressure == .critical {
            return MachineHealth(level: .critical, title: "Memory pressure critical", detail: "macOS is swapping heavily")
        }
        if s.thermal.level == .critical || s.thermal.level == .serious {
            return MachineHealth(level: .critical, title: "Thermally constrained", detail: "macOS is reducing performance")
        }
        if m.isSwappingOut {
            return MachineHealth(level: .attention, title: "Swapping", detail: "Memory is being written to disk")
        }
        if m.pressure == .warning {
            return MachineHealth(level: .attention, title: "Memory pressure elevated", detail: "macOS is compressing memory")
        }
        if s.thermal.level == .elevated {
            return MachineHealth(level: .attention, title: "Running warm", detail: "Thermal pressure is elevated")
        }
        return MachineHealth(level: .healthy, title: "Healthy", detail: nil)
    }
}
