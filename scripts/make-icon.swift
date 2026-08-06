#!/usr/bin/env swift
import AppKit

// One shape, two natures.
//
// Proteus changed form at will — the sea god who became a lion, a serpent,
// water, fire, whatever the moment asked of him. "Protean" comes from him and
// means exactly that: able to take any shape.
//
// So the mark is a single silhouette that is a circle down one edge and a hard
// square down the other, with the transformation happening across its middle.
// Not two shapes side by side — one shape being both. That is the product: a
// Windows game and a Mac app are the same thing wearing different forms.
//
// Drawn in code so the repository carries no binary blob, and so the geometry
// can be reasoned about rather than nudged in a vector editor.

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset = size * 0.07
let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
NSBezierPath(roundedRect: plate, xRadius: size * 0.23, yRadius: size * 0.23).addClip()

// Deep, cool ground so the mark carries the colour.
NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.11, alpha: 1),
])!.draw(in: plate, angle: -90)

// Proteus caught mid-change: the same shape three times, each further along
// from fluid to solid, the earlier states trailing behind like an after-image.
// A single static silhouette read as a letter; a sequence reads as movement,
// which is what shape-shifting actually looks like.
let markSize = size * 0.42
let centreY = size / 2

/// One instance of the shape. `settled` runs 0…1, from a full circle to a
/// square with only a hint of a corner radius.
func morph(at centreX: CGFloat, settled: CGFloat) -> NSBezierPath {
    let half = markSize / 2
    let rect = NSRect(x: centreX - half, y: centreY - half, width: markSize, height: markSize)
    let radius = half * (1 - settled) + markSize * 0.12 * settled
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

// The trail: earlier, rounder, dimmer, set back and slightly smaller.
let step = size * 0.105
for (index, settled) in [CGFloat(0.0), 0.45].enumerated() {
    let offset = CGFloat(2 - index) * step
    let ghost = morph(at: size / 2 - offset, settled: settled)
    NSColor(calibratedRed: 0.42, green: 1.00, blue: 0.82,
            alpha: 0.18 + CGFloat(index) * 0.22).setFill()
    ghost.fill()
}

// The settled form, front and solid.
let solid = morph(at: size / 2 + step * 0.55, settled: 1.0)
NSGraphicsContext.saveGraphicsState()
solid.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.46, green: 1.00, blue: 0.84, alpha: 1),
    NSColor(calibratedRed: 0.33, green: 0.60, blue: 1.00, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -45)
NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (px, name) in sizes {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    bitmap.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    if let data = bitmap.representation(using: .png, properties: [:]) {
        try? data.write(to: iconset.appendingPathComponent(name))
    }
}
print("wrote \(iconset.path)")
