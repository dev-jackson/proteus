// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Identifies which installer framework produced an .exe, and therefore which
/// silent-install flag actually works. Guessing "/S" for an Inno Setup binary
/// pops a dialog and hangs the automation, so the detection has to be real.
public enum InstallerDetector {

    public enum Framework: String, Sendable {
        case nsis = "NSIS"
        case innoSetup = "Inno Setup"
        case installShield = "InstallShield"
        case msi = "Windows Installer (MSI)"
        case wise = "Wise"
        case sfx = "Self-extracting archive"
        case unknown = "Unknown installer"

        /// Flags that install without user interaction, in preference order.
        public var silentFlags: [[String]] {
            switch self {
            case .nsis:
                return [["/S"]]
            case .innoSetup:
                return [["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-"]]
            case .installShield:
                return [["/s", "/v/qn"], ["-s"]]
            case .msi:
                return [["/qn"]]
            case .wise:
                return [["/s"]]
            case .sfx:
                return [["-y"], ["/S"]]
            case .unknown:
                return []
            }
        }

        /// Where the installer puts things when told to be silent, relative to
        /// drive_c. Used to find the game afterwards.
        public var honoursDirFlag: ((String) -> [String])? {
            switch self {
            // Both take the path as one argv element with no quoting. Adding
            // quotes passes them through as literal characters and the
            // installer either ignores the flag or aborts.
            case .nsis: return { ["/D=\($0)"] }          // must be last
            case .innoSetup: return { ["/DIR=\($0)"] }
            default: return nil
            }
        }
    }

    /// Signatures searched for in the file. Order matters: Inno binaries also
    /// contain generic strings, so the most specific marker wins.
    static let signatures: [(marker: String, framework: Framework)] = [
        ("Inno Setup Setup Data", .innoSetup),
        ("JR.Inno.Setup", .innoSetup),
        ("InnoSetupLdrWindow", .innoSetup),
        ("Nullsoft Install System", .nsis),
        ("NullsoftInst", .nsis),
        ("InstallShield", .installShield),
        ("WiseMain", .wise),
        ("7-Zip", .sfx),
        ("WinRAR SFX", .sfx),
    ]

    public static func framework(of url: URL) -> Framework {
        if url.pathExtension.lowercased() == "msi" { return .msi }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }

        // Markers live near the header or in the overlay at the end. Inno Setup
        // puts "Inno Setup Setup Data" after its loader stub, which in a large
        // installer lands well past the first half-megabyte — a 371 MB game
        // installer was misread as "unknown" with a smaller window.
        var haystack = Data()
        if let head = try? handle.read(upToCount: 4 * 1024 * 1024) { haystack.append(head) }
        if let size = try? handle.seekToEnd(), size > 5 * 1024 * 1024 {
            try? handle.seek(toOffset: size - 512 * 1024)
            if let tail = try? handle.readToEnd() { haystack.append(tail) }
        }
        guard !haystack.isEmpty else { return .unknown }

        for (marker, framework) in signatures {
            if haystack.range(of: Data(marker.utf8)) != nil { return framework }
        }

        // Fall back to what the binary says about itself.
        if let pe = try? PEFile(url: url) {
            let blob = (pe.versionStrings.values.joined(separator: " ")).lowercased()
            if blob.contains("inno setup") { return .innoSetup }
            if blob.contains("nullsoft") { return .nsis }
            if blob.contains("installshield") { return .installShield }
        }
        return .unknown
    }

    /// True when this executable installs something rather than being the thing.
    public static func isInstaller(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "msi" { return true }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        // A file literally called "setup" that we cannot fingerprint is still
        // almost certainly an installer.
        let namedLikeInstaller = ["setup", "install", "instalar", "installer"]
            .contains { stem == $0 || stem.hasPrefix($0 + "_") || stem.hasPrefix($0 + "-") || stem.hasSuffix("-" + $0) || stem.hasSuffix("_" + $0) || stem.hasSuffix($0) }

        switch framework(of: url) {
        case .unknown: return namedLikeInstaller
        case .sfx: return namedLikeInstaller   // an SFX might just be the game
        default: return true
        }
    }
}
