import AppKit
import SiliconPulseCore
import SiliconPulseSystem

/// Running GUI apps from NSWorkspace, refreshed only on launch/terminate notifications.
@MainActor
final class RunningAppsRegistry {
    private(set) var snapshot: [Int32: RunningAppInfo] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false

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
}

/// App and executable icons, cached by path. A plain singleton so views (including Table cells,
/// where SwiftUI environment objects are not reliably available) need no environment lookups.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private let icons = NSCache<NSString, NSImage>()

    private init() {
        icons.countLimit = 300
    }

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
        image.size = NSSize(width: 32, height: 32)
        icons.setObject(image, forKey: key)
        return image
    }
}
