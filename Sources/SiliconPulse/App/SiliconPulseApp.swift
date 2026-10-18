import AppKit
import SiliconPulseCore
import SwiftUI

@main
struct SiliconPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var engine: MonitorEngine

    init() {
        let options = LaunchOptions.current
        let settings = AppSettings()
        if options.skipOnboarding { settings.hasCompletedOnboarding = true }
        let engine = MonitorEngine(settings: settings)
        _settings = State(initialValue: settings)
        _engine = State(initialValue: engine)
        AppDelegate.engine = engine
        if settings.hasCompletedOnboarding { engine.start() }
    }

    var body: some Scene {
        Window("SiliconPulse", id: WindowID.main) {
            RootView()
                .environment(engine)
                .environment(settings)
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { SiliconPulseCommands(engine: engine) }

        MenuBarExtra {
            MenuBarPopover()
                .environment(engine)
                .environment(settings)
        } label: {
            MenuBarLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(standalone: true)
                .environment(engine)
                .environment(settings)
                .frame(width: 620, height: 640)
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// The status item title: icon plus the live summary chosen in Settings.
struct MenuBarLabel: View {
    var engine: MonitorEngine

    var body: some View {
        if engine.menuBarTitle.isEmpty {
            Image(systemName: "waveform.path.ecg")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                Text(engine.menuBarTitle).monospacedDigit()
            }
        }
    }
}

struct SiliconPulseCommands: Commands {
    var engine: MonitorEngine

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(Array(AppSection.allCases.filter { $0 != .settings }.enumerated()), id: \.element) { index, section in
                Button(section.title) { engine.section = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Refresh AI Detection") { engine.refreshAINow() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

/// Keeps the app alive in the menu bar after the window closes and hides the Dock icon while no window is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var engine: MonitorEngine?
    private var profiler: ProfileRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let options = LaunchOptions.current
        if let directory = options.profileDirectory, let engine = AppDelegate.engine {
            profiler = ProfileRunner(engine: engine, directory: directory)
            profiler?.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppWindows.showMain() }
        return true
    }
}

/// Opening and closing the main window from places that have no SwiftUI environment.
@MainActor
enum AppWindows {
    static var openMainAction: (() -> Void)?

    /// Reported by the main window's own content, so no guessing from window identifiers is needed.
    static weak var registeredMainWindow: NSWindow?

    static var mainWindow: NSWindow? {
        if let window = registeredMainWindow { return window }
        return NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(WindowID.main) == true }
    }

    static func showMain() {
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func mainWindowClosed() {
        // Leave only the menu bar item: no Dock icon while no window is open.
        DispatchQueue.main.async {
            if !(mainWindow?.isVisible ?? false) { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

struct LaunchOptions {
    var skipOnboarding = false
    var profileDirectory: URL?

    static let current: LaunchOptions = {
        var options = LaunchOptions()
        let args = ProcessInfo.processInfo.arguments
        options.skipOnboarding = args.contains("--skip-onboarding")
        if let index = args.firstIndex(of: "--profile"), index + 1 < args.count {
            options.profileDirectory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            options.skipOnboarding = true
        }
        return options
    }()
}
