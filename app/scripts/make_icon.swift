// Renders the app icon (the welcome screen's teal-to-indigo eye) as a 1024 px PNG.
// Usage: swift scripts/make_icon.swift out.png   (scripts/make_icon.sh turns it into Resources/AppIcon.icns)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: an 824 px rounded square centred on the 1024 canvas
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.19, green: 0.78, blue: 0.80, alpha: 1), NSColor(red: 0.33, green: 0.30, blue: 0.85, alpha: 1)])!
    .draw(in: shape, angle: -45)

let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let r = NSRect(x: (size - eye.size.width) / 2, y: (size - eye.size.height) / 2, width: eye.size.width, height: eye.size.height)
eye.draw(in: r)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
