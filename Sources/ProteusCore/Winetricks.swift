// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Installs the Windows redistributables a game needs. Winetricks is a shell
/// script; we cache one copy and drive it per wrapper.
public struct Winetricks {
    public static let scriptURL = URL(string: "https://raw.githubusercontent.com/Sikarugir-App/winetricks/master/src/winetricks")!

    let cacheDir: URL
    let fm = FileManager.default

    public init(cacheDir: URL) { self.cacheDir = cacheDir }

    public var scriptPath: URL { cacheDir.appendingPathComponent("winetricks") }

    public enum TricksError: Error, CustomStringConvertible {
        case unavailable(String)
        public var description: String {
            switch self { case .unavailable(let s): return "could not prepare the component installer: \(s)" }
        }
    }

    public func ensureScript() async throws -> URL {
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Refresh weekly: verb definitions and download URLs rot quickly.
        if let attrs = try? fm.attributesOfItem(atPath: scriptPath.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 7 * 86_400 {
            return scriptPath
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.scriptURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 100_000 else {
                throw TricksError.unavailable("unexpected response")
            }
            try data.write(to: scriptPath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
            return scriptPath
        } catch {
            // A stale script beats no script; only fail if we have neither.
            if fm.fileExists(atPath: scriptPath.path) { return scriptPath }
            throw TricksError.unavailable(error.localizedDescription)
        }
    }

    public struct VerbOutcome: Sendable {
        public let verb: String
        public let installed: Bool
        public let detail: String
    }

    /// Runs one verb. Failures are reported, never fatal: a game often runs
    /// fine without an optional component, and stopping the whole install
    /// because `physx` 404'd would be the exact NASA-grade behaviour we are
    /// trying to get rid of.
    public func install(_ verb: String, into wrapper: Wrapper, engine: WineEngine,
                        timeout: TimeInterval = 900) -> VerbOutcome {
        guard fm.isExecutableFile(atPath: scriptPath.path) else {
            return VerbOutcome(verb: verb, installed: false, detail: "component installer unavailable")
        }
        var env = engine.environment()
        env["WINE"] = wrapper.wineBinary.path
        env["WINESERVER"] = wrapper.wineRoot.appendingPathComponent("bin/wineserver").path
        env["W_CACHE"] = cacheDir.appendingPathComponent("cache").path
        env["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        env["WINETRICKS_SUPER_QUIET"] = "1"
        // Winetricks shells out constantly; give it a normal PATH plus wine's.
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/bin:/bin:/usr/sbin:/sbin"

        let result = Shell.run("/bin/sh", [scriptPath.path, "-q", "--force", verb],
                               environment: env, timeout: timeout)
        let combined = result.stdout + result.stderr
        let failed = result.exitCode != 0
            || combined.contains("Downloading") && combined.contains("failed")
            || combined.lowercased().contains("sha256sum mismatch")
        return VerbOutcome(verb: verb,
                           installed: !failed,
                           detail: failed ? lastMeaningfulLine(combined) : "ok")
    }

    func lastMeaningfulLine(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("+ ") }
        return lines.suffix(2).joined(separator: " / ")
    }
}
