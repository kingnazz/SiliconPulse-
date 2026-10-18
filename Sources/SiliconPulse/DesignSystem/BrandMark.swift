import AppKit
import SwiftUI

/// The SiliconPulse mark: a silicon die with a pulse running through it.
/// One drawing routine serves the in-app mark and the menu bar template image, so they always match.
enum BrandMark {
    /// Draws the mark into `rect` (y-up), stroking with the current color.
    static func draw(in rect: CGRect, lineWidth: CGFloat) {
        let s = rect.width
        let inset = s * 0.19
        let die = rect.insetBy(dx: inset, dy: inset)
        let radius = s * 0.13

        let body = NSBezierPath(roundedRect: die, xRadius: radius, yRadius: radius)
        body.lineWidth = lineWidth
        body.stroke()

        // Pins: three on each side.
        let pin = NSBezierPath()
        pin.lineWidth = lineWidth
        pin.lineCapStyle = .round
        let pinLength = inset * 0.62
        for i in 1...3 {
            let t = die.minX + die.width * CGFloat(i) / 4
            let u = die.minY + die.height * CGFloat(i) / 4
            pin.move(to: CGPoint(x: t, y: die.maxY)); pin.line(to: CGPoint(x: t, y: die.maxY + pinLength))
            pin.move(to: CGPoint(x: t, y: die.minY)); pin.line(to: CGPoint(x: t, y: die.minY - pinLength))
            pin.move(to: CGPoint(x: die.minX, y: u)); pin.line(to: CGPoint(x: die.minX - pinLength, y: u))
            pin.move(to: CGPoint(x: die.maxX, y: u)); pin.line(to: CGPoint(x: die.maxX + pinLength, y: u))
        }
        pin.stroke()

        // Pulse across the die.
        let pulse = NSBezierPath()
        pulse.lineWidth = lineWidth
        pulse.lineJoinStyle = .round
        pulse.lineCapStyle = .round
        let midY = die.midY
        let w = die.width
        let x0 = die.minX + w * 0.12
        pulse.move(to: CGPoint(x: x0, y: midY))
        pulse.line(to: CGPoint(x: die.minX + w * 0.34, y: midY))
        pulse.line(to: CGPoint(x: die.minX + w * 0.45, y: midY + die.height * 0.26))
        pulse.line(to: CGPoint(x: die.minX + w * 0.57, y: midY - die.height * 0.28))
        pulse.line(to: CGPoint(x: die.minX + w * 0.67, y: midY))
        pulse.line(to: CGPoint(x: die.maxX - w * 0.12, y: midY))
        pulse.stroke()
    }

    /// Template image for the status item; macOS tints it for light/dark menu bars.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            draw(in: rect, lineWidth: 1.35)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SiliconPulse"
        return image
    }()

    /// Colored image for in-app use.
    static func image(size: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setStroke()
            draw(in: rect, lineWidth: max(1.2, size / 13))
            return true
        }
    }
}

/// In-app brand mark (accent tinted).
struct AppMark: View {
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme

    /// One image per size and appearance: the popover re-renders every second while open, and a new
    /// NSImage each time would make SwiftUI redraw the mark every time.
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Image(nsImage: Self.image(size: size, dark: colorScheme == .dark))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @MainActor private static func image(size: CGFloat, dark: Bool) -> NSImage {
        let key = "\(size)|\(dark)"
        if let cached = cache[key] { return cached }
        // Resolve the accent for this appearance now; the drawing handler may run later under another one.
        var color = NSColor(Theme.cpu)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor(Theme.cpu).usingColorSpace(.sRGB) ?? color
        }
        let image = BrandMark.image(size: size, color: color)
        cache[key] = image
        return image
    }
}
