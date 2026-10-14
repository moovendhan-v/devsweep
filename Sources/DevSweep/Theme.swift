import AppKit
import SwiftUI

/// User-selectable color theme. Navy is the default.
enum AppTheme: String, CaseIterable, Identifiable {
    case navy, ocean, emerald, purple, sunset, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .navy: "Navy"
        case .ocean: "Ocean"
        case .emerald: "Emerald"
        case .purple: "Purple Haze"
        case .sunset: "Sunset"
        case .graphite: "Graphite"
        }
    }

    /// Dark → light stops used for hero backgrounds, the app icon and primary buttons.
    var stops: [(Double, Double, Double)] {
        switch self {
        case .navy: [(0.03, 0.07, 0.16), (0.06, 0.15, 0.34), (0.12, 0.32, 0.66)]
        case .ocean: [(0.02, 0.13, 0.19), (0.04, 0.29, 0.40), (0.09, 0.58, 0.64)]
        case .emerald: [(0.02, 0.14, 0.11), (0.05, 0.31, 0.24), (0.12, 0.56, 0.41)]
        case .purple: [(0.20, 0.10, 0.36), (0.42, 0.12, 0.45), (0.62, 0.18, 0.42)]
        case .sunset: [(0.22, 0.06, 0.13), (0.52, 0.13, 0.22), (0.86, 0.38, 0.23)]
        case .graphite: [(0.07, 0.08, 0.09), (0.15, 0.16, 0.18), (0.27, 0.30, 0.34)]
        }
    }

    var colors: [Color] { stops.map { Color(red: $0.0, green: $0.1, blue: $0.2) } }
    var nsColors: [NSColor] { stops.map { NSColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } }

    /// Bright accent for buttons, rings and highlights.
    var accent: Color {
        switch self {
        case .navy: Color(red: 0.30, green: 0.56, blue: 1.0)
        case .ocean: Color(red: 0.18, green: 0.78, blue: 0.86)
        case .emerald: Color(red: 0.22, green: 0.80, blue: 0.56)
        case .purple: Color(red: 0.93, green: 0.40, blue: 0.70)
        case .sunset: Color(red: 1.0, green: 0.55, blue: 0.30)
        case .graphite: Color(red: 0.62, green: 0.70, blue: 0.82)
        }
    }

    /// Secondary accent used in two-color gradients.
    var accent2: Color {
        switch self {
        case .navy: Color(red: 0.20, green: 0.36, blue: 0.92)
        case .ocean: Color(red: 0.10, green: 0.50, blue: 0.85)
        case .emerald: Color(red: 0.10, green: 0.60, blue: 0.62)
        case .purple: Color(red: 0.62, green: 0.32, blue: 1.0)
        case .sunset: Color(red: 0.92, green: 0.30, blue: 0.40)
        case .graphite: Color(red: 0.40, green: 0.46, blue: 0.56)
        }
    }

    var hero: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var button: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)
    }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .navy
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.navy
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Draws the DevSweep logo for any theme. Shared by the app (Dock icon) and scripts/make_icon.
enum IconRenderer {
    static func image(theme: AppTheme, size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(bitmap(theme: theme, pixels: Int(size)))
        return image
    }

    static func bitmap(theme: AppTheme, pixels px: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(theme: theme, scale: CGFloat(px) / 1024)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func draw(theme: AppTheme, scale s: CGFloat) {
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)   // Apple icon grid
        let shape = NSBezierPath(roundedRect: body, xRadius: 186 * s, yRadius: 186 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 26 * s
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.set()
        theme.nsColors[0].setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: theme.nsColors)!.draw(in: body, angle: 60)
        // Soft light from the top-left.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: 360 * s, y: 760 * s), radius: 0,
                  toCenter: NSPoint(x: 360 * s, y: 760 * s), radius: 620 * s, options: [])
        NSGraphicsContext.restoreGraphicsState()

        let center = NSPoint(x: 512 * s, y: 512 * s)
        let radius = 232 * s

        // Track ring (faint) + sweep arc (the "gauge" that's been cleaned up).
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 64 * s
        NSColor.white.withAlphaComponent(0.14).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 78, endAngle: 388, clockwise: false)
        arc.lineWidth = 64 * s
        arc.lineCapStyle = .round
        NSColor.white.setStroke()
        arc.stroke()

        // Sparkle sitting in the arc's gap.
        drawSymbol("sparkle", size: 150 * s, weight: .bold,
                   center: NSPoint(x: center.x + radius * cos(.pi * 53 / 180) + 6 * s,
                                   y: center.y + radius * sin(.pi * 53 / 180) + 6 * s))
        // Code mark in the middle.
        drawSymbol("chevron.left.forwardslash.chevron.right", size: 150 * s, weight: .heavy, center: center)

        NSColor.white.withAlphaComponent(0.16).setStroke()
        let border = NSBezierPath(roundedRect: body.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 184 * s, yRadius: 184 * s)
        border.lineWidth = 4 * s
        border.stroke()
    }

    private static func drawSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight, center: NSPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return }
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: center.x - symbol.size.width / 2, y: center.y - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height))
    }
}
