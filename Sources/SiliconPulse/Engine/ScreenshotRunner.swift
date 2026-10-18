import AppKit
import SiliconPulseCore
import SwiftUI

/// Captures every screen in light and dark appearance at several window sizes, then quits.
/// Enabled with `--screenshots <directory>`; used by CI for screenshot-driven design review.
@MainActor
final class ScreenshotRunner {
    private let engine: MonitorEngine
    private let directory: URL

    static let screens: [AppSection] = [.overview, .ai, .processes, .memory, .compute, .diskNetwork, .history, .settings]

    init(engine: MonitorEngine, directory: URL) {
        self.engine = engine
        self.directory = directory
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { await run() }
    }

    private func run() async {
        // Let history and process deltas fill in, and give AI detection time to find the runners so
        // both appearances show the same state.
        await wait(14)
        for _ in 0..<30 where engine.latestAI.workloads.isEmpty { await wait(1) }
        if let window = AppWindows.mainWindow { Self.allowFramesBeyondScreen(window) }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            resize(width: 1180, height: 800)
            for section in Self.screens {
                engine.section = section
                await wait(2.2)
                WindowCapture.captureMain(to: directory.appendingPathComponent("\(section.rawValue)-\(suffix).png"))
            }
            engine.section = .overview
            for (width, height, label) in [(920.0, 620.0, "min"), (1600.0, 1000.0, "large")] {
                resize(width: width, height: height)
                await wait(1.5)
                WindowCapture.captureMain(to: directory.appendingPathComponent("overview-\(label)-\(suffix).png"))
            }
            resize(width: 1180, height: 800)
            WindowCapture.renderPopover(engine: engine, appearance: appearance,
                                        to: directory.appendingPathComponent("menubar-popover-\(suffix).png"))
        }
        NSApp.appearance = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApp.terminate(nil)
    }

    /// CI screens are small; titled windows are clamped to the screen, which would crop every capture.
    /// Screenshot mode only: let this window's class keep the frame it is given.
    private static func allowFramesBeyondScreen(_ window: NSWindow) {
        let selector = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(type(of: window), selector) else { return }
        let keep: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
        class_replaceMethod(type(of: window), selector, imp_implementationWithBlock(keep), method_getTypeEncoding(method))
    }

    private func resize(width: CGFloat, height: CGFloat) {
        guard let window = AppWindows.mainWindow else { return }
        // Set the frame directly so the window may extend below a small CI screen instead of being clamped.
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let top = window.screen?.visibleFrame.maxY ?? window.frame.maxY
        let frame = NSRect(x: window.frame.minX, y: top - height - chrome, width: width, height: height + chrome)
        window.setFrame(frame, display: true)
        print("screenshots: requested \(Int(width))x\(Int(height)), content \(window.contentLayoutRect.size), screen \(window.screen?.frame.size ?? .zero)")
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Captures the app's own windows (no screen-recording permission needed for own windows).
@MainActor
enum WindowCapture {
    static func captureMain(to url: URL) {
        guard let window = AppWindows.mainWindow, let content = window.contentView else { return }
        capture(view: content.superview ?? content, to: url)
    }

    static func capture(view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    /// Hosts the popover content in an offscreen window with the given appearance and captures it.
    static func renderPopover(engine: MonitorEngine, appearance: NSAppearance.Name, to url: URL) {
        let root = MenuBarPopover(alwaysLive: true)
            .environment(engine)
            .environment(engine.settings)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderFront(nil)
        host.frame = NSRect(origin: .zero, size: size)
        capture(view: host, to: url)
        window.orderOut(nil)
    }
}
