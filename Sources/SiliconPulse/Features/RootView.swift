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
            if let window { AppWindows.registeredMainWindow = window }
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
            .navigationSplitViewColumnWidth(min: 190, ideal: 206, max: 240)
            .safeAreaInset(edge: .top) { SidebarHeader() }
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            detail
                .navigationTitle(engine.section.title)
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
            if engine.loadedModelCount > 0 {
                PulseDot(color: Theme.ai, isLive: engine.aiGenerating, size: 6)
                    .help(engine.aiGenerating ? "A local model is generating" : "A local model is loaded")
            }
        case .memory:
            let pressure = engine.memoryPressure
            if pressure == .warning || pressure == .critical {
                Circle().fill(Theme.color(for: pressure)).frame(width: 6, height: 6)
            }
        default:
            EmptyView()
        }
    }
}

/// Product identity at the top of the sidebar.
private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 7) {
            AppMark(size: 18)
            Text("SiliconPulse").font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// Live sampling state and the privacy promise, quietly, at the bottom of the sidebar.
private struct SidebarFooter: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let schedule = engine.activeSchedule
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(engine.isRunning ? Theme.good : Theme.muted).frame(width: 6, height: 6)
                Text(engine.isRunning ? "Live · every \(Format.fixed(schedule.system, schedule.system < 1 ? 1 : 0)) s" : "Paused")
                    .monospacedDigit()
            }
            .help("System metrics every \(schedule.system) s, processes every \(schedule.processes) s, AI detection every \(schedule.aiDiscovery) s. SiliconPulse slows down when its window is hidden.")
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("Local only · no telemetry")
            }
            .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }
}
