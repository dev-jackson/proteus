// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Keeps a game's saved games outside the app, and keeps the game out of the
/// user's own files.
///
/// The wrapper template points the Windows user folders — Documents, Desktop,
/// Downloads, Pictures, Music, Videos — straight at the real ones. That is two
/// problems wearing one hat.
///
/// The first is data loss. A game that saves into "My Documents" is fine, but
/// plenty save beside their own executable, which is inside the app bundle.
/// Reinstalling or moving the app to the Trash takes the saves with it, and the
/// user is never warned because from the outside it looks like deleting an app.
///
/// The second is reach. A Windows program running under Wine with those links
/// in place can read and rewrite every document, every photo and everything in
/// Downloads. Nobody asked for that, and nothing about "I want to play a game"
/// implies it.
///
/// So each game gets its own folders, outside the bundle and belonging to it
/// alone. Saves survive a reinstall, and a game sees a Documents folder with
/// nothing in it but its own files.
public struct GameData {

    /// Windows user folders the template links to the real ones.
    static let userFolders = ["Desktop", "Documents", "Downloads",
                              "Music", "Pictures", "Videos", "Templates"]

    /// Files that look like saved progress rather than installed content.
    static let saveExtensions: Set<String> = ["sav", "save", "dat", "profile", "cfg",
                                              "ini", "json", "xml", "slot", "sgd"]

    public let root: URL

    public init(gameName: String, supportDir: URL? = nil) {
        let base = supportDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Proteus/Games")
        self.root = base.appendingPathComponent(GameData.slug(gameName), isDirectory: true)
    }

    static func slug(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Repoints the prefix's user folders at this game's own storage.
    ///
    /// Called after `wineboot`, which is what creates the links in the first
    /// place, and before the game is installed, so anything it writes on first
    /// run already lands outside the bundle.
    public func adopt(prefix: URL) throws {
        let fm = FileManager()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let users = prefix.appendingPathComponent("drive_c/users")
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            for folder in Self.userFolders {
                let inPrefix = user.appendingPathComponent(folder)
                let outside = root.appendingPathComponent(folder)
                try? fm.createDirectory(at: outside, withIntermediateDirectories: true)

                // Anything already there was put there by the game's installer;
                // move it rather than lose it.
                if (try? fm.destinationOfSymbolicLink(atPath: inPrefix.path)) == nil,
                   fm.fileExists(atPath: inPrefix.path) {
                    for entry in (try? fm.contentsOfDirectory(at: inPrefix, includingPropertiesForKeys: nil)) ?? [] {
                        try? fm.moveItem(at: entry, to: outside.appendingPathComponent(entry.lastPathComponent))
                    }
                }
                try? fm.removeItem(at: inPrefix)
                try? fm.createSymbolicLink(atPath: inPrefix.path, withDestinationPath: outside.path)
            }
        }
    }

    /// Copies save-shaped files out of a game folder before it is replaced.
    ///
    /// Games that write beside their own executable — an entire generation of
    /// them — cannot be helped by folder redirection, because the path they use
    /// is inside the app. The only thing that saves those is taking a copy
    /// before the app is rebuilt.
    @discardableResult
    public func preserveSaves(from gameDir: URL) -> Int {
        let fm = FileManager()
        let store = root.appendingPathComponent("beside-the-game", isDirectory: true)
        try? fm.createDirectory(at: store, withIntermediateDirectories: true)

        guard let walker = fm.enumerator(at: gameDir, includingPropertiesForKeys: [.fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }
        var saved = 0
        for case let file as URL in walker {
            guard Self.saveExtensions.contains(file.pathExtension.lowercased()) else { continue }
            // Saved games are small; a 400 MB .dat is game content.
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size < 20_000_000 else { continue }

            let relative = file.path.replacingOccurrences(of: gameDir.path + "/", with: "")
            let destination = store.appendingPathComponent(relative)
            try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            if (try? fm.copyItem(at: file, to: destination)) != nil { saved += 1 }
        }
        return saved
    }

    /// Puts preserved saves back after a reinstall, without overwriting
    /// anything the new install considers newer.
    @discardableResult
    public func restoreSaves(into gameDir: URL) -> Int {
        let fm = FileManager()
        let store = root.appendingPathComponent("beside-the-game", isDirectory: true)
        guard fm.fileExists(atPath: store.path),
              let walker = fm.enumerator(at: store, includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }
        var restored = 0
        for case let file as URL in walker {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let relative = file.path.replacingOccurrences(of: store.path + "/", with: "")
            let destination = gameDir.appendingPathComponent(relative)

            // A fresh install writes default config files. The preserved copy
            // is the one with the player's progress in it, so it wins — unless
            // the installed file is genuinely newer, which means the game has
            // already been played since.
            if fm.fileExists(atPath: destination.path) {
                let existing = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let preserved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard preserved > existing else { continue }
                try? fm.removeItem(at: destination)
            }
            try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if (try? fm.copyItem(at: file, to: destination)) != nil { restored += 1 }
        }
        return restored
    }

    /// Whether this game has anything stored outside its app.
    public var hasStoredData: Bool {
        let fm = FileManager()
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return false }
        return !entries.isEmpty
    }
}
