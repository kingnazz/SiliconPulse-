import SiliconPulseCore
import SwiftUI

/// Small uppercase label used for section and metric headings.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.sectionLabel)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A quiet container: subtle fill, hairline border, small radius.
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
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { SectionLabel(text: title) }
                    Spacer(minLength: 8)
                    if let accessory { accessory }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).strokeBorder(Theme.separator))
    }
}

/// Tiny tag that says whose value this is: SYSTEM, PROCESS or MODEL.
struct ScopeTag: View {
    var scope: MetricScope
    var body: some View {
        Text(scope.label)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.75))
    }
}

/// Quality indicator. Estimated and unavailable values say so in words; others show a quiet dot.
/// Hover explains the source.
struct QualityBadge: View {
    var info: MetricInfo
    var quality: MetricQuality?

    var body: some View {
        let q = quality ?? info.quality
        Group {
            switch q {
            case .estimated:
                Text("EST")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.caution)
            case .unavailable:
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            default:
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .help(tooltip(q))
    }

    private func tooltip(_ q: MetricQuality) -> String {
        guard q != info.quality else { return info.tooltip }
        return "\(info.title) · \(info.scope.label) · \(q.label)\n\(q.explanation)\nSource: \(info.source)" + (info.note.map { "\n" + $0 } ?? "")
    }
}

/// A big number with a unit, label and optional detail line.
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let indicator {
                    Circle().fill(indicator).frame(width: 6, height: 6)
                }
                SectionLabel(text: label)
                QualityBadge(info: info, quality: quality)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.metricValue)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit).font(.metricUnit).foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label/value row with optional quality info and scope.
struct StatRow: View {
    var label: String
    var value: String
    var info: MetricInfo?
    var quality: MetricQuality?
    var scope: MetricScope?
    var valueColor: Color = .primary
    var swatch: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8)
            }
            Text(label).foregroundStyle(.secondary)
            if let scope { ScopeTag(scope: scope) }
            if let info { QualityBadge(info: info, quality: quality) }
            Spacer(minLength: 8)
            Text(value)
                .font(.numericMedium)
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.vertical, 2.5)
    }
}

/// Capsule showing a state such as RUNNING or NORMAL.
struct StatusPill: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color == Theme.muted ? Color.secondary : color)
    }
}

/// Thin horizontal usage bar.
struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

/// Muted explanatory text with an icon, used where macOS does not expose something.
struct LimitationNote: View {
    var text: String
    var symbol = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
    }
}

/// Centered placeholder for empty states.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
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
        .frame(width: 150)
    }
}

/// Page scaffold: scrolling column with consistent padding.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                content
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// Column divider for metric strips.
    func stripDivider() -> some View {
        overlay(alignment: .trailing) {
            Rectangle().fill(Theme.separator).frame(width: 1).padding(.vertical, 2)
        }
    }
}
