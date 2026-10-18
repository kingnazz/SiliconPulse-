import SiliconPulseCore
import SwiftUI

/// Compact popover shown from the menu bar item.
struct MenuBarPopover: View {
    /// Render live values even without a visible window (used for offscreen rendering).
    var alwaysLive = false
    @Environment(MonitorEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var token = VisibilityToken()
    @State private var isVisible = false

    var body: some View {
        // SwiftUI keeps this view alive while the popover is closed. Reading the per-second system
        // snapshot only while it is open keeps the closed popover from re-rendering every sample.
        let s = (isVisible || alwaysLive) ? engine.system : SystemSnapshot.empty
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SiliconPulse").font(.system(size: 13, weight: .semibold))
                Spacer()
                if s.memory.pressure != .normal && s.memory.pressure != .unknown {
                    StatusPill(text: s.memory.pressure.label, color: Theme.color(for: s.memory.pressure))
                }
            }

            if settings.hasCompletedOnboarding {
                VStack(spacing: 7) {
                    popoverRow("CPU", Format.percent(s.cpu.usage.total), fraction: s.cpu.usage.total, color: Theme.cpu)
                    popoverRow("GPU", s.gpu.deviceUtilization.map { Format.percent($0) } ?? "—", fraction: s.gpu.deviceUtilization, color: Theme.gpu)
                    popoverRow("Memory", "\(Format.fixed(Double(s.memory.used) / 1_073_741_824, 1)) / \(Format.fixed(Double(s.memory.total) / 1_073_741_824, 0)) GB",
                               fraction: s.memory.usedFraction, color: Theme.memory)
                    HStack {
                        Text("Pressure").foregroundStyle(.secondary)
                        Spacer()
                        Text(s.memory.pressure.label).foregroundStyle(Theme.color(for: s.memory.pressure))
                        Text("· swap \(Format.bytes(s.memory.swapUsed))").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Thermal").foregroundStyle(.secondary)
                        Spacer()
                        Text(s.thermal.level.label).foregroundStyle(s.thermal.level.isConstrained ? Theme.color(for: s.thermal.level) : .primary)
                    }
                }
                .font(.system(size: 12).monospacedDigit())

                if let workload = engine.ai.featured {
                    Divider()
                    PopoverAISection(workload: workload)
                }
            } else {
                Text("Open SiliconPulse to start monitoring.").font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                PopoverButton(title: "Open SiliconPulse", shortcut: "") { openMain(section: nil) }
                PopoverButton(title: "Settings…", shortcut: "") { openMain(section: .settings) }
                PopoverButton(title: "Quit SiliconPulse", shortcut: "") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 290)
        .background {
            // ImageRenderer cannot draw AppKit views, so offscreen renders skip the tracker.
            if !alwaysLive {
                WindowVisibilityReporter { visible, _ in
                    isVisible = visible
                    engine.setPopoverVisible(visible, token: ObjectIdentifier(token))
                }
            }
        }
    }

    private func popoverRow(_ label: String, _ value: String, fraction: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            UsageBar(fraction: fraction ?? 0, color: color.opacity(fraction == nil ? 0 : 1), height: 4)
            Text(value).frame(minWidth: 86, alignment: .trailing)
        }
    }

    private func openMain(section: AppSection?) {
        if let section { engine.section = section }
        NSApp.setActivationPolicy(.regular)
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
        AppWindows.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct PopoverAISection: View {
    var workload: AIWorkload
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        let live = engine.liveProcessMetrics(for: workload)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionLabel(text: "Local AI")
                Spacer()
                ActivityLabel(activity: workload.activity, lastActivity: workload.lastActivity)
            }
            Text(workload.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(workload.runner.displayName + (workload.state == .modelLoaded ? "" : " · " + workload.state.label))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                if let tps = workload.tokensPerSecond.value {
                    Text(Format.tokensPerSecond(tps)).foregroundStyle(workload.activity.isBusy ? .primary : .secondary)
                        .help(workload.tokensPerSecond.note ?? "")
                }
                if let memory = workload.primaryModel?.sizeBytes ?? live.memory {
                    Text(Format.bytes(memory))
                        .help(workload.primaryModel?.sizeBytes != nil ? "Model memory reported by the runner" : "Runner process memory")
                }
                if let cpu = live.cpu { Text("CPU \(Format.processCPU(cpu))%") }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }
}

private struct PopoverButton: View {
    var title: String
    var shortcut: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hovering ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(hovering ? Color.white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5))
        .onHover { hovering = $0 }
    }
}
