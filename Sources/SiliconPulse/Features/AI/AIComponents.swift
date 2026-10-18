import SiliconPulseCore
import SwiftUI

/// One labelled AI value with its scope, so system, process and model numbers never blur together.
struct AIMetricCell: View {
    var label: String
    var value: String?
    var unit: String?
    var scope: MetricScope
    var info: MetricInfo
    var quality: MetricQuality?
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                ScopeTag(scope: scope)
                QualityBadge(info: info, quality: value == nil ? .unavailable : quality)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                if let unit, value != nil {
                    Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(note ?? info.tooltip)
    }
}

/// Prominent summary of a detected workload: model, runner, state, and its key metrics.
struct AIWorkloadSummary: View {
    var workload: AIWorkload
    var compact = false
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let live = engine.liveProcessMetrics(for: workload)
        let model = workload.primaryModel
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workload.title)
                        .font(.system(size: compact ? 17 : 20, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(workload.runner.displayName)
                        if let version = workload.runnerVersion { Text(version).foregroundStyle(.tertiary) }
                        if let endpoint = workload.endpoint {
                            Text("·").foregroundStyle(.tertiary)
                            Text(endpoint).font(.system(size: 11).monospacedDigit())
                        }
                        if let model, let detail = Self.modelDetail(model) {
                            Text("·").foregroundStyle(.tertiary)
                            Text(detail)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    StatusPill(text: workload.state.label, color: Theme.color(for: workload.state))
                    ActivityLabel(activity: workload.activity, lastActivity: workload.lastActivity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: compact ? 4 : 4),
                      alignment: .leading, spacing: 12) {
                AIMetricCell(label: "Tokens/sec", value: workload.tokensPerSecond.value.map { Format.fixed($0, 1) }, unit: "tok/s",
                             scope: .model, info: MetricCatalog.aiTokensPerSecond, quality: workload.tokensPerSecond.quality,
                             note: workload.tokensPerSecond.note)
                AIMetricCell(label: "System GPU", value: engine.system.gpu.deviceUtilization.map { Format.fixed($0 * 100, 0) }, unit: "%",
                             scope: .system, info: MetricCatalog.gpuDevice)
                AIMetricCell(label: "Runner CPU", value: live.cpu.map { Format.processCPU($0) }, unit: "%",
                             scope: .process, info: MetricCatalog.aiProcessCPU)
                AIMetricCell(label: "Runner memory", value: live.memory.map { Format.bytes($0) },
                             scope: .process, info: MetricCatalog.aiProcessMemory)
                if !compact || model?.sizeBytes != nil {
                    AIMetricCell(label: "Model memory", value: model?.sizeBytes.map { Format.bytes($0) },
                                 scope: .model, info: MetricCatalog.aiModelMemory)
                }
                AIMetricCell(label: "Context", value: model?.contextLength.map(Format.integer), unit: "tokens",
                             scope: .model, info: MetricCatalog.aiContext)
                if let offload = model?.gpuOffloadFraction {
                    AIMetricCell(label: "GPU offload", value: Format.fixed(offload * 100, 0), unit: "%",
                                 scope: .model, info: MetricCatalog.aiGPUOffload)
                } else if let layers = model?.gpuLayers {
                    AIMetricCell(label: "GPU layers", value: String(layers), scope: .model, info: MetricCatalog.aiGPUOffload,
                                 note: "From -ngl launch argument")
                }
                if engine.perProcessGPUSupported == true || live.gpu != nil {
                    AIMetricCell(label: "Runner GPU time", value: live.gpu.map { Format.fixed(min($0, 1) * 100, 0) }, unit: "%",
                                 scope: .process, info: MetricCatalog.aiProcessGPU, quality: .estimated)
                }
                AIMetricCell(label: "Runtime", value: workload.runtime(now: engine.system.timestamp).map(Format.duration),
                             scope: .process, info: MetricCatalog.aiRuntime)
            }

            if let timeline = engine.ai.timelines[workload.id] {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Inference activity · last 5 min").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        QualityBadge(info: MetricCatalog.aiInference, quality: workload.activity.quality == .unavailable ? .estimated : workload.activity.quality)
                        Spacer()
                    }
                    ActivityTimeline(points: timeline.points(for: .fiveMinutes), window: .fiveMinutes)
                }
            }
        }
    }

    static func modelDetail(_ model: AIModelInfo) -> String? {
        let parts = [model.parameterSize, model.quantization].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ActivityLabel: View {
    var activity: InferenceActivity
    var lastActivity: Date?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(activity.isBusy ? 1 : 0.6)
            Text(activity.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(activity.isBusy ? color : .secondary)
        }
        .help(helpText)
    }

    private var color: Color {
        switch activity {
        case .active: return Theme.ai
        case .likely: return Theme.ai.opacity(0.75)
        case .idle, .unknown: return Theme.muted
        }
    }

    private var helpText: String {
        var text = activity.evidence.map { "Evidence: \($0)" } ?? "No inference evidence in the last interval."
        if let lastActivity { text += "\nLast activity: \(Format.duration(Date().timeIntervalSince(lastActivity))) ago" }
        text += "\nQuality: \(activity.quality.label)"
        return text
    }
}
