// Renders the DMG window background: the app's teal-to-indigo gradient, "Drag eyeOS into Applications", an arrow
// from the app icon to the Applications folder, and (for builds that aren't notarized) the one Terminal command
// people need first. Finder draws the icons and their labels on top, at the spots in scripts/dmg_settings.py.
// Usage: swift scripts/make_dmg_background.swift out.png scale [note]
import AppKit

let W: CGFloat = 660, H: CGFloat = 420           // window content size in points; keep in sync with dmg_settings.py
let appX: CGFloat = 170, appsX: CGFloat = 490, iconY: CGFloat = 215  // icon centres, from the top
let args = CommandLine.arguments
let out = args[1], scale = CGFloat(Double(args[2]) ?? 1), note = args.count > 3 ? args[3] : ""

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let top = { (y: CGFloat) in H - y }               // Finder measures from the top, AppKit from the bottom

// Mid-tone gradient: icon labels are black in light mode and white in dark mode, and both read on it.
NSGradient(colors: [NSColor(red: 0.20, green: 0.62, blue: 0.68, alpha: 1), NSColor(red: 0.33, green: 0.34, blue: 0.70, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)
// soft glow behind each icon
for x in [appX, appsX] {
    let c = NSPoint(x: x, y: top(iconY))
    NSGradient(colors: [NSColor(white: 1, alpha: 0.2), NSColor(white: 1, alpha: 0)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: 115, options: [])
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat, mono: Bool = false) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 3
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha),
                                            .paragraphStyle: para, .shadow: shadow]
    NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 20, y: top(y) - size * 1.4, width: W - 40, height: size * 1.6))
}

text("Drag eyeOS into Applications", size: 22, weight: .semibold, alpha: 1, y: 40)
text("Then open it from your Applications folder", size: 13, weight: .regular, alpha: 0.85, y: 76)

// arrow from the app to Applications
let y = top(iconY), x0 = appX + 80, x1 = appsX - 80
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: x0, y: y))
shaft.line(to: NSPoint(x: x1 - 6, y: y))
shaft.lineWidth = 5
shaft.lineCapStyle = .round
shaft.setLineDash([2, 12], count: 2, phase: 0)
NSColor(white: 1, alpha: 0.9).setStroke()
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: x1 + 8, y: y))
head.line(to: NSPoint(x: x1 - 12, y: y + 13))
head.line(to: NSPoint(x: x1 - 12, y: y - 13))
head.close()
NSColor(white: 1, alpha: 0.9).setFill()
head.fill()

if !note.isEmpty {  // a darker strip at the bottom with the one command an un-notarized build needs
    NSColor(white: 0, alpha: 0.28).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: 74)).fill()
    text("Blocked when you open it? Run this once in Terminal:", size: 12, weight: .medium, alpha: 0.9, y: H - 62)
    text(note, size: 12, weight: .regular, alpha: 1, y: H - 38, mono: true)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
