import Foundation

public enum SamplingInterval: Double, CaseIterable, Identifiable, Sendable {
    case halfSecond = 0.5
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .halfSecond: return "0.5 s"
        case .oneSecond: return "1 s"
        case .twoSeconds: return "2 s"
        case .fiveSeconds: return "5 s"
        }
    }
}

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case overview, ai, processes, memory, compute, diskNetwork, history, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .ai: return "AI Models"
        case .processes: return "Processes"
        case .memory: return "Memory"
        case .compute: return "Compute"
        case .diskNetwork: return "Disk & Network"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .ai: return "sparkles"
        case .processes: return "list.bullet.rectangle"
        case .memory: return "memorychip"
        case .compute: return "cpu"
        case .diskNetwork: return "arrow.up.arrow.down"
        case .history: return "chart.xyaxis.line"
        case .settings: return "gearshape"
        }
    }

    /// Screens that render the process table or per-process figures.
    var needsProcesses: Bool { self == .processes || self == .overview || self == .ai || self == .memory || self == .compute || self == .diskNetwork }
}

/// What the UI currently needs. The engine derives its schedule from this.
public struct MonitoringDemand: Equatable, Sendable {
    public var dashboardVisible: Bool
    public var popoverVisible: Bool
    public var section: AppSection
    public var menuBarShowsLiveValues: Bool
    public var lowPowerMode: Bool

    public init(dashboardVisible: Bool = false, popoverVisible: Bool = false, section: AppSection = .overview,
                menuBarShowsLiveValues: Bool = true, lowPowerMode: Bool = false) {
        self.dashboardVisible = dashboardVisible
        self.popoverVisible = popoverVisible
        self.section = section
        self.menuBarShowsLiveValues = menuBarShowsLiveValues
        self.lowPowerMode = lowPowerMode
    }
}

/// Interval per collection tier, in seconds.
public struct SamplingSchedule: Equatable, Sendable {
    public var system: TimeInterval
    public var processes: TimeInterval
    public var aiDiscovery: TimeInterval
    public var slow: TimeInterval

    public init(system: TimeInterval, processes: TimeInterval, aiDiscovery: TimeInterval, slow: TimeInterval) {
        self.system = system
        self.processes = processes
        self.aiDiscovery = aiDiscovery
        self.slow = slow
    }

    public var fastest: TimeInterval { min(system, processes, aiDiscovery, slow) }
}

/// Adaptive cadence: fast when someone is looking, slow when SiliconPulse only feeds the menu bar.
public enum SamplingPolicy {
    public static func schedule(for demand: MonitoringDemand, base: SamplingInterval) -> SamplingSchedule {
        let b = base.rawValue
        let visible = demand.dashboardVisible || demand.popoverVisible
        var schedule: SamplingSchedule

        if demand.dashboardVisible {
            // The process table refreshes at most every 2 s: re-sorting ~500 NSTableView rows is by far the
            // most expensive thing SiliconPulse draws (Activity Monitor defaults to 5 s).
            let processes = demand.section.needsProcesses ? max(b, 2) : 5
            schedule = SamplingSchedule(system: b, processes: processes, aiDiscovery: demand.section == .ai ? 2 : 5, slow: 10)
        } else if demand.popoverVisible {
            schedule = SamplingSchedule(system: b, processes: max(b, 2), aiDiscovery: 5, slow: 10)
        } else {
            let system = demand.menuBarShowsLiveValues ? max(b, 2) : 5
            schedule = SamplingSchedule(system: system, processes: 5, aiDiscovery: 10, slow: 30)
        }
        // The AI tier needs fresh per-process values, so it never runs faster than the process tier.
        schedule.aiDiscovery = max(schedule.aiDiscovery, schedule.processes)
        if !visible { schedule.processes = max(schedule.processes, schedule.system) }

        if demand.lowPowerMode {
            schedule = SamplingSchedule(system: schedule.system * 2, processes: schedule.processes * 2,
                                        aiDiscovery: schedule.aiDiscovery * 2, slow: schedule.slow * 2)
        }
        return schedule
    }
}

public enum MenuBarItem: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, pressure, aiModel, tokensPerSecond

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .pressure: return "Memory pressure"
        case .aiModel: return "Active AI model"
        case .tokensPerSecond: return "Tokens/sec (when available)"
        }
    }
}

/// Builds the status-item title, e.g. "CPU 22% · GPU 91% · RAM 21.8G" or "Qwen3 · GPU 91% · 38 tok/s".
public enum MenuBarFormatter {
    public static func title(items: [MenuBarItem], snapshot: SystemSnapshot, featured: AIWorkload?, preferAI: Bool) -> String {
        var parts: [String] = []
        let showAI = preferAI && featured?.primaryModel != nil && featured?.state != .apiUnreachable
        let selected = Set(items)

        if showAI, let featured, let model = featured.primaryModel {
            parts.append(model.shortName)
            if selected.contains(.gpu), let gpu = snapshot.gpu.deviceUtilization { parts.append("GPU " + Format.percent(gpu)) }
            if let tps = featured.tokensPerSecond.value, featured.activity.isBusy {
                parts.append(Format.fixed(tps, 0) + " tok/s")
            } else if selected.contains(.memory) {
                parts.append("RAM " + Format.compactBytes(snapshot.memory.used))
            }
            return parts.joined(separator: " · ")
        }

        for item in MenuBarItem.allCases where selected.contains(item) {
            switch item {
            case .cpu: parts.append("CPU " + Format.percent(snapshot.cpu.usage.total))
            case .gpu: if let gpu = snapshot.gpu.deviceUtilization { parts.append("GPU " + Format.percent(gpu)) }
            case .memory: parts.append("RAM " + Format.compactBytes(snapshot.memory.used))
            case .pressure: if snapshot.memory.pressure != .normal { parts.append(snapshot.memory.pressure.label.uppercased()) }
            case .aiModel:
                if !preferAI, let name = featured?.primaryModel?.shortName, featured?.state == .modelLoaded { parts.append(name) }
            case .tokensPerSecond:
                if let tps = featured?.tokensPerSecond.value, featured?.activity.isBusy == true { parts.append(Format.fixed(tps, 0) + " tok/s") }
            }
        }
        return parts.joined(separator: " · ")
    }
}
