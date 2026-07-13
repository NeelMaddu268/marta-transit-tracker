// Generate the 1024px app icon: indigo->blue gradient, white tram glyph.
// Run:  swift tools/gen_app_icon.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

// Background gradient (indigo -> blue, diagonal).
let top = NSColor(calibratedRed: 0.32, green: 0.22, blue: 0.83, alpha: 1)
let bottom = NSColor(calibratedRed: 0.08, green: 0.47, blue: 0.95, alpha: 1)
NSGradient(colors: [top, bottom])!.draw(in: NSRect(origin: .zero, size: size), angle: -60)

// Subtle "route line" motif behind the glyph.
let path = NSBezierPath()
path.move(to: NSPoint(x: 120, y: 250))
path.curve(to: NSPoint(x: 904, y: 790),
           controlPoint1: NSPoint(x: 420, y: 240),
           controlPoint2: NSPoint(x: 610, y: 830))
path.lineWidth = 34
NSColor.white.withAlphaComponent(0.22).setStroke()
path.stroke()
for (x, y) in [(120.0, 250.0), (904.0, 790.0)] {
    let dot = NSBezierPath(ovalIn: NSRect(x: x - 30, y: y - 30, width: 60, height: 60))
    NSColor.white.withAlphaComponent(0.35).setFill()
    dot.fill()
}

// White tram glyph, centered.
let config = NSImage.SymbolConfiguration(pointSize: 540, weight: .semibold)
let symbol = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let symbolSize = symbol.size
let tinted = NSImage(size: symbolSize)
tinted.lockFocus()
symbol.draw(in: NSRect(origin: .zero, size: symbolSize))
NSColor.white.set()
NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
tinted.unlockFocus()

let scale = 560.0 / max(symbolSize.width, symbolSize.height)
let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
let origin = NSPoint(x: (size.width - drawSize.width) / 2,
                     y: (size.height - drawSize.height) / 2 - 20)
tinted.draw(in: NSRect(origin: origin, size: drawSize))

image.unlockFocus()

// Write PNG.
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
