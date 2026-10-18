import Foundation
import Observation
import SiliconPulseCore

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var samplingInterval: SamplingInterval {
        didSet { defaults.set(samplingInterval.rawValue, forKey: Keys.interval) }
    }
    var menuBarItems: Set<MenuBarItem> {
        didSet { defaults.set(menuBarItems.map(\.rawValue).sorted(), forKey: Keys.menuBarItems) }
    }
    /// When a model is loaded, show "Qwen3 · GPU 91% · 38 tok/s" instead of the system summary.
    var menuBarPrefersAI: Bool {
        didSet { defaults.set(menuBarPrefersAI, forKey: Keys.menuBarPrefersAI) }
    }
    var probeDefaultPorts: Bool {
        didSet { defaults.set(probeDefaultPorts, forKey: Keys.probe) }
    }
    var customEndpoints: [String] {
        didSet { defaults.set(customEndpoints, forKey: Keys.endpoints) }
    }
    var chartWindow: HistoryWindow {
        didSet { defaults.set(chartWindow.rawValue, forKey: Keys.chartWindow) }
    }
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        samplingInterval = SamplingInterval(rawValue: defaults.object(forKey: Keys.interval) as? Double ?? 1) ?? .oneSecond
        if let stored = defaults.array(forKey: Keys.menuBarItems) as? [String] {
            menuBarItems = Set(stored.compactMap(MenuBarItem.init(rawValue:)))
        } else {
            menuBarItems = [.cpu, .gpu, .memory, .pressure]
        }
        menuBarPrefersAI = defaults.object(forKey: Keys.menuBarPrefersAI) as? Bool ?? true
        probeDefaultPorts = defaults.object(forKey: Keys.probe) as? Bool ?? true
        customEndpoints = defaults.stringArray(forKey: Keys.endpoints) ?? []
        chartWindow = HistoryWindow(rawValue: defaults.string(forKey: Keys.chartWindow) ?? "") ?? .oneMinute
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
    }

    /// Valid loopback URLs from the custom endpoint list; anything else is ignored.
    var customEndpointURLs: [URL] {
        customEndpoints.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
            guard let url = URL(string: withScheme), LoopbackPolicy.isAllowed(url) else { return nil }
            return url
        }
    }

    var menuBarShowsLiveValues: Bool { !menuBarItems.isEmpty }

    private enum Keys {
        static let interval = "samplingInterval"
        static let menuBarItems = "menuBarItems"
        static let menuBarPrefersAI = "menuBarPrefersAI"
        static let probe = "probeDefaultPorts"
        static let endpoints = "customEndpoints"
        static let chartWindow = "chartWindow"
        static let onboarding = "hasCompletedOnboarding"
    }
}
