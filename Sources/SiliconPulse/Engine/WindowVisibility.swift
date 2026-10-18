import AppKit
import SwiftUI

/// Reports whether the hosting NSWindow is actually visible on screen (not closed, minimised or fully covered).
/// Used to drive adaptive sampling, so the engine slows down when nobody is looking.
struct WindowVisibilityReporter: NSViewRepresentable {
    var onChange: (_ visible: Bool, _ window: NSWindow?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopObserving()
        nsView.onChange?(false, nil)
    }

    final class TrackingView: NSView {
        var onChange: ((Bool, NSWindow?) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                report(false)
                return
            }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        if note.name == NSWindow.willCloseNotification {
                            self?.report(false)
                        } else {
                            self?.evaluate()
                        }
                    }
                })
            }
            evaluate()
        }

        func evaluate() {
            guard let window else { return report(false) }
            report(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible, window)
        }

        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
