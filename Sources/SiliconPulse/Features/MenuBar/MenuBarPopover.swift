import SiliconPulseCore
import SwiftUI

/// Compact popover shown from the menu bar item: state, three numbers, the active model, actions.
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
        let health = MachineHealth.evaluate(s)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppMark(size: 16)
                Text("SiliconPulse").font(.system(size: 13, weight: .semibold))
                Spacer()
                if settings.hasCompletedOnboarding {
                    StatusPill(text: health.title, color: health.color, prominent: health.level != .healthy)
                }
            }
            .padding(.bottom, 14)

            if settings.hasCompletedOnboarding {
                HStack(alignment: .top, spacing: 0) {
                    column("CPU", value: Format.fixed(s.cpu.usage.total * 100, 0), unit: "%", fraction: s.cpu.usage.total, color: Theme.cpu)
                    column("GPU", value: s.gpu.deviceUtilization.map { Format.fixed($0 * 100, 0) } ?? "—",
                           unit: s.gpu.isAvailable ? "%" : nil, fraction: s.gpu.deviceUtilization ?? 0, color: Theme.gpu)
                    column("Memory", value: Format.fixed(Double(s.memory.used) / 1_073_741_824, 1),
                           unit: "/ \(Format.fixed(Double(s.memory.total) / 1_073_741_824, 0))G", fraction: s.memory.usedFraction, color: Theme.memory)
                }
                Text(statusLine(s))
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)

                if let workload = engine.ai.featured {
                    PopoverAISection(workload: workload)
                        .padding(.top, 16)
                }
            } else {
                Text("Open SiliconPulse to start monitoring.").font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 1) {
                PopoverButton(title: "Open SiliconPulse", symbol: "macwindow") { openMain(section: nil) }
                PopoverButton(title: "Settings…", symbol: "gearshape") { openMain(section: .settings) }
                PopoverButton(title: "Quit SiliconPulse", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, -6)
        }
        .padding(16)
        .frame(width: 312)
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

    private func column(_ label: String, value: String, unit: String?, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.overline).tracking(0.6).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                if let unit, value != "—" {
                    Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            UsageBar(fraction: fraction, color: color, height: 3)
                .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(_ s: SystemSnapshot) -> String {
        var parts = ["Pressure \(s.memory.pressure.label.lowercased())", "swap \(Format.bytes(s.memory.swapUsed))"]
        parts.append("thermal \(s.thermal.level.label.lowercased())")
        return parts.joined(separator: " · ")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Overline(text: "Active model", color: workload.activity.isBusy ? Theme.ai : .secondary)
                Spacer()
                ActivityLabel(activity: workload.activity, lastActivity: workload.lastActivity, state: workload.state)
            }
            HStack(spacing: 10) {
                RunnerGlyph(runner: workload.runner, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    // The model name gets the full row; numbers sit on the line below so it never truncates early.
                    Text(workload.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(workload.runner.displayName).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if let tps = workload.liveTokensPerSecond {
                            Text(Format.tokensPerSecond(tps)).fontWeight(.semibold).foregroundStyle(Theme.ai)
                        } else if let tps = workload.tokensPerSecond.value {
                            // A past rate or a runner's session average: secondary, and labeled on hover.
                            Text(Format.tokensPerSecond(tps)).foregroundStyle(.secondary)
                                .help(workload.tokensPerSecond.note ?? "")
                        }
                        if let memory = workload.primaryModel?.sizeBytes ?? live.memory {
                            Text(Format.bytes(memory)).foregroundStyle(.secondary)
                                .help(workload.primaryModel?.sizeBytes != nil ? "Model memory reported by the runner" : "Runner process memory")
                        }
                    }
                    .font(.meta.monospacedDigit())
                }
            }
            .padding(10)
            .background(Theme.ai.opacity(workload.activity.isBusy ? 0.09 : 0.05),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        }
    }
}

private struct PopoverButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(hovering ? Color.white : .secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(hovering ? Color.white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .onHover { hovering = $0 }
    }
}
