// Renders Resources/AppIcon.icns: a macOS-style rounded square with the DevSweep mark.
// Usage: swift scripts/make_icon.swift   (or compiled by build_app.sh)
import AppKit

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    // Tint white.
    let tinted = NSImage(size: image.size)
    tinted.lockFocus()
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)   // Apple icon grid
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    // Drop shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background gradient: deep purple → magenta → pink
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.10, blue: 0.42, alpha: 1),
                        NSColor(red: 0.55, green: 0.16, blue: 0.62, alpha: 1),
                        NSColor(red: 0.98, green: 0.36, blue: 0.56, alpha: 1)])!
        .draw(in: body, angle: -55)
    // Soft glow
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: 160 * s, y: 430 * s, width: 700 * s, height: 560 * s)), relativeCenterPosition: .zero)
    // Bottom "floor" sweep
    let sweep = NSBezierPath()
    sweep.move(to: NSPoint(x: 100 * s, y: 300 * s))
    sweep.curve(to: NSPoint(x: 924 * s, y: 250 * s), controlPoint1: NSPoint(x: 380 * s, y: 380 * s),
                controlPoint2: NSPoint(x: 650 * s, y: 160 * s))
    sweep.line(to: NSPoint(x: 924 * s, y: 100 * s))
    sweep.line(to: NSPoint(x: 100 * s, y: 100 * s))
    sweep.close()
    NSColor.white.withAlphaComponent(0.12).setFill()
    sweep.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Mark: big sparkles + code brackets
    let sparkles = symbol("sparkles", size: 380 * s, weight: .semibold)
    sparkles.draw(in: NSRect(x: (1024 * s - sparkles.size.width) / 2 + 20 * s, y: 395 * s,
                             width: sparkles.size.width, height: sparkles.size.height))
    let code = symbol("chevron.left.forwardslash.chevron.right", size: 150 * s, weight: .bold)
    code.draw(in: NSRect(x: (1024 * s - code.size.width) / 2, y: 175 * s, width: code.size.width, height: code.size.height),
              from: .zero, operation: .sourceOver, fraction: 0.92)

    // Subtle inner border
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let border = NSBezierPath(roundedRect: body.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 183 * s, yRadius: 183 * s)
    border.lineWidth = 4 * s
    border.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try render(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
