// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Reads what can be known about a Windows Installer package before running it.
///
/// An `.msi` is not a program: it is an OLE compound document holding a
/// database of files and registry keys. There is no PE header, no import table
/// and no icon to read, so every technique the rest of Proteus relies on comes
/// up empty — and treating it as an executable fails outright with "missing MZ
/// header".
///
/// What an MSI does carry is a SummaryInformation stream naming the product and
/// its target architecture. That is enough to name the app and pick the right
/// prefix; everything else is learned after the install, from the program the
/// MSI put on disk, which is the more reliable source anyway.
public struct MSIPackage: Sendable {

    public let url: URL
    /// "x64" or "Intel" from the package Template, mapped to something a person
    /// would recognise.
    public let architecture: String
    public let is64Bit: Bool
    /// Product name from the package Subject, when it says one.
    public let productName: String?

    public enum ParseError: Error, CustomStringConvertible {
        case notCompoundFile
        public var description: String { "not a Windows Installer package" }
    }

    /// The OLE compound-file magic. Every MSI starts with it.
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    public init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 8, Array(data.prefix(8)) == Self.signature else {
            throw ParseError.notCompoundFile
        }

        // The summary stream stores its strings as plain code-page text inside
        // the compound file. Walking the full CFB directory to reach it is a
        // lot of machinery for two short strings, so they are located by
        // signature instead — the Template value is a short, distinctive token.
        let head = data.prefix(2 * 1024 * 1024)
        let text = String(decoding: head, as: UTF8.self)

        if text.contains("x64;") || text.contains("Intel64;") || text.contains("AMD64") {
            self.architecture = "64-bit (x64)"
            self.is64Bit = true
        } else if text.contains("Intel;") {
            self.architecture = "32-bit (x86)"
            self.is64Bit = false
        } else {
            // Unmarked packages are overwhelmingly 32-bit; that is also the
            // safer assumption, since a 32-bit prefix runs both.
            self.architecture = "32-bit (x86)"
            self.is64Bit = false
        }

        self.productName = Self.findProductName(in: text)
    }

    /// MSI Subject fields read like "7-Zip (x64 edition) Package".
    ///
    /// The fields sit back-to-back in the stream with no separators, so
    /// searching the whole blob for " Package" and taking the text before it
    /// drags in the neighbouring field — the first attempt produced
    /// "xInstallation Database7-Zip". Splitting into printable runs first keeps
    /// each field whole.
    static func findProductName(in text: String) -> String? {
        var runs: [String] = []
        var current = ""
        for character in text.unicodeScalars {
            if character.value >= 0x20 && character.value < 0x7F {
                current.unicodeScalars.append(character)
            } else {
                if current.count >= 3 { runs.append(current) }
                current = ""
            }
        }
        if current.count >= 3 { runs.append(current) }

        for run in runs {
            for marker in [" Package", " Installer", " Setup"] {
                guard let range = run.range(of: marker) else { continue }
                var name = String(run[run.startIndex..<range.lowerBound])
                // Drop a parenthesised architecture note: "(x64 edition)".
                if let paren = name.range(of: " (") {
                    name = String(name[name.startIndex..<paren.lowerBound])
                }
                name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                // Reject anything that is clearly another field bleeding in.
                guard name.count > 2, name.count < 60,
                      !name.lowercased().contains("installation database"),
                      !name.lowercased().contains("this installer") else { continue }
                return name
            }
        }
        return nil
    }

    /// Windows Installer is driven through `msiexec`, which Wine implements.
    /// `/qn` is fully silent; `TARGETDIR` is honoured by well-built packages
    /// and ignored by the rest, which is why the installed game is searched for
    /// afterwards rather than assumed.
    public static func silentArguments(for msi: URL, targetWindowsPath: String) -> [String] {
        ["msiexec", "/i", msi.path, "/qn", "TARGETDIR=\(targetWindowsPath)"]
    }
}
