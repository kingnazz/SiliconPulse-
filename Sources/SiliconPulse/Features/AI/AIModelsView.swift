import SiliconPulseCore
import SwiftUI

/// Loaded models first, as first-class objects; model details, evidence and detection diagnostics
/// follow, collapsed until requested.
struct AIModelsView: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let ai = engine.ai
        Page(spacing: 22) {
            PageHeader("AI Models", subtitle: subtitle(ai)) {
                Button {
                    engine.refreshAINow()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Look for runners again now")
            }

            if ai.workloads.isEmpty {
                EmptyAIState(searching: ai.timestamp == .distantPast)
            }
            ForEach(ai.workloads) { workload in
                WorkloadSection(workload: workload, isFeatured: workload.id == ai.featured?.id)
            }

            DetectionDetails(statuses: ai.statuses, lastRefresh: ai.timestamp, duration: ai.duration)
        }
    }

    private func subtitle(_ ai: AIMonitorResult) -> String {
        guard ai.timestamp != .distantPast else { return "Looking for local runtimes…" }
        let loaded = ai.workloads.filter { $0.state == .modelLoaded }.count
        let generating = ai.workloads.filter { $0.activity.isBusy }.count
        if ai.workloads.isEmpty { return "No local runtimes detected" }
        var parts = ["\(ai.workloads.count) runtime\(ai.workloads.count == 1 ? "" : "s")"]
        if loaded > 0 { parts.append("\(loaded) with a model loaded") }
        if generating > 0 { parts.append("\(generating) generating") }
        return parts.joined(separator: " · ")
    }
}

private struct EmptyAIState: View {
    var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if searching { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles").foregroundStyle(.tertiary) }
                Text(searching ? "Looking for local AI runtimes…" : "No local AI runtime detected").font(.sectionTitle)
            }
            Text("Start a runner and it appears here within a few seconds. SiliconPulse only talks to runners on 127.0.0.1.")
                .font(.body13).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(["Ollama", "LM Studio", "llama.cpp", "MLX", "vLLM", "OpenAI-compatible"], id: \.self) { name in
                    Text(name).font(.meta).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.raised, in: Capsule())
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// One runtime: hero first, then the model's facts, then the evidence behind the detection.
private struct WorkloadSection: View {
    var workload: AIWorkload
    var isFeatured: Bool
    @State private var showDetails = false
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ActiveModelHero(workload: workload)

            if workload.models.count > 1 || workload.models.contains(where: { !$0.isConfirmedLoaded }) {
                ModelTable(models: workload.models)
            }

            if let note = limitation {
                LimitationNote(text: note)
            }

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 16) {
                    if let model = workload.primaryModel { ModelFacts(model: model) }
                    EvidenceList(workload: workload)
                    ScopeExplanation()
                }
                .padding(.top, 10)
            } label: {
                Text("Model & detection details").font(.label).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .surface(isFeatured ? .emphasized : .raised, padding: nil)
    }

    private var limitation: String? {
        if workload.processPIDs.isEmpty {
            return "The runner's process is not visible to SiliconPulse (another user's process or a container), so only values its API reports are shown."
        }
        if !workload.tokensPerSecond.isAvailable && workload.counters == nil {
            switch workload.runner {
            case .llamaCpp: return "Start llama-server with --metrics (or keep /slots enabled) to see tokens/sec."
            default: return nil
            }
        }
        return nil
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
            ("Context", model.contextLength.map(Format.integer) ?? ""),
            ("Keep-alive until", model.expiresAt.map { $0.formatted(date: .omitted, time: .standard) } ?? ""),
            ("Reported by", model.source),
        ].filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.metaMedium).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                ForEach(facts, id: \.0) { fact in
                    GridRow {
                        Text(fact.0).foregroundStyle(.secondary)
                        Text(fact.1).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .font(.system(size: 12))
        }
    }
}

private struct EvidenceList: View {
    var workload: AIWorkload
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why SiliconPulse thinks this is \(workload.runner.displayName)").font(.metaMedium).foregroundStyle(.secondary)
            ForEach(Array(workload.evidence.enumerated()), id: \.offset) { _, line in
                row("checkmark", line)
            }
            if let endpoint = workload.endpoint { row("network", "Endpoint \(endpoint)") }
            if !workload.processPIDs.isEmpty {
                row("number", "Processes: " + workload.processPIDs.map { pid in
                    "\(engine.processesByPID[pid]?.name ?? "?") (\(pid))"
                }.joined(separator: ", "))
            }
            if let evidence = workload.activity.evidence { row("waveform", "Activity: " + evidence) }
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 12)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// The SYSTEM / PROCESS / MODEL distinction, explained once, inside the details.
private struct ScopeExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How to read these numbers").font(.metaMedium).foregroundStyle(.secondary)
            Text("Model values come from the runner's API. Runner values are measured for its own processes. System GPU is the whole Mac and is never attributed to a model. Values marked Estimated are inferred, not measured.")
                .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ModelTable: View {
    var models: [AIModelInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Params").frame(width: 70, alignment: .trailing)
                Text("Quant").frame(width: 80, alignment: .trailing)
                Text("Context").frame(width: 70, alignment: .trailing)
                Text("Size").frame(width: 80, alignment: .trailing)
                Text("State").frame(width: 80, alignment: .trailing)
            }
            .font(.metaMedium)
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)
            .hairlineBelow()
            ForEach(models) { model in
                HStack {
                    Text(model.displayName).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.parameterSize ?? "—").frame(width: 70, alignment: .trailing)
                    Text(model.quantization ?? "—").frame(width: 80, alignment: .trailing)
                    Text(model.contextLength.map(Format.integer) ?? "—").frame(width: 70, alignment: .trailing)
                    Text(model.sizeBytes.map { Format.bytes($0) } ?? "—").frame(width: 80, alignment: .trailing)
                    Text(model.isConfirmedLoaded ? "Loaded" : "Listed").foregroundStyle(model.isConfirmedLoaded ? .primary : .secondary)
                        .frame(width: 80, alignment: .trailing)
                        .help(model.isConfirmedLoaded ? "The runner reports this model as loaded." : "Listed by /v1/models; the API does not say whether it is loaded.")
                }
                .font(.numeric)
                .padding(.vertical, 5)
                .hairlineBelow()
            }
        }
    }
}

/// Provider-by-provider detection status. Diagnostics, so collapsed by default.
private struct DetectionDetails: View {
    var statuses: [AIProviderStatus]
    var lastRefresh: Date
    var duration: TimeInterval
    @State private var expanded = false
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(statuses) { status in
                    HStack {
                        Circle().fill(status.detected ? Theme.good : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                        Text(status.runner == .pythonInference ? "Python / OpenAI-compatible" : status.runner.displayName)
                            .frame(width: 200, alignment: .leading)
                        Text(status.summary).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 5)
                    .hairlineBelow()
                }
                if lastRefresh != .distantPast {
                    Text("Checked \(lastRefresh.formatted(date: .omitted, time: .standard)) in \(Format.fixed(duration * 1000, 0)) ms, every \(Format.fixed(engine.activeSchedule.aiDiscovery, 0)) s while visible. Only 127.0.0.1 is contacted.")
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Detection details").font(.label).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
