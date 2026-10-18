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

/// App and executable icons, cached by path and drawn once into a small bitmap. NSWorkspace icons are
/// multi-resolution IconServices images that would otherwise be re-rendered from their source artwork
/// every time a row redraws. A plain singleton so views (including Table cells, where SwiftUI
/// environment objects are not reliably available) need no environment lookups.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private let icons = NSCache<NSString, NSImage>()

    private init() {
        icons.countLimit = 400
    }

    /// - Parameter points: displayed size; icons are rasterized at 2× for 20 pt and below, else at 48 pt.
    func icon(for sample: ProcessSample, points: CGFloat = 16) -> NSImage? {
        guard let path = sample.executablePath else { return nil }
        let side: CGFloat = points <= 20 ? 20 : 48
        let key = "\(Int(side))|\(path)" as NSString
        if let cached = icons.object(forKey: key) { return cached }
        let source: NSImage
        if sample.isApp, let app = NSRunningApplication(processIdentifier: sample.pid), let appIcon = app.icon {
            source = appIcon
        } else if let range = path.range(of: ".app/Contents/MacOS/") {
            source = NSWorkspace.shared.icon(forFile: String(path[..<range.lowerBound]) + ".app")
        } else {
            source = NSWorkspace.shared.icon(forFile: path)
        }
        let image = Self.rasterize(source, side: side)
        icons.setObject(image, forKey: key)
        return image
    }

    private static func rasterize(_ source: NSImage, side: CGFloat) -> NSImage {
        let pixels = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return source }
        // The context draws in pixels; the rep's point size is set afterwards for 2× display.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: side, height: side)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
