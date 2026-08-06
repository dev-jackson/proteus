import Foundation
import AppKit

/// Pulls the real icon out of a Windows executable and turns it into a macOS
/// .icns. This is the difference between "a folder of files" and "an app that
/// looks like it belongs in the Dock".
public enum IconExtractor {

    public enum IconError: Error, CustomStringConvertible {
        case noIcon
        case conversionFailed(String)
        public var description: String {
            switch self {
            case .noIcon: return "the program carries no icon"
            case .conversionFailed(let s): return "icon conversion failed: \(s)"
            }
        }
    }

    /// Rebuilds a Windows .ico from the PE resource tree.
    ///
    /// RT_GROUP_ICON holds a directory of icon *IDs*; the pixel data lives in
    /// separate RT_ICON entries. Reassembling the .ico means rewriting the
    /// directory so each entry points at a byte offset instead of an ID.
    public static func extractICO(from exe: URL) throws -> Data {
        let pe = try PEFile(url: exe)
        guard pe.resourceDirRVA != 0,
              let root = pe.fileOffset(forRVA: pe.resourceDirRVA)
        else { throw IconError.noIcon }

        let data = pe.data

        /// Collect every leaf under a given resource type, keyed by resource ID.
        func leaves(ofType type: UInt32) -> [UInt32: (offset: Int, size: Int)] {
            var out: [UInt32: (Int, Int)] = [:]
            for typeEntry in PEFile.resourceEntries(data: data, at: root)
            where typeEntry.id == type && typeEntry.isDirectory {
                for nameEntry in PEFile.resourceEntries(data: data, at: root + Int(typeEntry.offset))
                where nameEntry.isDirectory {
                    for langEntry in PEFile.resourceEntries(data: data, at: root + Int(nameEntry.offset))
                    where !langEntry.isDirectory {
                        let de = root + Int(langEntry.offset)
                        guard de + 8 <= data.count else { continue }
                        guard let off = pe.fileOffset(forRVA: data.u32(de)) else { continue }
                        let size = Int(data.u32(de + 4))
                        guard size > 0, off + size <= data.count else { continue }
                        // First language wins; icons rarely differ by locale.
                        if out[nameEntry.id] == nil { out[nameEntry.id] = (off, size) }
                    }
                }
            }
            return out
        }

        let groups = leaves(ofType: 14)   // RT_GROUP_ICON
        let icons = leaves(ofType: 3)     // RT_ICON
        guard !groups.isEmpty, !icons.isEmpty else { throw IconError.noIcon }

        // Applications put their main icon in the lowest-numbered group.
        guard let groupID = groups.keys.min(), let group = groups[groupID] else { throw IconError.noIcon }
        let grp = data.subdata(in: group.offset..<(group.offset + group.size))
        guard grp.count >= 6 else { throw IconError.noIcon }
        let count = Int(grp.u16(4))
        guard count > 0, grp.count >= 6 + count * 14 else { throw IconError.noIcon }

        // Build the .ico: 6-byte header, count * 16-byte entries, then images.
        var directory = Data()
        var images = Data()
        var kept = 0
        var entries = Data()
        var offset = 6 + count * 16

        for i in 0..<count {
            let e = 6 + i * 14
            let width = grp[grp.startIndex + e]
            let height = grp[grp.startIndex + e + 1]
            let colorCount = grp[grp.startIndex + e + 2]
            let planes = grp.u16(e + 4)
            let bitCount = grp.u16(e + 6)
            let iconID = grp.u16(e + 12)

            guard let image = icons[UInt32(iconID)] else { continue }
            let payload = data.subdata(in: image.offset..<(image.offset + image.size))

            var entry = Data()
            entry.append(width)
            entry.append(height)
            entry.append(colorCount)
            entry.append(0)                       // reserved
            entry.appendLE16(planes)
            entry.appendLE16(bitCount)
            entry.appendLE32(UInt32(payload.count))
            entry.appendLE32(UInt32(offset))
            entries.append(entry)
            images.append(payload)
            offset += payload.count
            kept += 1
        }
        guard kept > 0 else { throw IconError.noIcon }

        // Rewrite the header now that we know how many entries survived, and
        // shift offsets to match the smaller directory.
        let shift = (count - kept) * 16
        var fixedEntries = Data()
        var cursor = 0
        for _ in 0..<kept {
            var entry = entries.subdata(in: cursor..<(cursor + 16))
            let old = entry.u32(12)
            entry.replaceSubrange(12..<16, with: withUnsafeBytes(of: (old - UInt32(shift)).littleEndian) { Data($0) })
            fixedEntries.append(entry)
            cursor += 16
        }

        directory.appendLE16(0)              // reserved
        directory.appendLE16(1)              // type: icon
        directory.appendLE16(UInt16(kept))
        directory.append(fixedEntries)
        directory.append(images)
        return directory
    }

    /// Full path: exe → .icns written to `destination`.
    /// Falls back to a generated icon so a wrapper is never left iconless.
    @discardableResult
    public static func makeICNS(from exe: URL, named displayName: String, to destination: URL) throws -> URL {
        let images: [NSImage]
        if let ico = try? extractICO(from: exe), let rep = NSImage(data: ico) {
            images = [rep]
        } else {
            images = [PlaceholderIcon.make(for: displayName)]
        }
        guard let source = images.first else { throw IconError.noIcon }
        try writeICNS(from: source, to: destination)
        return destination
    }

    /// Writes the lettered placeholder on its own, for an app that exists but
    /// has no game inside it yet.
    public static func writePlaceholderICNS(named displayName: String, to destination: URL) throws {
        try writeICNS(from: PlaceholderIcon.make(for: displayName), to: destination)
    }

    static func writeICNS(from image: NSImage, to destination: URL) throws {
        let fm = FileManager.default
        let iconset = fm.temporaryDirectory
            .appendingPathComponent("proteus-\(UUID().uuidString.prefix(8)).iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }

        // macOS expects this exact set of names; iconutil rejects anything else.
        let sizes: [(px: Int, name: String)] = [
            (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
        ]

        for (px, name) in sizes {
            guard let png = render(image, size: px) else { continue }
            try png.write(to: iconset.appendingPathComponent(name))
        }

        let result = Shell.run("/usr/bin/iconutil",
                               ["-c", "icns", iconset.path, "-o", destination.path])
        guard result.exitCode == 0, fm.fileExists(atPath: destination.path) else {
            throw IconError.conversionFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Draws the source at `size`, letterboxed, using nearest-neighbour for
    /// upscales so pixel-art game icons stay crisp instead of turning to mush.
    static func render(_ image: NSImage, size: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: size, pixelsHigh: size,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = ctx

        let native = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? size
        ctx.imageInterpolation = size > native ? .none : .high

        // Preserve aspect ratio; Windows icons are square but extracted reps
        // occasionally are not.
        let source = image.size
        let scale = min(CGFloat(size) / max(source.width, 1), CGFloat(size) / max(source.height, 1))
        let drawn = NSSize(width: source.width * scale, height: source.height * scale)
        let origin = NSPoint(x: (CGFloat(size) - drawn.width) / 2,
                             y: (CGFloat(size) - drawn.height) / 2)
        image.draw(in: NSRect(origin: origin, size: drawn),
                   from: .zero, operation: .sourceOver, fraction: 1.0)

        return bitmap.representation(using: .png, properties: [:])
    }
}

/// When a game ships no icon we still need something recognisable, so draw a
/// lettered tile rather than inheriting the generic Wine glass.
enum PlaceholderIcon {
    static func make(for name: String) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 24, dy: 24), xRadius: 96, yRadius: 96)
        // Deterministic hue per name so two games never look identical.
        let hue = CGFloat(abs(name.hashValue % 360)) / 360.0
        NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.72, alpha: 1).setFill()
        path.fill()

        let initials = String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 220, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: initials.isEmpty ? "?" : initials, attributes: attrs)
        let textSize = text.size()
        text.draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                              y: (size.height - textSize.height) / 2))

        image.unlockFocus()
        return image
    }
}

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
    mutating func appendLE32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}
