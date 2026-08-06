// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation
import CoreGraphics
import ImageIO

/// Looks at a frame the game drew and says whether it looks like a game.
///
/// "It opened a window" is not the same as "it works". GZDoom under Wine draws
/// its title screen perfectly — correct geometry, legible text — flooded in
/// magenta, because the Vulkan swapchain format is wrong. A human sees that
/// instantly. Nothing in a process list or an exit code does.
///
/// So the frame itself is the evidence. The checks here are deliberately blunt:
/// they are looking for whole-screen pathologies that mean "misconfigured",
/// not for artistic judgement.
public enum FrameHealth {

    /// A rectangle inside the frame, in fractions of its width and height.
    public struct DialogRegion: Sendable, Equatable {
        public let x: Double, y: Double, width: Double, height: Double

        /// Where the first button of a Windows dialog sits: bottom row, left
        /// side. In a two-button prompt that is the affirmative one — "Yes",
        /// "OK", "Yes, download the graphics" — which is what an installer
        /// running unattended wants to press.
        public var firstButtonPoint: (x: Double, y: Double) {
            (x + width * 0.25, y + height * 0.88)
        }
    }

    public enum Verdict: Sendable, Equatable {
        case healthy
        /// One colour channel is missing or two are pinned: the classic
        /// symptom of a swapchain format or colour-space mismatch.
        case colourCast(dominant: String)
        /// A single flat colour across the whole frame.
        case blank
        /// Rendering, but too dark to see — a failed gamma or HDR path.
        case tooDark
        /// A mostly empty frame with one small panel of content: the game is
        /// blocked on a question, not drawing itself. OpenTTD installed
        /// silently asks permission to download its graphics and will sit there
        /// forever until somebody answers.
        ///
        /// The region is in fractions of the frame, so a caller can aim a click
        /// at the buttons without knowing the window size.
        case waitingOnDialog(region: DialogRegion)
        case unreadable

        public var isHealthy: Bool { self == .healthy }

        public var summaryEN: String {
            switch self {
            case .healthy: return "the picture looks right"
            case .colourCast(let d): return "the picture has a \(d) colour cast"
            case .blank: return "the window is a single flat colour"
            case .tooDark: return "the picture is too dark to see"
            case .waitingOnDialog: return "the game is waiting on a question, not running"
            case .unreadable: return "the frame could not be read"
            }
        }

        public var summaryES: String {
            switch self {
            case .healthy: return "la imagen se ve bien"
            case .colourCast(let d): return "la imagen tiene un tinte \(d)"
            case .blank: return "la ventana es un color plano"
            case .tooDark: return "la imagen está demasiado oscura"
            case .waitingOnDialog: return "el juego espera una respuesta, no está corriendo"
            case .unreadable: return "no se pudo leer el fotograma"
            }
        }
    }

    /// Measurements kept alongside the verdict, so a report can show its work
    /// instead of asking to be believed.
    public struct Measurements: Sendable {
        public let meanRed: Double
        public let meanGreen: Double
        public let meanBlue: Double
        public let variation: Double        // mean per-pixel spread of luminance
        public let distinctHues: Int        // how many hue buckets are populated

        public var description: String {
            String(format: "R%.0f G%.0f B%.0f · variation %.1f · %d hues",
                   meanRed, meanGreen, meanBlue, variation, distinctHues)
        }
    }

    static let side = 64

    public static func analyse(_ file: URL) -> (Verdict, Measurements?) {
        guard let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = samplePixels(image) else {
            return (.unreadable, nil)
        }

        let count = Double(pixels.count / 4)
        guard count > 0 else { return (.unreadable, nil) }

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var luminance: [Double] = []
        luminance.reserveCapacity(pixels.count / 4)
        var hueBuckets = Set<Int>()

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            sumR += r; sumG += g; sumB += b
            luminance.append(0.2126 * r + 0.7152 * g + 0.0722 * b)

            // Only saturated pixels carry hue information worth counting; a
            // grey wall says nothing about whether colour is working.
            let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
            if maxC - minC > 30 {
                hueBuckets.insert(Int(hue(r: r, g: g, b: b) / 20))
            }
        }

        let meanR = sumR / count, meanG = sumG / count, meanB = sumB / count
        let meanLuma = luminance.reduce(0, +) / count
        let variation = (luminance.map { abs($0 - meanLuma) }.reduce(0, +)) / count
        let measurements = Measurements(meanRed: meanR, meanGreen: meanG, meanBlue: meanB,
                                        variation: variation, distinctHues: hueBuckets.count)

        // A modal prompt looks like nothing else: one flat background filling
        // most of the frame, and a single compact panel somewhere in it. Test
        // for it before the darkness checks, because the background is usually
        // black and would otherwise be dismissed as "too dark".
        if let region = detectDialog(pixels: pixels) {
            return (.waitingOnDialog(region: region), measurements)
        }

        // A flat frame has almost no luminance spread. Startup logos and
        // loading screens can be dark but are never *uniform*.
        if variation < 3 { return (.blank, measurements) }
        if meanLuma < 10 { return (.tooDark, measurements) }

        // A cast is one channel far below the others across the whole frame.
        // Real game art is rarely balanced, so the threshold is generous: this
        // is looking for "green is simply absent", not "this scene is warm".
        let channels = [("red", meanR), ("green", meanG), ("blue", meanB)]
        let brightest = channels.max { $0.1 < $1.1 }!
        let dimmest = channels.min { $0.1 < $1.1 }!
        if brightest.1 > 40, dimmest.1 < brightest.1 * 0.45 {
            // Name the cast by what is *present*, which is what the user sees.
            let present = channels.filter { $0.0 != dimmest.0 }.map(\.0).sorted()
            let name: String
            switch (present[0], present[1]) {
            case ("blue", "red"): name = "magenta"
            case ("green", "red"): name = "yellow"
            case ("blue", "green"): name = "cyan"
            default: name = "\(present[0])/\(present[1])"
            }
            return (.colourCast(dominant: name), measurements)
        }

        // A frame with only one or two hues present, yet plenty of saturation,
        // is another face of the same fault.
        if hueBuckets.count <= 2, variation > 8 {
            return (.colourCast(dominant: "single-hue"), measurements)
        }

        return (.healthy, measurements)
    }

    /// Finds a compact panel sitting on an otherwise uniform background.
    ///
    /// Deliberately strict: the background has to dominate, and the panel has
    /// to be both small and contiguous. A game's actual first frame — a menu, a
    /// loading screen, a logo — spreads its content across the frame and does
    /// not match.
    static func detectDialog(pixels: [UInt8]) -> DialogRegion? {
        let total = side * side
        var luma = [Int](repeating: 0, count: total)
        for i in 0..<total {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            luma[i] = (r * 2126 + g * 7152 + b * 722) / 10000
        }

        // The background is whatever luminance covers most of the frame.
        var histogram = [Int](repeating: 0, count: 32)
        for value in luma { histogram[min(31, value / 8)] += 1 }
        guard let backgroundBucket = histogram.indices.max(by: { histogram[$0] < histogram[$1] }) else {
            return nil
        }
        let backgroundShare = Double(histogram[backgroundBucket]) / Double(total)
        guard backgroundShare > 0.80 else { return nil }

        // Everything that is not background.
        var minX = side, minY = side, maxX = -1, maxY = -1
        var count = 0
        for i in 0..<total where min(31, luma[i] / 8) != backgroundBucket {
            let x = i % side, y = i / side
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            count += 1
        }
        guard count > 0, maxX >= minX, maxY >= minY else { return nil }

        let share = Double(count) / Double(total)
        guard share > 0.01, share < 0.20 else { return nil }

        // Contiguous: the differing cells should nearly fill their own bounding
        // box. Scattered sparkle across the frame is not a dialog.
        let boxArea = Double((maxX - minX + 1) * (maxY - minY + 1))
        guard boxArea > 0, Double(count) / boxArea > 0.55 else { return nil }

        // A dialog is wider than it is tall and does not touch the edges.
        let width = Double(maxX - minX + 1) / Double(side)
        let height = Double(maxY - minY + 1) / Double(side)
        guard width > height * 0.9, minX > 1, minY > 1, maxX < side - 2, maxY < side - 2 else {
            return nil
        }

        return DialogRegion(x: Double(minX) / Double(side), y: Double(minY) / Double(side),
                            width: width, height: height)
    }

    static func hue(r: Double, g: Double, b: Double) -> Double {
        let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        var h: Double
        if maxC == r { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
        else if maxC == g { h = 60 * (((b - r) / delta) + 2) }
        else { h = 60 * (((r - g) / delta) + 4) }
        if h < 0 { h += 360 }
        return h
    }

    /// Downsamples to a fixed grid of RGBA bytes. Small is fine: these are
    /// whole-frame properties, and 4096 samples settle them.
    static func samplePixels(_ image: CGImage) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let context = buffer.withUnsafeMutableBytes { raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: side, height: side,
                      bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}
