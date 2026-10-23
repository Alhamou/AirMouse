// Renders the AirMouse app icon (1024×1024 PNG): a trackpad with a pointer on a blue squircle.
// Usage: swift scripts/make-icon.swift out.png   (build.sh turns it into AppIcon.icns)
//        swift scripts/make-icon.swift --ios out.png   full-bleed square for the iPhone Home Screen
//                                                      (iOS rounds the corners itself)
import AppKit

let fullBleed = CommandLine.arguments.contains("--ios")
let output = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "AppIcon.png"
let size = 1024.0

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    // Squircle background (macOS icon grid: 824 pt body, centered) with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = fullBleed ? NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size))
                             : NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    if !fullBleed {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.black.setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.58, blue: 1.00, alpha: 1),
               ending: NSColor(srgbRed: 0.13, green: 0.25, blue: 0.75, alpha: 1))!
        .draw(in: squircle, angle: 90)

    // Trackpad: frosted glass rounded rectangle.
    let pad = NSBezierPath(roundedRect: NSRect(x: 232, y: 300, width: 560, height: 400), xRadius: 64, yRadius: 64)
    NSColor.white.withAlphaComponent(0.20).setFill()
    pad.fill()
    NSColor.white.withAlphaComponent(0.55).setStroke()
    pad.lineWidth = 14
    pad.stroke()

    // Pointer arrow, overlapping the trackpad's lower right.
    let arrow = NSBezierPath()
    let points: [(Double, Double)] = [(0, 0), (0, 0.74), (0.19, 0.58), (0.32, 0.86), (0.44, 0.80), (0.31, 0.53), (0.56, 0.53)]
    let origin = NSPoint(x: 560, y: 470), scale = 330.0
    for (i, p) in points.enumerated() {
        let pt = NSPoint(x: origin.x + p.0 * scale, y: origin.y + p.1 * scale)
        i == 0 ? arrow.move(to: pt) : arrow.line(to: pt)
    }
    arrow.close()
    arrow.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let arrowShadow = NSShadow()
    arrowShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    arrowShadow.shadowBlurRadius = 16
    arrowShadow.shadowOffset = NSSize(width: 0, height: -6)
    arrowShadow.set()
    NSColor.white.setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.10, green: 0.18, blue: 0.50, alpha: 1).setStroke()
    arrow.lineWidth = 16
    arrow.stroke()
    NSColor.white.setFill()
    arrow.fill()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
