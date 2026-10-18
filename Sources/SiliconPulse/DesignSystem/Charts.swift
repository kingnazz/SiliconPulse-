import SiliconPulseCore
import SwiftUI

struct ChartSeries {
    var points: [HistoryPoint]
    var color: Color
    var label: String
    var dashed = false
    var fill = true
}

/// Lightweight time-series chart drawn with Canvas (much cheaper than Swift Charts at 1 Hz).
/// X spans the selected window ending now; Y is fixed (`maxValue`) or auto-scaled.
struct LineChart: View {
    var series: [ChartSeries]
    var window: HistoryWindow
    var maxValue: Double?
    var format: (Double) -> String
    var height: CGFloat = 86

    @State private var hoverX: CGFloat?

    var body: some View {
        let end = series.compactMap { $0.points.last?.time }.max() ?? Date().timeIntervalSinceReferenceDate
        let start = end - window.duration
        let peak = series.flatMap { $0.points.map(\.average) }.max() ?? 0
        let top = maxValue ?? Self.niceCeiling(peak)

        Canvas { context, size in
            // Grid
            for fraction in [0.0, 0.5, 1.0] {
                let y = size.height - CGFloat(fraction) * (size.height - 1)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(Theme.grid), lineWidth: 1)
            }
            guard top > 0 else { return }
            for s in series where s.points.count > 1 {
                var path = Path()
                var first = true
                var firstX: CGFloat = 0
                var lastX: CGFloat = 0
                for point in s.points where point.time >= start - window.bucketWidth {
                    let x = CGFloat((point.time - start) / window.duration) * size.width
                    let y = size.height - CGFloat(min(point.average, top) / top) * (size.height - 1)
                    if first {
                        path.move(to: CGPoint(x: x, y: y))
                        firstX = x
                        first = false
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    lastX = x
                }
                if s.fill && !s.dashed {
                    var area = path
                    area.addLine(to: CGPoint(x: lastX, y: size.height))
                    area.addLine(to: CGPoint(x: firstX, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [s.color.opacity(0.22), s.color.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                }
                context.stroke(path, with: .color(s.dashed ? s.color.opacity(0.75) : s.color),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: s.dashed ? [3, 3] : []))
            }
            if let hoverX {
                var rule = Path()
                rule.move(to: CGPoint(x: hoverX, y: 0))
                rule.addLine(to: CGPoint(x: hoverX, y: size.height))
                context.stroke(rule, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)
            }
        }
        .frame(height: height)
        .overlay(alignment: .topLeading) {
            Text(format(top)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary).padding(.leading, 2)
        }
        .overlay(alignment: .topTrailing) {
            if let hoverX { hoverLabel(at: hoverX, start: start) }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
        .accessibilityElement()
        .accessibilityLabel(series.map(\.label).joined(separator: ", "))
        .accessibilityValue(series.compactMap { s in s.points.last.map { "\(s.label) \(format($0.average))" } }.joined(separator: ", "))
    }

    private func hoverLabel(at x: CGFloat, start: TimeInterval) -> some View {
        GeometryReader { geometry in
            let time = start + Double(x / max(1, geometry.size.width)) * window.duration
            let values = series.compactMap { s -> (String, Color)? in
                guard let nearest = s.points.min(by: { abs($0.time - time) < abs($1.time - time) }),
                      abs(nearest.time - time) <= window.bucketWidth * 2 else { return nil }
                return ("\(s.label) \(format(nearest.average))", s.color)
            }
            VStack(alignment: .trailing, spacing: 1) {
                let ago = Int(max(0, (series.compactMap { $0.points.last?.time }.max() ?? time) - time))
                Text(ago == 0 ? "now" : "−\(Format.duration(Double(ago)))").foregroundStyle(.secondary)
                ForEach(values, id: \.0) { value in Text(value.0).foregroundStyle(value.1) }
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .allowsHitTesting(false)
    }

    /// Rounds up to 1/2/5 × 10ⁿ so auto-scaled axes are readable.
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        for step in [1.0, 2.0, 5.0, 10.0] where value <= step * base { return step * base }
        return 10 * base
    }
}

/// A titled chart with its current value, used in grids.
struct ChartCard: View {
    var title: String
    var value: String
    var info: MetricInfo
    var series: [ChartSeries]
    var window: HistoryWindow
    var maxValue: Double?
    var format: (Double) -> String
    var height: CGFloat = 86
    /// Shown over the plot when there is no data, e.g. a metric this Mac does not report.
    var emptyMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: title)
                QualityBadge(info: info)
                Spacer()
                Text(value).font(.numericMedium).foregroundStyle(.primary)
            }
            LineChart(series: series, window: window, maxValue: maxValue, format: format, height: height)
                .overlay {
                    if let emptyMessage, series.allSatisfy({ $0.points.isEmpty }) {
                        Text(emptyMessage).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            // The legend row is always laid out (hidden for one series) so cards in a grid row match in height.
            HStack(spacing: 10) {
                ForEach(series.indices, id: \.self) { index in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(series[index].color.opacity(series[index].dashed ? 0.7 : 1))
                            .frame(width: 10, height: 2)
                        Text(series[index].label).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(series.count > 1 ? 1 : 0)
            .accessibilityHidden(series.count <= 1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).strokeBorder(Theme.separator))
    }
}

/// Compact strip showing when inference was active (full height) or likely (half height).
struct ActivityTimeline: View {
    var points: [HistoryPoint]
    var window: HistoryWindow
    var color: Color = Theme.ai

    var body: some View {
        Canvas { context, size in
            let end = points.last?.time ?? Date().timeIntervalSinceReferenceDate
            let start = end - window.duration
            let width = max(1.5, size.width / CGFloat(HistoryWindow.pointsPerWindow) - 1)
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(Color.primary.opacity(0.05)))
            for point in points where point.time >= start && point.maximum > 0 {
                let x = CGFloat((point.time - start) / window.duration) * size.width
                let h = size.height * CGFloat(point.maximum >= 1 ? 1 : 0.5)
                let rect = CGRect(x: x, y: size.height - h, width: width, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(point.maximum >= 1 ? 0.9 : 0.45)))
            }
        }
        .frame(height: 14)
        .accessibilityLabel("Inference activity over the last \(window.label)")
    }
}

/// Stacked horizontal bar for memory composition.
struct CompositionBar: View {
    struct Segment: Identifiable {
        var id: String { label }
        var label: String
        var value: Double
        var color: Color
    }

    var segments: [Segment]
    var total: Double

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    let width = total > 0 ? CGFloat(segment.value / total) * (geometry.size.width - CGFloat(segments.count) * 1.5) : 0
                    Rectangle().fill(segment.color).frame(width: max(0, width))
                        .help("\(segment.label): \(Format.bytes(UInt64(max(0, segment.value))))")
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Mini sparkline for tables and the inspector.
struct Sparkline: View {
    var points: [HistoryPoint]
    var color: Color
    var maxValue: Double?

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }
            let top = maxValue ?? max(points.map(\.average).max() ?? 1, 0.0001)
            let start = points.first!.time
            let span = max(1, points.last!.time - start)
            var path = Path()
            for (index, point) in points.enumerated() {
                let x = CGFloat((point.time - start) / span) * size.width
                let y = size.height - CGFloat(min(point.average, top) / top) * size.height
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), lineWidth: 1.25)
        }
    }
}
