// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Owns the two big binary blobs a wrapper is built from: the wrapper template
/// and a Wine engine. Both are fetched once, cached, and reused — the user is
/// never asked to install Homebrew, Xcode tools or anything else.
public actor Runtime {

    public struct EngineChoice: Sendable {
        public let identifier: String
        public let url: URL
        public let summaryEN: String
        public let summaryES: String
    }

    /// Default engine: CrossOver-derived Wine, the broadest compatibility for
    /// ordinary games including 32-bit ones.
    public static let defaultEngine = EngineChoice(
        identifier: "WS12WineSikarugir10.0_6",
        url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz")!,
        summaryEN: "Wine 10 (general compatibility)",
        summaryES: "Wine 10 (compatibilidad general)")

    /// Apple's Game Porting Toolkit path, needed for D3DMetal on DX12 titles.
    public static let gptkEngine = EngineChoice(
        identifier: "WS12WineGPTK1.1_3",
        url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineGPTK1.1_3.tar.xz")!,
        summaryEN: "Wine + Game Porting Toolkit (DirectX 12)",
        summaryES: "Wine + Game Porting Toolkit (DirectX 12)")

    public static let templateName = "Template-1.0.11"
    public static let templateURL = URL(string: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz")!

    public enum RuntimeError: Error, CustomStringConvertible {
        case downloadFailed(String, underlying: String)
        case extractionFailed(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .downloadFailed(let what, let why): return "could not download \(what): \(why)"
            case .extractionFailed(let what): return "could not unpack \(what)"
            case .notFound(let what): return "\(what) is missing"
            }
        }
    }

    public struct Progress: Sendable {
        public let stageEN: String
        public let stageES: String
        public let fraction: Double?   // nil = indeterminate
    }

    let fm = FileManager.default
    public let supportDir: URL
    public let enginesDir: URL
    public let templatesDir: URL

    /// Existing Sikarugir/Kegworks installs keep the same blobs; reuse them
    /// rather than making the user download a second copy.
    static let foreignSupportDirs = ["Sikarugir", "Kegworks", "Wineskin"]

    public init(supportDir: URL? = nil) {
        let base = supportDir ?? fmDefaultSupport()
        self.supportDir = base
        self.enginesDir = base.appendingPathComponent("Engines")
        self.templatesDir = base.appendingPathComponent("Templates")
    }

    // MARK: - Template

    public func ensureTemplate(progress: @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        let installed = templatesDir.appendingPathComponent("\(Self.templateName).app")
        if fm.fileExists(atPath: installed.path) { return installed }

        // Reuse a template another wrapper tool already downloaded.
        if let borrowed = findForeignTemplate() {
            progress(.init(stageEN: "Reusing an existing Wine template",
                           stageES: "Reutilizando una plantilla de Wine existente", fraction: nil))
            try fm.createDirectory(at: templatesDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: installed)
            try fm.copyItem(at: borrowed, to: installed)
            return installed
        }

        try fm.createDirectory(at: templatesDir, withIntermediateDirectories: true)
        let archive = templatesDir.appendingPathComponent("\(Self.templateName).tar.xz")
        try await download(Self.templateURL, to: archive, label: ("wrapper template", "plantilla"), progress: progress)

        progress(.init(stageEN: "Unpacking the wrapper template",
                       stageES: "Descomprimiendo la plantilla", fraction: nil))
        let result = Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", templatesDir.path])
        guard result.exitCode == 0 else { throw RuntimeError.extractionFailed("wrapper template") }
        try? fm.removeItem(at: archive)

        guard fm.fileExists(atPath: installed.path) else {
            // Some template archives use a bare "Template.app" name.
            let alt = templatesDir.appendingPathComponent("Template.app")
            if fm.fileExists(atPath: alt.path) {
                try fm.moveItem(at: alt, to: installed)
                return installed
            }
            throw RuntimeError.notFound("wrapper template")
        }
        return installed
    }

    func findForeignTemplate() -> URL? {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let support else { return nil }
        for name in Self.foreignSupportDirs {
            let dir = support.appendingPathComponent(name).appendingPathComponent("Template")
            let candidates = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            // Newest version string wins.
            if let best = candidates.filter({ $0.pathExtension == "app" })
                .sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending })
                .last {
                return best
            }
        }
        return nil
    }

    // MARK: - Engine

    public func ensureEngine(_ engine: EngineChoice,
                             progress: @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        try fm.createDirectory(at: enginesDir, withIntermediateDirectories: true)
        let local = enginesDir.appendingPathComponent("\(engine.identifier).tar.xz")
        if fm.fileExists(atPath: local.path) { return local }

        if let borrowed = findForeignEngine(engine.identifier) {
            progress(.init(stageEN: "Reusing an existing Wine engine",
                           stageES: "Reutilizando un motor de Wine existente", fraction: nil))
            try fm.copyItem(at: borrowed, to: local)
            return local
        }

        try await download(engine.url, to: local,
                           label: ("Wine engine", "motor de Wine"), progress: progress)
        return local
    }

    /// Which engine a wrapper currently has, by the version file the engine
    /// writes into itself.
    public nonisolated static func installedEngineName(in wrapper: Wrapper) -> String? {
        let version = wrapper.wineRoot.appendingPathComponent("version")
        guard let text = try? String(contentsOf: version, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the wrapper is running the Game Porting Toolkit engine, which
    /// is the only one that carries D3DMetal.
    ///
    /// The engine names itself "Game Porting Toolkit v1.1", not "GPTK" — the
    /// download is called `WS12WineGPTK` but the version file it writes is
    /// spelled out. Matching only the abbreviation made this always false, so
    /// the engine would have been swapped again on every check.
    public nonisolated static func hasGPTK(_ wrapper: Wrapper) -> Bool {
        let name = (installedEngineName(in: wrapper) ?? "").lowercased()
        return name.contains("gptk") || name.contains("game porting toolkit")
    }

    /// Unpacks the engine once and keeps it. Wrappers then clone it with APFS,
    /// so the second game costs almost no disk instead of another gigabyte.
    public func ensureEngineUnpacked(_ engine: EngineChoice,
                                     progress: @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        let unpacked = enginesDir.appendingPathComponent(engine.identifier, isDirectory: true)
        let marker = unpacked.appendingPathComponent("bin/wine")
        if fm.isExecutableFile(atPath: marker.path) { return unpacked }

        let archive = try await ensureEngine(engine, progress: progress)
        progress(.init(stageEN: "Unpacking the Wine engine",
                       stageES: "Descomprimiendo el motor de Wine", fraction: nil))

        let staging = enginesDir.appendingPathComponent(".staging-\(UUID().uuidString.prefix(6))")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let result = Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", staging.path], timeout: 900)
        guard result.exitCode == 0 else { throw RuntimeError.extractionFailed("Wine engine") }

        // The archive wraps everything in `wswine.bundle`; wrappers expect its
        // contents directly.
        let inner = staging.appendingPathComponent("wswine.bundle")
        let source = fm.fileExists(atPath: inner.path) ? inner : staging
        try? fm.removeItem(at: unpacked)
        try fm.moveItem(at: source, to: unpacked)
        return unpacked
    }

    func findForeignEngine(_ identifier: String) -> URL? {
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        for name in Self.foreignSupportDirs {
            let candidate = support.appendingPathComponent(name)
                .appendingPathComponent("Engines")
                .appendingPathComponent("\(identifier).tar.xz")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Download

    func download(_ url: URL, to destination: URL,
                  label: (en: String, es: String),
                  progress: @Sendable (Progress) -> Void) async throws {
        let session = URLSession(configuration: .default)
        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)

        do {
            let (bytes, response) = try await session.bytes(from: url)
            let expected = response.expectedContentLength
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw RuntimeError.downloadFailed(label.en, underlying: "server refused the request")
            }

            fm.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            var written: Int64 = 0
            var lastReport = Date.distantPast

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastReport) > 0.2 {
                        lastReport = Date()
                        let fraction = expected > 0 ? Double(written) / Double(expected) : nil
                        progress(.init(stageEN: "Downloading the \(label.en)",
                                       stageES: "Descargando el \(label.es)",
                                       fraction: fraction))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            try handle.close()

            guard written > 1_000_000 else {
                throw RuntimeError.downloadFailed(label.en, underlying: "the download was truncated")
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: partial, to: destination)
        } catch let error as RuntimeError {
            try? fm.removeItem(at: partial)
            throw error
        } catch {
            try? fm.removeItem(at: partial)
            throw RuntimeError.downloadFailed(label.en, underlying: error.localizedDescription)
        }
    }

    /// How much has to come off the network before the first game can run.
    public func pendingDownloadBytes(engine: EngineChoice) -> Int64 {
        var total: Int64 = 0
        let template = templatesDir.appendingPathComponent("\(Self.templateName).app")
        if !fm.fileExists(atPath: template.path) && findForeignTemplate() == nil { total += 84_000_000 }
        let enginePath = enginesDir.appendingPathComponent("\(engine.identifier).tar.xz")
        if !fm.fileExists(atPath: enginePath.path) && findForeignEngine(engine.identifier) == nil {
            total += 166_000_000
        }
        return total
    }
}

private func fmDefaultSupport() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Proteus")
}
