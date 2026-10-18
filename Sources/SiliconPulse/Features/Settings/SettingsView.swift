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
            Section {
                Picker("Refresh interval", selection: $settings.samplingInterval) {
                    ForEach(SamplingInterval.allCases) { interval in Text(interval.label).tag(interval) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Monitoring")
            } footer: {
                SettingsFootnote("Applies while the window or the menu bar popover is open. Otherwise SiliconPulse samples every 2–5 s, and in Low Power Mode every interval doubles.")
            }

            Section {
                ForEach(MenuBarItem.allCases) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { settings.menuBarItems.contains(item) },
                        set: { on in
                            if on { settings.menuBarItems.insert(item) } else { settings.menuBarItems.remove(item) }
                            engine.settingsChanged()
                        }))
                }
                Toggle("Show the active model instead while one is loaded", isOn: Binding(
                    get: { settings.menuBarPrefersAI },
                    set: { settings.menuBarPrefersAI = $0; engine.settingsChanged() }))
                LabeledContent("Preview") {
                    MenuBarPreview(title: engine.menuBarTitle)
                }
            } header: {
                Text("Menu bar")
            } footer: {
                SettingsFootnote("With a model loaded the menu bar reads like “Qwen3 · GPU 91% · 38 tok/s”. Tokens/sec appears only while a runner reports live generation counters.")
            }

            Section {
                Toggle("Check runners' default ports", isOn: $settings.probeDefaultPorts)
            } header: {
                Text("AI detection")
            } footer: {
                SettingsFootnote("Finds runners that belong to another user or run in a container. Requests go only to 127.0.0.1: oMLX 8000, Ollama 11434, LM Studio 1234, llama.cpp 8080. Runners SiliconPulse can see as processes are found on whatever port they use.")
            }

            Section {
                if settings.customEndpoints.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
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
                        .help("Remove \(endpoint)")
                    }
                }
                HStack {
                    TextField("Endpoint", text: $newEndpoint, prompt: Text("127.0.0.1:5001"))
                        .onSubmit(addEndpoint)
                    Button("Add", action: addEndpoint).disabled(!isValidEndpoint(newEndpoint))
                }
            } header: {
                Text("Custom endpoints")
            } footer: {
                SettingsFootnote("Any local OpenAI-compatible server SiliconPulse should ask for its models. Loopback addresses only.")
            }

            Section {
                Label("Everything stays on this Mac.", systemImage: "lock.shield")
            } header: {
                Text("Privacy")
            } footer: {
                SettingsFootnote("No analytics, telemetry, accounts, cloud backend or tracking, and nothing is uploaded. The only network requests go to AI runners on 127.0.0.1, and the HTTP client refuses any other host. History is kept in memory and is gone when you quit.")
            }

            Section("Diagnostics") {
                DiagnosticsView()
            }

            Section {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Interfaces", value: "Mach, sysctl, libproc, IOKit, IOPowerSources")
            } header: {
                Text("About")
            } footer: {
                SettingsFootnote("SiliconPulse reports only what macOS and your runners expose through stable interfaces. Hover any value to see where it comes from and how precise it is.")
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

/// Secondary explanatory text under a settings section.
private struct SettingsFootnote: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        // Grouped-form footers are trailing-aligned by default; explanatory copy reads better from the left.
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The current menu bar title, drawn like a menu bar item.
private struct MenuBarPreview: View {
    var title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: BrandMark.menuBarImage)
            if !title.isEmpty {
                Text(title).font(.system(size: 12).monospacedDigit()).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(title.isEmpty ? "Icon only" : title)
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
