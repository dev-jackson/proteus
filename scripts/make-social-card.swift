#!/usr/bin/env swift
// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import AppKit

// The card that appears when someone pastes the repository link into Reddit,
// Hacker News, Discord or a group chat.
//
// Without one, GitHub renders a grey box with an avatar and a filename, and a
// link in a busy thread is scrolled past. This is the only part of the project
// most people will ever see, and it gets about one second to say what the
// thing is — so it says the two facts that matter and nothing else.
//
// 1280×640 is what every one of those sites expects. Anything else is cropped,
// usually through the middle of the text.

let width: CGFloat = 1280
let height: CGFloat = 640
let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

let full = NSRect(x: 0, y: 0, width: width, height: height)

// The same deep, cool ground as the app icon, so the card and the icon in the
// Applications folder are recognisably one product.
NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.11, alpha: 1),
])!.draw(in: full, angle: -75)

// MARK: - The mark

// Proteus mid-change: circle to square, the earlier states trailing behind.
// Smaller than on the icon and pushed to one side — here it is a signature,
// not the subject.
func morph(centre: NSPoint, size: CGFloat, settled: CGFloat) -> NSBezierPath {
    let half = size / 2
    let rect = NSRect(x: centre.x - half, y: centre.y - half, width: size, height: size)
    let radius = half * (1 - settled) + size * 0.12 * settled
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

let markSize: CGFloat = 96
let markY = height - 132
let step: CGFloat = 30

for (index, settled) in [CGFloat(0.0), 0.45].enumerated() {
    let offset = CGFloat(2 - index) * step
    NSColor(calibratedRed: 0.42, green: 1.00, blue: 0.82,
            alpha: 0.16 + CGFloat(index) * 0.20).setFill()
    morph(centre: NSPoint(x: 96 - offset + step * 2, y: markY),
          size: markSize, settled: settled).fill()
}

let solid = morph(centre: NSPoint(x: 96 + step * 2.55, y: markY), size: markSize, settled: 1.0)
NSGraphicsContext.saveGraphicsState()
solid.addClip()
// Across the mark's own bounds, not the whole card. Spread over 1280 points
// the mint-to-blue transition falls entirely outside a 96-point shape, and the
// mark comes out flat — the same mistake as stretching a gradient across a
// page and wondering why a button looks like one colour.
NSGradient(colors: [
    NSColor(calibratedRed: 0.46, green: 1.00, blue: 0.84, alpha: 1),
    NSColor(calibratedRed: 0.33, green: 0.60, blue: 1.00, alpha: 1),
])!.draw(in: solid.bounds.insetBy(dx: -8, dy: -8), angle: -45)
NSGraphicsContext.restoreGraphicsState()

// MARK: - Words

func draw(_ text: String, at point: NSPoint, size: CGFloat,
          weight: NSFont.Weight, colour: NSColor, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: colour,
        .kern: tracking,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
}

let left: CGFloat = 96

draw("PROTEUS", at: NSPoint(x: left + 132, y: markY - 26), size: 34,
     weight: .heavy, colour: NSColor(white: 1, alpha: 0.92), tracking: 6)

// The headline is the product in one line. Not a tagline, not a metaphor —
// somebody skimming a thread has to know within a second whether this is for
// them.
draw("Windows games on your Mac.", at: NSPoint(x: left, y: 300), size: 62,
     weight: .bold, colour: .white)
draw("Drop the file, get an app.", at: NSPoint(x: left, y: 226), size: 62,
     weight: .bold, colour: NSColor(calibratedRed: 0.46, green: 1.00, blue: 0.84, alpha: 1))

// The differentiator, stated as a fact rather than a boast. Every other tool
// in this space asks the person to choose the renderer and the runtimes.
draw("It reads what the game needs — imports, manifest, engine — and",
     at: NSPoint(x: left, y: 150), size: 27, weight: .regular,
     colour: NSColor(white: 1, alpha: 0.62))
draw("configures itself. No bottles, no winetricks verbs, no guessing.",
     at: NSPoint(x: left, y: 112), size: 27, weight: .regular,
     colour: NSColor(white: 1, alpha: 0.62))

draw("Free software · GPL v3 · signed and notarised for macOS 14+",
     at: NSPoint(x: left, y: 48), size: 21, weight: .medium,
     colour: NSColor(white: 1, alpha: 0.34))

image.unlockFocus()

// MARK: - Write

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1]
                 : "docs/images/social-card.png")

guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: Int(width), pixelsHigh: Int(height),
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("could not make a bitmap")
}
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: full)
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not encode the png")
}
try data.write(to: output)
print("wrote \(output.path)")
