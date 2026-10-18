import SiliconPulseCore
import SwiftUI

struct AIModelsView: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let ai = engine.ai
        Page {
            ScopeLegend()
            if ai.workloads.isEmpty {
                Panel {
                    if ai.timestamp == .distantPast {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for local AI runtimes…").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        EmptyStateView(symbol: "sparkles", title: "No local AI runtime detected",
                                       message: "Start Ollama, LM Studio's local server, llama-server, mlx_lm or another OpenAI-compatible server and it will appear here within a few seconds.")
                    }
                }
            }
            ForEach(ai.workloads) { workload in
                AIWorkloadPanel(workload: workload)
            }
            DetectionStatusPanel(statuses: ai.statuses, lastRefresh: ai.timestamp, duration: ai.duration)
        }
    }
}

/// Explains the three scopes once, at the top.
private struct ScopeLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            legend(.system, "Whole Mac, shared by everything running")
            legend(.process, "The runner's own processes")
            legend(.model, "Reported by the runner about the model")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func legend(_ scope: MetricScope, _ text: String) -> some View {
        HStack(spacing: 5) {
            ScopeTag(scope: scope)
            Text(text)
        }
    }
}

private struct AIWorkloadPanel: View {
    var workload: AIWorkload
    @State private var showEvidence = false
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        Panel {
            AIWorkloadSummary(workload: workload)

            if workload.models.count > 1 || workload.models.contains(where: { !$0.isConfirmedLoaded }) {
                Divider()
                ModelTable(models: workload.models)
            } else if let model = workload.primaryModel {
                Divider()
                ModelFacts(model: model)
            }

            if !workload.tokensPerSecond.isAvailable && workload.counters == nil {
                LimitationNote(text: throughputExplanation)
            }

            Divider()
            DisclosureGroup(isExpanded: $showEvidence) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(workload.evidence.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark.circle").foregroundStyle(.tertiary)
                            Text(line).textSelection(.enabled)
                        }
                    }
                    if !workload.processPIDs.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "number").foregroundStyle(.tertiary)
                            Text("Processes: " + workload.processPIDs.map { pid in
                                let name = engine.processesByPID[pid]?.name ?? "?"
                                return "\(name) (\(pid))"
                            }.joined(separator: ", "))
                            .textSelection(.enabled)
                        }
                    }
                    if let evidence = workload.activity.evidence {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "waveform").foregroundStyle(.tertiary)
                            Text("Activity: " + evidence)
                        }
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            } label: {
                Text("Why SiliconPulse thinks this is \(workload.runner.displayName)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var throughputExplanation: String {
        switch workload.runner {
        case .ollama:
            return "Ollama does not publish live tokens/sec to other apps, so SiliconPulse does not show one. Activity comes from keep-alive refreshes and the runner's GPU time."
        case .lmStudio:
            return "LM Studio's API reports what is loaded but not live generation speed, so tokens/sec is not shown."
        case .mlx:
            return "mlx_lm has no status API; the model comes from its launch arguments and activity from process GPU time."
        case .llamaCpp:
            return "Start llama-server with --metrics (or keep /slots enabled) to get tokens/sec."
        case .pythonInference, .openAICompatible:
            return "This runner exposes no generation counters, so tokens/sec is not shown."
        }
    }
}

private struct ModelFacts: View {
    var model: AIModelInfo

    var body: some View {
        let facts: [(String, String)] = [
            ("Identifier", model.identifier),
            ("Family", model.family ?? ""),
            ("Parameters", model.parameterSize ?? ""),
            ("Quantization", model.quantization ?? ""),
            ("Format", model.format ?? ""),
            ("Keep-alive until", model.expiresAt.map { $0.formatted(date: .omitted, time: .standard) } ?? ""),
            ("Source", model.source),
        ].filter { !$0.1.isEmpty }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(facts, id: \.0) { fact in
                HStack(spacing: 6) {
                    Text(fact.0).foregroundStyle(.secondary)
                    Text(fact.1).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .font(.system(size: 11.5))
            }
        }
    }
}

private struct ModelTable: View {
    var models: [AIModelInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Params").frame(width: 70, alignment: .trailing)
                Text("Quant").frame(width: 80, alignment: .trailing)
                Text("Context").frame(width: 70, alignment: .trailing)
                Text("Size").frame(width: 80, alignment: .trailing)
                Text("State").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            ForEach(models) { model in
                HStack {
                    Text(model.displayName).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.parameterSize ?? "—").frame(width: 70, alignment: .trailing)
                    Text(model.quantization ?? "—").frame(width: 80, alignment: .trailing)
                    Text(model.contextLength.map(Format.integer) ?? "—").frame(width: 70, alignment: .trailing)
                    Text(model.sizeBytes.map { Format.bytes($0) } ?? "—").frame(width: 80, alignment: .trailing)
                    Text(model.isConfirmedLoaded ? "Loaded" : "Listed").foregroundStyle(model.isConfirmedLoaded ? .primary : .secondary)
                        .frame(width: 90, alignment: .trailing)
                        .help(model.isConfirmedLoaded ? "The runner reports this model as loaded." : "Listed by /v1/models; the API does not say whether it is loaded.")
                }
                .font(.numeric)
            }
        }
    }
}

private struct DetectionStatusPanel: View {
    var statuses: [AIProviderStatus]
    var lastRefresh: Date
    var duration: TimeInterval
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        Panel("Detection", accessory: AnyView(
            Button {
                engine.refreshAINow()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        )) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(statuses) { status in
                    HStack {
                        Circle().fill(status.detected ? Theme.good : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                        Text(status.runner == .pythonInference ? "Python / OpenAI-compatible" : status.runner.displayName)
                            .frame(width: 200, alignment: .leading)
                        Text(status.summary).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.system(size: 12))
                }
                if lastRefresh != .distantPast {
                    Text("Checked \(lastRefresh.formatted(date: .omitted, time: .standard)) in \(Format.fixed(duration * 1000, 0)) ms · every \(Format.fixed(engine.activeSchedule.aiDiscovery, 0)) s while visible. Only 127.0.0.1 is contacted.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
        }
    }
}
