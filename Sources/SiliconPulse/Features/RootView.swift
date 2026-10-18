import SiliconPulseCore
import SwiftUI

struct RootView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var visibilityToken = VisibilityToken()

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                mainSplit
            } else {
                OnboardingView {
                    settings.hasCompletedOnboarding = true
                    engine.start()
                }
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(WindowVisibilityReporter { visible, window in
            engine.setDashboardVisible(visible, token: ObjectIdentifier(visibilityToken))
            if !visible && window == nil { AppWindows.mainWindowClosed() }
        })
        .onAppear {
            AppWindows.openMainAction = { openWindow(id: WindowID.main) }
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            engine.setDashboardVisible(false, token: ObjectIdentifier(visibilityToken))
            AppWindows.mainWindowClosed()
        }
    }

    private var mainSplit: some View {
        NavigationSplitView {
            List(selection: Binding<AppSection?>(get: { engine.section }, set: { if let s = $0 { engine.section = s } })) {
                Section {
                    ForEach([AppSection.overview, .ai, .processes]) { section in
                        SidebarRow(section: section).tag(section)
                    }
                }
                Section("Resources") {
                    ForEach([AppSection.memory, .compute, .diskNetwork, .history]) { section in
                        SidebarRow(section: section).tag(section)
                    }
                }
                Section {
                    SidebarRow(section: .settings).tag(AppSection.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            detail
                .navigationTitle(engine.section.title)
                .toolbar {
                    ToolbarItem(placement: .automatic) { SamplingStatus() }
                }
        }
    }

    @ViewBuilder private var detail: some View {
        switch engine.section {
        case .overview: OverviewView()
        case .ai: AIModelsView()
        case .processes: ProcessesView()
        case .memory: MemoryView()
        case .compute: ComputeView()
        case .diskNetwork: DiskNetworkView()
        case .history: HistoryView()
        case .settings: SettingsView(standalone: false)
        }
    }
}

/// Identity object for visibility reporting; one per window instance.
final class VisibilityToken {}

private struct SidebarRow: View {
    var section: AppSection
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                badge
            }
        } icon: {
            Image(systemName: section.symbol)
        }
    }

    @ViewBuilder private var badge: some View {
        switch section {
        case .ai:
            let loaded = engine.ai.workloads.filter { $0.state == .modelLoaded }.count
            if loaded > 0 {
                Text("\(loaded)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
        case .memory:
            let pressure = engine.system.memory.pressure
            if pressure == .warning || pressure == .critical {
                Circle().fill(Theme.color(for: pressure)).frame(width: 6, height: 6)
            }
        default:
            EmptyView()
        }
    }
}

private struct SidebarFooter: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let memory = engine.system.memory
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(.tertiary)
                Text("Local only · no telemetry").foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5))
            if memory.total > 0 {
                Text(engine.system.cpu.topology.brand + " · " + Format.bytes(memory.total, decimals: 0))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

/// Toolbar indicator showing the live sampling cadence.
private struct SamplingStatus: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let schedule = engine.diagnostics.schedule
        HStack(spacing: 6) {
            Circle()
                .fill(engine.isRunning ? Theme.good : Theme.muted)
                .frame(width: 6, height: 6)
            Text(engine.isRunning ? "Sampling every \(Format.fixed(schedule.system, schedule.system < 1 ? 1 : 0)) s" : "Paused")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .help("System metrics every \(schedule.system) s, processes every \(schedule.processes) s, AI detection every \(schedule.aiDiscovery) s. Slower when the window is hidden.")
    }
}
