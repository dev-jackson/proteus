// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Things a player may want to do to a game they have already installed.
///
/// Until now the only options were "play" and "delete", which meant that any
/// problem short of catastrophic had exactly one remedy: reinstall forty
/// gigabytes. Most problems deserve something smaller than that.
public struct GameActions {

    public let wrapper: Wrapper
    public let gameName: String

    public init(wrapper: Wrapper, gameName: String) {
        self.wrapper = wrapper
        self.gameName = gameName
    }

    var fm: FileManager { FileManager() }

    // MARK: - Logs

    /// The last run's output, filtered down to the lines that mean something.
    ///
    /// Raw, it is mostly MoltenVK reciting its extension inventory. Pasting
    /// that into a bug report helps nobody, so the same filtering the command
    /// line applies is applied here.
    public func recentLog(lines: Int = 200) -> String? {
        let file = wrapper.contents.appendingPathComponent("Logs/last-run.log")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return GameActions.filterLog(text, lines: lines)
    }

    static let logNoise = ["mvk-info", "vk_khr", "vk_ext", "vk_mvk", "gpu family", "gpu memory",
                           "metal shading", "read-write texture", "vulkan extensions",
                           "pipelinecacheuuid", "vendorid", "deviceid", "supports the following",
                           "handle_devicematchingcallback", "not a joystick or gamepad"]

    public static func filterLog(_ text: String, lines: Int) -> String {
        var kept: [String] = []
        var lastShape = ""
        var repeats = 0

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            guard !line.isEmpty, !line.hasPrefix("VK_"),
                  !logNoise.contains(where: { lower.contains($0) }),
                  !lower.hasPrefix("model:"), !lower.hasPrefix("type:") else { continue }

            // Two lines differing only in a pointer are the same message.
            let shape = line.replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0x…",
                                                  options: .regularExpression)
            if shape == lastShape { repeats += 1; continue }
            if repeats > 0 {
                kept.append("   … and \(repeats) more like the line above")
                repeats = 0
            }
            lastShape = shape
            kept.append(line)
        }
        if repeats > 0 { kept.append("   … and \(repeats) more like the line above") }
        return kept.suffix(lines).joined(separator: "\n")
    }

    /// Everything someone would otherwise have to be asked for, in one paste.
    public func diagnosticReport() -> String {
        let info = (try? wrapper.plist()) ?? [:]
        let engine = Runtime.installedEngineName(in: wrapper) ?? "unknown"
        var report = """
        Proteus — \(gameName)

        Program   \(info["Program Name and Path"] as? String ?? "?")
        Flags     \(info["Program Flags"] as? String ?? "(none)")
        Graphics  \(info["ProteusRenderer"] as? String ?? info["TandemRenderer"] as? String ?? "?")
        Engine    \(engine)
        Gamepad   \((info["ProteusGamepad"] as? Int ?? 1) == 1 ? "on" : "off")
        Windowed  \((info["ProteusWindowed"] as? Int ?? 0) == 1 ? "yes" : "no")
        macOS     \(ProcessInfo.processInfo.operatingSystemVersionString)

        --- last run ---
        """
        report += "\n" + (recentLog(lines: 120) ?? "(the game has not been run yet)")
        return report
    }

    // MARK: - Repair without reinstalling

    /// Puts the graphics and launch settings back to what the analysis chose.
    ///
    /// Cheap, safe, and undoes an afternoon of experimenting in the settings
    /// panel without touching a single game file.
    public func resetSettings() throws {
        var defaults = GameSettings()
        let info = (try? wrapper.plist()) ?? [:]
        defaults.renderer = Prescription.Renderer(
            rawValue: info["ProteusOriginalRenderer"] as? String
                ?? info["ProteusRenderer"] as? String ?? "wined3d") ?? .wined3d
        defaults.launchFlags = info["ProteusOriginalFlags"] as? String ?? ""
        try defaults.write(to: wrapper)
    }

    /// Rebuilds the Windows side without touching the game or its saves.
    ///
    /// A prefix can end up wedged — a half-written registry, a stuck service,
    /// a setting nobody remembers changing. The game files and the saved games
    /// live outside it, so they are unaffected; only Windows itself is made
    /// new again.
    public func rebuildWindows() throws {
        let engine = WineEngine(wrapper: wrapper)
        engine.killServer()

        // Keep the installed programs, discard the machine they ran on.
        let prefix = wrapper.prefix
        for registry in ["user.reg", "system.reg", "userdef.reg", ".update-timestamp"] {
            try? fm.removeItem(at: prefix.appendingPathComponent(registry))
        }
        let windows = wrapper.driveC.appendingPathComponent("windows")
        try? fm.removeItem(at: windows)

        try engine.boot()
        // The user folders have to be pointed back outside the bundle: wineboot
        // recreates them aimed at the real ones.
        try GameData(gameName: gameName).adopt(prefix: prefix)
    }

    /// Deletes this game's saved games and settings, leaving the game itself.
    public func deleteSavedGames() throws {
        let data = GameData(gameName: gameName)
        guard fm.fileExists(atPath: data.root.path) else { return }
        // To the Trash, never straight to oblivion: this is the one action
        // whose mistake cannot be undone any other way.
        try fm.trashItem(at: data.root, resultingItemURL: nil)
    }

    /// Total size of what would be lost, so a confirmation can say it out loud.
    public func savedGamesSize() -> Int64 {
        let data = GameData(gameName: gameName)
        guard let walker = fm.enumerator(at: data.root, includingPropertiesForKeys: [.fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
