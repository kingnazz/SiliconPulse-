import AppKit
import SiliconPulseCore
import SiliconPulseSystem

/// Running GUI apps from NSWorkspace, refreshed only on launch/terminate notifications.
@MainActor
final class RunningAppsRegistry {
    private(set) var snapshot: [Int32: RunningAppInfo] = [:]
    private var observers: [NSObjectProtocol] = []
    private let icons = NSCache<NSString, NSImage>()
    private var started = false

    init() {
        icons.countLimit = 300
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func refresh() {
        var map: [Int32: RunningAppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            map[pid] = RunningAppInfo(name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                                      bundleIdentifier: app.bundleIdentifier,
                                      isRegularApp: app.activationPolicy == .regular)
        }
        snapshot = map
    }

    /// App icon for apps, executable icon otherwise. Cached by path.
    func icon(for sample: ProcessSample) -> NSImage? {
        guard let path = sample.executablePath else { return nil }
        let key = path as NSString
        if let cached = icons.object(forKey: key) { return cached }
        let image: NSImage
        if sample.isApp, let app = NSRunningApplication(processIdentifier: sample.pid), let appIcon = app.icon {
            image = appIcon
        } else if let range = path.range(of: ".app/Contents/MacOS/") {
            image = NSWorkspace.shared.icon(forFile: String(path[..<range.lowerBound]) + ".app")
        } else {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        image.size = NSSize(width: 16, height: 16)
        icons.setObject(image, forKey: key)
        return image
    }
}
