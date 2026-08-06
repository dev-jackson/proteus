// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Data a game needs but a silent install does not deliver.
///
/// Some installers fetch part of the game the first time a human clicks
/// through them. Told to be silent they skip that step, and the result starts,
/// opens a window, and then sits on a dialog asking permission to download what
/// it is missing. OpenTTD is the textbook case: installed with `/S` it has no
/// graphics at all.
///
/// Letting the game download its own data is the obvious answer and it does not
/// work — OpenTTD's downloader crashes inside the prefix, leaving the game
/// exactly as broken and a crash dump in the user's Documents. So Proteus
/// fetches the data itself, on the host, where the network stack is not being
/// emulated, and puts it where the game expects.
///
/// The list is deliberately small and additive: each entry is one game's known
/// missing piece. That is the same shape winetricks uses for runtimes, and it
/// is honest about what this is — accumulated knowledge, not a general law.
public struct ContentPack: Sendable {
    public let identifier: String
    public let url: URL
    /// Where the files belong, relative to the installed game folder.
    public let destination: String
    public let summaryEN: String
    public let summaryES: String
    /// Given the installed game folder, is this pack missing?
    public let isMissing: @Sendable (URL) -> Bool

    // MARK: - Known packs

    /// OpenTTD ships no graphics of its own; without a base set it cannot draw
    /// a single pixel and refuses to start.
    public static let openGFX = ContentPack(
        identifier: "opengfx-7.1",
        url: URL(string: "https://cdn.openttd.org/opengfx-releases/7.1/opengfx-7.1-all.zip")!,
        destination: "baseset",
        summaryEN: "OpenTTD's graphics set",
        summaryES: "el conjunto gráfico de OpenTTD",
        isMissing: { gameDir in
            let fm = FileManager()
            // Only applies to OpenTTD, and only when no base graphics are
            // present. The `orig_*` files that ship with it are descriptions of
            // the original game's data, not the data itself.
            guard fm.fileExists(atPath: gameDir.appendingPathComponent("openttd.exe").path) else {
                return false
            }
            let baseset = gameDir.appendingPathComponent("baseset")
            let files = (try? fm.contentsOfDirectory(atPath: baseset.path)) ?? []
            return !files.contains { $0.lowercased().hasPrefix("opengfx") }
        })

    public static let all: [ContentPack] = [openGFX]

    /// Packs this installed game is missing.
    public static func missing(for gameDir: URL) -> [ContentPack] {
        all.filter { $0.isMissing(gameDir) }
    }
}

/// Downloads and unpacks content packs into an installed game.
public actor ContentPackInstaller {

    nonisolated let cacheDir: URL
    nonisolated var fm: FileManager { FileManager() }

    public init(cacheDir: URL? = nil) {
        self.cacheDir = cacheDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Proteus/Content")
    }

    public enum PackError: Error, CustomStringConvertible {
        case downloadFailed(String)
        case unpackFailed(String)
        public var description: String {
            switch self {
            case .downloadFailed(let s): return "could not download the game data: \(s)"
            case .unpackFailed(let s): return "could not unpack the game data: \(s)"
            }
        }
    }

    /// Fetches the pack once and keeps it; a second game needing the same data
    /// costs nothing.
    public func install(_ pack: ContentPack, into gameDir: URL) async throws {
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let archive = cacheDir.appendingPathComponent("\(pack.identifier).zip")

        if !fm.fileExists(atPath: archive.path) {
            do {
                let (data, response) = try await URLSession.shared.data(from: pack.url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode), data.count > 10_000 else {
                    throw PackError.downloadFailed("unexpected response")
                }
                try data.write(to: archive)
            } catch let error as PackError {
                throw error
            } catch {
                throw PackError.downloadFailed(error.localizedDescription)
            }
        }

        let staging = cacheDir.appendingPathComponent(".staging-\(UUID().uuidString.prefix(6))")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path], timeout: 300)
        guard unzip.exitCode == 0 else {
            throw PackError.unpackFailed(unzip.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // These archives are a zip wrapping a tar; unwrap whatever is inside
        // rather than assuming one shape.
        for entry in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        where entry.pathExtension.lowercased() == "tar" {
            _ = Shell.run("/usr/bin/tar", ["-xf", entry.path, "-C", staging.path], timeout: 300)
            try? fm.removeItem(at: entry)
        }

        let destination = gameDir.appendingPathComponent(pack.destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyContents(of: staging, into: destination)
    }

    /// Copies files in, flattening one level of wrapper directory if the
    /// archive has one.
    func copyContents(of source: URL, into destination: URL) throws {
        var roots = [source]
        let top = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let directories = top.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if top.count == 1, let only = directories.first { roots = [only] }

        for root in roots {
            for file in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: file, to: target)
            }
        }
    }
}
