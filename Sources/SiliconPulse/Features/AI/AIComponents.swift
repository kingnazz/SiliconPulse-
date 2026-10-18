import SiliconPulseCore
import SwiftUI

/// The headline numbers for a workload, chosen honestly: model values when the runner reports them,
/// runner-process values when the process is visible, and system GPU only ever labelled as system-wide.
struct WorkloadHeadline {
    struct Item: Identifiable {
        var id: String { label }
        var label: String
        var value: String
        var unit: String?
        var caption: String?
        var info: MetricInfo
        var quality: MetricQuality?
    }

    var items: [Item]
    var details: [String]

    @MainActor
    init(_ w: AIWorkload, engine: MonitorEngine) {
        let live = engine.liveProcessMetrics(for: w)
        let model = w.primaryModel
        let hasProcess = !w.processPIDs.isEmpty
        var items: [Item] = []

        // Throughput: only a measured value; otherwise say why there is none.
        if let tps = w.tokensPerSecond.value {
            // The note says what kind of figure this is (last generation, session average); live rates have none.
            let caption = w.tokensPerSecond.note ?? (w.activity.isBusy ? "Generating now" : "Last generation")
            items.append(Item(label: "Tokens / sec", value: Format.fixed(tps, tps >= 100 ? 0 : 1), caption: caption,
                              info: MetricCatalog.aiTokensPerSecond, quality: w.tokensPerSecond.quality))
        } else {
            items.append(Item(label: "Tokens / sec", value: "—", caption: "Not exposed by \(w.runner.displayName)",
                              info: MetricCatalog.aiTokensPerSecond, quality: .unavailable))
        }

        // GPU: the runner's own GPU time when measurable, always next to the system-wide figure.
        let systemGPU = engine.system.gpu.deviceUtilization
        if hasProcess, let gpu = live.gpu {
            items.append(Item(label: "Runner GPU", value: Format.fixed(min(gpu, 1) * 100, 0), unit: "%",
                              caption: systemGPU.map { "System GPU \(Format.percent($0))" } ?? "Share of GPU time",
                              info: MetricCatalog.aiProcessGPU, quality: .estimated))
        } else {
            items.append(Item(label: "System GPU", value: systemGPU.map { Format.fixed($0 * 100, 0) } ?? "—",
                              unit: systemGPU == nil ? nil : "%", caption: systemGPU == nil ? "Not reported on this Mac" : "Whole Mac, all apps",
                              info: MetricCatalog.gpuDevice))
        }

        // Memory: what the runner says the model takes, else the runner's footprint.
        if let size = model?.sizeBytes {
            let offload = model?.gpuOffloadFraction.map { " · \(Format.percent($0)) on GPU" } ?? ""
            items.append(Item(label: "Model memory", value: Format.bytes(size), caption: "Reported by \(w.runner.displayName)" + offload,
                              info: MetricCatalog.aiModelMemory))
        } else if hasProcess, let memory = live.memory {
            items.append(Item(label: "Runner memory", value: Format.bytes(memory), caption: "Process footprint",
                              info: MetricCatalog.aiProcessMemory))
        }

        if hasProcess, let cpu = live.cpu {
            items.append(Item(label: "Runner CPU", value: Format.processCPU(cpu), unit: "%", caption: "100% = one core",
                              info: MetricCatalog.aiProcessCPU))
        }
        self.items = items

        var details: [String] = []
        if let available = w.availableModelCount, available > 1 {
            details.append("\(w.models.count) of \(available) models loaded")
        }
        if let context = model?.contextLength { details.append("Context \(Self.compactTokens(context))") }
        if let runtime = w.runtime(now: engine.system.timestamp), hasProcess { details.append("Up \(Format.duration(runtime))") }
        if let layers = model?.gpuLayers { details.append("\(layers) GPU layers") }
        if let endpoint = w.endpoint { details.append(endpoint) }
        self.details = details
    }

    static func compactTokens(_ value: Int) -> String {
        value >= 1024 && value % 1024 == 0 ? "\(value / 1024)K" : Format.integer(value)
    }
}

extension AIRunner {
    /// Neutral monogram (not a brand mark) shown in the runner glyph.
    var monogram: String {
        switch self {
        case .ollama: return "O"
        case .lmStudio: return "LM"
        case .llamaCpp: return "L"
        case .omlx: return "oM"
        case .mlx: return "MX"
        case .pythonInference: return "Py"
        case .openAICompatible: return "AI"
        }
    }
}

/// Small rounded tile identifying the runner.
struct RunnerGlyph: View {
    var runner: AIRunner
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Theme.ai.opacity(0.14))
            .overlay(
                Text(runner.monogram)
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ai)
            )
            .frame(width: size, height: size)
    }
}

/// The Active Model hero: the centrepiece of Overview and of each AI Models entry.
struct ActiveModelHero: View {
    var workload: AIWorkload
    var showsTimelineCaption = true
    var onOpenDetails: (() -> Void)?
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let headline = WorkloadHeadline(workload, engine: engine)
        let model = workload.primaryModel
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                RunnerGlyph(runner: workload.runner)
                VStack(alignment: .leading, spacing: 3) {
                    Text(workload.title)
                        .font(.heroTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(subtitle(model))
                        .font(.body13)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    ActivityLabel(activity: workload.activity, lastActivity: workload.lastActivity, state: workload.state)
                    if let onOpenDetails {
                        Button("Details", action: onOpenDetails).buttonStyle(.link).font(.meta)
                    }
                }
            }

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(headline.items.enumerated()), id: \.element.id) { index, item in
                    MetricReadout(label: item.label, value: item.value, unit: item.unit, caption: item.caption,
                                  info: item.info, quality: item.quality, valueFont: .metricLarge,
                                  tint: index == 0 && workload.liveTokensPerSecond != nil ? Theme.ai : .primary)
                        .padding(.trailing, 16)
                        .padding(.leading, index == 0 ? 0 : 16)
                        .overlay(alignment: .leading) {
                            if index > 0 { Rectangle().fill(Theme.hairline).frame(width: 1) }
                        }
                }
            }

            if let timeline = engine.ai.timelines[workload.id] {
                VStack(alignment: .leading, spacing: 6) {
                    ActivityTimeline(points: timeline.points(for: .fiveMinutes), window: .fiveMinutes, height: 16)
                    if showsTimelineCaption {
                        HStack(spacing: 6) {
                            Text("Inference, last 5 minutes")
                            if !headline.details.isEmpty {
                                Text("·")
                                Text(headline.details.joined(separator: " · "))
                            }
                            Spacer(minLength: 0)
                            QualityBadge(info: MetricCatalog.aiInference,
                                         quality: workload.activity.quality == .unavailable ? .estimated : workload.activity.quality)
                        }
                        .font(.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }
        }
    }

    private func subtitle(_ model: AIModelInfo?) -> String {
        var parts = [workload.runner.displayName]
        if let model {
            parts += [model.parameterSize, model.quantization].compactMap { $0 }
        }
        if workload.state != .modelLoaded && workload.state != .processOnly { parts.append(workload.state.label) }
        return parts.joined(separator: " · ")
    }
}

/// "Generating" with a live pulse, or a quiet state.
struct ActivityLabel: View {
    var activity: InferenceActivity
    var lastActivity: Date?
    var state: AIWorkloadState = .modelLoaded

    var body: some View {
        HStack(spacing: 4) {
            PulseDot(color: color, isLive: activity.isBusy, size: 7)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(activity.isBusy ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
        }
        .help(helpText)
    }

    private var text: String {
        switch activity {
        case .active: return "Generating"
        case .likely: return "Likely generating"
        case .idle, .unknown:
            switch state {
            case .apiUnreachable: return "API not responding"
            case .idle: return "No model loaded"
            default: return "Idle"
            }
        }
    }

    private var color: Color {
        switch activity {
        case .active: return Theme.ai
        case .likely: return Theme.ai.opacity(0.8)
        case .idle, .unknown: return state == .apiUnreachable ? Theme.caution : Color.secondary.opacity(0.6)
        }
    }

    private var helpText: String {
        var text = activity.evidence.map { "Evidence: \($0)" } ?? "No inference evidence in the last interval."
        if let lastActivity { text += "\nLast activity: \(Format.duration(Date().timeIntervalSince(lastActivity))) ago" }
        text += "\nQuality: \(activity.quality.label)"
        return text
    }
}
