import SiliconPulseCore
import SwiftUI

struct SettingsView: View {
    var standalone: Bool
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var newEndpoint = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Monitoring") {
                Picker("Refresh interval", selection: $settings.samplingInterval) {
                    ForEach(SamplingInterval.allCases) { interval in Text(interval.label).tag(interval) }
                }
                .pickerStyle(.segmented)
                Text("Used while the window or menu bar popover is visible. When hidden, SiliconPulse slows to every 2–5 s; in Low Power Mode every interval doubles.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                ForEach(MenuBarItem.allCases) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { settings.menuBarItems.contains(item) },
                        set: { on in
                            if on { settings.menuBarItems.insert(item) } else { settings.menuBarItems.remove(item) }
                            engine.settingsChanged()
                        }))
                }
                Toggle("When a model is loaded, show it instead (for example “Qwen3 · GPU 91% · 38 tok/s”)", isOn: Binding(
                    get: { settings.menuBarPrefersAI },
                    set: { settings.menuBarPrefersAI = $0; engine.settingsChanged() }))
                LabeledContent("Preview") {
                    Text(engine.menuBarTitle.isEmpty ? "Icon only" : engine.menuBarTitle).font(.system(size: 12).monospacedDigit())
                }
            }

            Section("AI detection") {
                Toggle("Check default runner ports even without a matching process", isOn: $settings.probeDefaultPorts)
                Text("Finds runners owned by another user or running in a container. Requests go only to 127.0.0.1 (ports 11434, 1234, 8080).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(settings.customEndpoints, id: \.self) { endpoint in
                    HStack {
                        Text(endpoint).font(.system(size: 12).monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            settings.customEndpoints.removeAll { $0 == endpoint }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Custom OpenAI-compatible endpoint, e.g. 127.0.0.1:5001", text: $newEndpoint)
                        .onSubmit(addEndpoint)
                    Button("Add", action: addEndpoint).disabled(!isValidEndpoint(newEndpoint))
                }
            }

            Section("Privacy") {
                Label("Everything stays on this Mac.", systemImage: "lock.shield")
                Text("SiliconPulse has no analytics, telemetry, accounts, cloud backend or tracking. It never uploads data. The only network requests it makes are to AI runners on 127.0.0.1, and its HTTP client refuses any other host. History is kept in memory and is gone when you quit.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Diagnostics") {
                DiagnosticsView()
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Interfaces", value: "Mach, sysctl, libproc, IOKit, IOPowerSources")
                Text("SiliconPulse reports only what macOS exposes through stable interfaces. Hover the ⓘ next to any value to see how it is measured and how precise it is.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.samplingInterval) { _, _ in engine.settingsChanged() }
        .onChange(of: settings.probeDefaultPorts) { _, _ in engine.refreshAINow() }
        .onChange(of: settings.customEndpoints) { _, _ in engine.refreshAINow() }
    }

    private func isValidEndpoint(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        return URL(string: candidate).map(LoopbackPolicy.isAllowed) ?? false
    }

    private func addEndpoint() {
        guard isValidEndpoint(newEndpoint) else { return }
        let value = newEndpoint.trimmingCharacters(in: .whitespaces)
        if !settings.customEndpoints.contains(value) { settings.customEndpoints.append(value) }
        newEndpoint = ""
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// Live self-measurement: proves there is one sampling loop and shows what each collector costs.
struct DiagnosticsView: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let d = engine.diagnostics
        VStack(alignment: .leading, spacing: 0) {
            StatRow(label: "SiliconPulse CPU", value: d.selfCPUPercent.map { Format.processCPU($0) + "%" } ?? "—")
            StatRow(label: "SiliconPulse memory", value: d.selfFootprint.map { Format.bytes($0) } ?? "—")
            StatRow(label: "Sampling loops running", value: "\(d.activeLoops)", valueColor: d.activeLoops == 1 ? .primary : Theme.critical)
            StatRow(label: "Schedule", value: "system \(Format.fixed(d.schedule.system, 1)) s · processes \(Format.fixed(d.schedule.processes, 1)) s · AI \(Format.fixed(d.schedule.aiDiscovery, 0)) s")
            StatRow(label: "Samples", value: "\(d.systemSamples) system · \(d.processSamples) process · \(d.aiRefreshes) AI")
            StatRow(label: "Last AI detection", value: Format.fixed(d.lastAIRefreshDuration * 1000, 0) + " ms")
            StatRow(label: "History points held", value: "\(d.historyPoints)")
            if !d.timings.isEmpty {
                Divider().padding(.vertical, 6)
                Text("Collector cost (thread CPU per run)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(d.timings) { timing in
                    StatRow(label: timing.name, value: "\(Format.fixed(timing.averageCPUMilliseconds, 2)) ms avg · \(timing.runs) runs")
                }
            }
        }
    }
}
