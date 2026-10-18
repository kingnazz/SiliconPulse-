import SiliconPulseCore
import SwiftUI

struct ChartSeries {
    var points: [HistoryPoint]
    var color: Color
    var label: String
    var dashed = false
    var fill = true
}

/// Time-series chart drawn with Canvas: far cheaper than Swift Charts at one update per second.
///
/// Lines are smoothed with midpoint quadratic curves (which never overshoot the data), the grid is
/// reduced to a baseline and one quiet midline, and the newest value carries a marker. Until the
/// history fills the window, the x-axis spans the data actually collected, so a fresh launch shows
/// a full-width chart rather than a half-empty one.
struct LineChart: View {
    var series: [ChartSeries]
    var window: HistoryWindow
    var maxValue: Double?
    var format: (Double) -> String
    var height: CGFloat = 86
    var showsScale = true
    var showsMarker = true

    @State private var hoverX: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    private static let minimumSpan: TimeInterval = 20

    var body: some View {
        let end = series.compactMap { $0.points.last?.time }.max() ?? Date().timeIntervalSinceReferenceDate
        let earliest = series.compactMap { $0.points.first?.time }.min() ?? end
        let start = max(end - window.duration, min(earliest, end - Self.minimumSpan))
        let span = max(1, end - start)
        let peak = series.flatMap { $0.points.map(\.average) }.max() ?? 0
        let top = maxValue ?? Self.niceCeiling(peak)
        let fillOpacity = colorScheme == .dark ? 0.28 : 0.18

        Canvas { context, size in
            let plotTop: CGFloat = 4
            let plotHeight = max(1, size.height - plotTop - 1)
            func y(_ value: Double) -> CGFloat { plotTop + plotHeight - CGFloat(min(max(value, 0), top) / top) * plotHeight }
            func x(_ time: TimeInterval) -> CGFloat { CGFloat((time - start) / span) * size.width }

            // Baseline, a quiet top line that carries the scale label, and a fainter midline.
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(Theme.grid), lineWidth: 1)
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: y(top / 2)))
            mid.addLine(to: CGPoint(x: size.width, y: y(top / 2)))
            context.stroke(mid, with: .color(Theme.grid.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            if showsScale {
                var ceiling = Path()
                ceiling.move(to: CGPoint(x: 0, y: plotTop))
                ceiling.addLine(to: CGPoint(x: size.width, y: plotTop))
                context.stroke(ceiling, with: .color(Theme.grid), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
            guard top > 0 else { return }

            for s in series {
                let points = s.points.filter { $0.time >= start - window.bucketWidth }
                guard points.count > 1 else { continue }
                let coordinates = points.map { CGPoint(x: x($0.time), y: y($0.average)) }
                let line = Self.smoothPath(coordinates)
                if s.fill && !s.dashed {
                    var area = line
                    area.addLine(to: CGPoint(x: coordinates.last!.x, y: size.height))
                    area.addLine(to: CGPoint(x: coordinates.first!.x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [s.color.opacity(fillOpacity), s.color.opacity(0)]),
                        startPoint: CGPoint(x: 0, y: plotTop), endPoint: CGPoint(x: 0, y: size.height)))
                }
                context.stroke(line, with: .color(s.dashed ? s.color.opacity(0.7) : s.color),
                               style: StrokeStyle(lineWidth: s.dashed ? 1.25 : 1.75, lineCap: .round, lineJoin: .round,
                                                  dash: s.dashed ? [3, 3] : []))
                if showsMarker && !s.dashed, let last = coordinates.last {
                    let dot = CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(Theme.page))
                    context.fill(Path(ellipseIn: dot), with: .color(s.color))
                }
            }

            if let hoverX {
                var rule = Path()
                rule.move(to: CGPoint(x: hoverX, y: plotTop))
                rule.addLine(to: CGPoint(x: hoverX, y: size.height))
                context.stroke(rule, with: .color(Color.primary.opacity(0.22)), lineWidth: 1)
                let time = start + Double(hoverX / max(1, size.width)) * span
                for s in series where !s.dashed {
                    guard let nearest = s.points.min(by: { abs($0.time - time) < abs($1.time - time) }) else { continue }
                    let point = CGPoint(x: x(nearest.time), y: y(nearest.average))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(Theme.page))
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(s.color), lineWidth: 1.5)
                }
            }
        }
        .frame(height: height)
        .padding(.trailing, showsMarker ? 4 : 0)
        .overlay(alignment: .topLeading) {
            if showsScale {
                // Inside the plot, just under the top line, so it reads as the chart's scale.
                Text(format(top)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                    .padding(.leading, 2).padding(.top, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let hoverX { hoverLabel(at: hoverX, start: start, span: span) }
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

    private func hoverLabel(at x: CGFloat, start: TimeInterval, span: TimeInterval) -> some View {
        GeometryReader { geometry in
            let time = start + Double(x / max(1, geometry.size.width)) * span
            let values = series.compactMap { s -> (String, Color)? in
                guard let nearest = s.points.min(by: { abs($0.time - time) < abs($1.time - time) }),
                      abs(nearest.time - time) <= window.bucketWidth * 3 else { return nil }
                return ("\(s.label) \(format(nearest.average))", s.color)
            }
            let ago = Int(max(0, (series.compactMap { $0.points.last?.time }.max() ?? time) - time))
            VStack(alignment: .leading, spacing: 2) {
                Text(ago == 0 ? "Now" : "\(Format.duration(Double(ago))) ago").foregroundStyle(.secondary)
                ForEach(values, id: \.0) { value in
                    HStack(spacing: 5) {
                        Circle().fill(value.1).frame(width: 6, height: 6)
                        Text(value.0).foregroundStyle(.primary)
                    }
                }
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
            .fixedSize()
            .offset(x: min(max(0, x + 12), max(0, geometry.size.width - 150)), y: 2)
        }
        .allowsHitTesting(false)
    }

    /// Midpoint quadratic smoothing: curves pass through segment midpoints with the samples as control
    /// points, so the line stays within the data's range (no overshoot below zero or above 100%).
    static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
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

/// Compact titled chart for secondary metrics: title and current value on one line, no container.
struct ChartCard: View {
    var title: String
    var value: String
    var info: MetricInfo
    var series: [ChartSeries]
    var window: HistoryWindow
    var maxValue: Double?
    var format: (Double) -> String
    var height: CGFloat = 86
    var emptyMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.label)
                QualityBadge(info: info)
                Spacer()
                Text(value).font(.numericMedium).foregroundStyle(.secondary)
            }
            .metricHelp(info)
            LineChart(series: series, window: window, maxValue: maxValue, format: format, height: height, showsScale: false)
                .overlay {
                    if let emptyMessage, series.allSatisfy({ $0.points.isEmpty }) {
                        Text(emptyMessage).font(.meta).foregroundStyle(.tertiary)
                    }
                }
            if series.count > 1 {
                ChartLegend(series: series)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChartLegend: View {
    var series: [ChartSeries]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(series.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    Capsule()
                        .fill(series[index].color.opacity(series[index].dashed ? 0.65 : 1))
                        .frame(width: 10, height: 2.5)
                    Text(series[index].label).font(.meta).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Strip showing when inference was active (tall, full accent) or likely (short, faded).
struct ActivityTimeline: View {
    var points: [HistoryPoint]
    var window: HistoryWindow
    var color: Color = Theme.ai
    var height: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            let end = points.last?.time ?? Date().timeIntervalSinceReferenceDate
            let start = end - window.duration
            let barWidth = max(2, size.width / CGFloat(HistoryWindow.pointsPerWindow) - 1.5)
            // A thin lane spanning the whole window, so a few recent bars still read as a timeline.
            let lane = CGRect(x: 0, y: size.height - 3, width: size.width, height: 3)
            context.fill(Path(roundedRect: lane, cornerRadius: 1.5), with: .color(Theme.track))
            for point in points where point.time >= start && point.maximum > 0 {
                let x = CGFloat((point.time - start) / window.duration) * size.width
                let active = point.maximum >= 1
                let h = size.height * (active ? 1 : 0.45)
                let rect = CGRect(x: min(x, size.width - barWidth), y: size.height - h, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, barWidth / 2)),
                             with: .color(color.opacity(active ? 0.95 : 0.4)))
            }
        }
        .frame(height: height)
        .accessibilityLabel("Inference activity over the last \(window.label)")
    }
}

/// Stacked horizontal bar for memory composition. Segments add up to the total; the remainder is free.
struct CompositionBar: View {
    struct Segment: Identifiable {
        var id: String { label }
        var label: String
        var value: Double
        var color: Color
    }

    var segments: [Segment]
    var total: Double
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let visible = segments.filter { $0.value > 0 }
            let usable = geometry.size.width - gap * CGFloat(max(0, visible.count))
            HStack(spacing: gap) {
                ForEach(visible) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: total > 0 ? max(2, CGFloat(segment.value / total) * usable) : 0)
                        .help("\(segment.label): \(Format.bytes(UInt64(max(0, segment.value))))")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.track)
            .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
        }
        .frame(height: height)
    }
}

/// Minimal sparkline for lists and the inspector.
struct Sparkline: View {
    var points: [HistoryPoint]
    var color: Color
    var maxValue: Double?
    var fill = false

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }
            let top = maxValue ?? max(points.map(\.average).max() ?? 1, 0.0001)
            let start = points.first!.time
            let span = max(1, points.last!.time - start)
            let coordinates = points.map { point in
                CGPoint(x: CGFloat((point.time - start) / span) * size.width,
                        y: size.height - 1 - CGFloat(min(point.average, top) / top) * (size.height - 2))
            }
            let line = LineChart.smoothPath(coordinates)
            if fill {
                var area = line
                area.addLine(to: CGPoint(x: coordinates.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: coordinates.first!.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.15)))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}
