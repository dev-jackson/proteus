import Foundation

/// Installs the newest graphics translation layers into a wrapper.
///
/// The Wine engine ships with whatever versions were current when it was built,
/// and these move fast — DXMT gained most of its performance in releases that
/// landed months after the engine snapshot. Since the choice of layer is
/// already made from evidence, keeping the chosen one up to date is the
/// cheapest performance win available, and it costs one small download.
public actor TranslationLayers {

    public struct Layer: Sendable {
        public let identifier: String
        public let url: URL
        /// Directory inside the archive that holds the per-architecture folders.
        public let rootPrefix: String
        public let summaryEN: String
        public let summaryES: String
    }

    /// Metal-native Direct3D 11. The current best-performing path on Apple
    /// silicon, and by a wide margin on lower-spec Macs, which is exactly the
    /// audience that cannot afford the slower routes.
    public static let dxmt = Layer(
        identifier: "dxmt-v0.80",
        url: URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!,
        rootPrefix: "v0.80",
        summaryEN: "DXMT 0.80 — Direct3D 11 straight to Metal",
        summaryES: "DXMT 0.80 — Direct3D 11 directo a Metal")

    /// Wine lays its libraries out by architecture; the layer archives use the
    /// same names, so installing is a merge rather than a translation.
    static let architectures = ["x86_64-windows", "i386-windows", "x86_64-unix"]

    nonisolated let cacheDir: URL

    /// A fresh FileManager per call: the shared one is not Sendable, and these
    /// operations are plain filesystem work with no state worth keeping.
    nonisolated var fm: FileManager { FileManager() }

    public init(cacheDir: URL? = nil) {
        let base = cacheDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Proteus/Layers")
        self.cacheDir = base
    }

    public enum LayerError: Error, CustomStringConvertible {
        case downloadFailed(String)
        case unpackFailed(String)
        public var description: String {
            switch self {
            case .downloadFailed(let s): return "could not download the graphics layer: \(s)"
            case .unpackFailed(let s): return "could not unpack the graphics layer: \(s)"
            }
        }
    }

    /// Downloads and unpacks once; later wrappers reuse it.
    public func ensure(_ layer: Layer) async throws -> URL {
        let unpacked = cacheDir.appendingPathComponent(layer.identifier, isDirectory: true)
        let marker = unpacked.appendingPathComponent("x86_64-windows/d3d11.dll")
        if fm.fileExists(atPath: marker.path) { return unpacked }

        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let archive = cacheDir.appendingPathComponent("\(layer.identifier).tar.gz")
        if !fm.fileExists(atPath: archive.path) {
            do {
                let (data, response) = try await URLSession.shared.data(from: layer.url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode), data.count > 100_000 else {
                    throw LayerError.downloadFailed("unexpected response")
                }
                try data.write(to: archive)
            } catch let error as LayerError {
                throw error
            } catch {
                throw LayerError.downloadFailed(error.localizedDescription)
            }
        }

        let staging = cacheDir.appendingPathComponent(".staging-\(UUID().uuidString.prefix(6))")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let result = Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path], timeout: 300)
        guard result.exitCode == 0 else {
            throw LayerError.unpackFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let inner = staging.appendingPathComponent(layer.rootPrefix)
        let source = fm.fileExists(atPath: inner.path) ? inner : staging
        try? fm.removeItem(at: unpacked)
        try fm.moveItem(at: source, to: unpacked)
        return unpacked
    }

    /// Copies the layer's DLLs over the engine's own, per architecture.
    ///
    /// Overwriting is intended: Wine resolves `d3d11.dll` from its library
    /// directory, so a newer file in the same place is how a translation layer
    /// is meant to be installed.
    public nonisolated func install(_ layerRoot: URL, into wrapper: Wrapper) throws {
        let wineLib = wrapper.wineRoot.appendingPathComponent("lib/wine")
        for architecture in Self.architectures {
            let from = layerRoot.appendingPathComponent(architecture)
            let to = wineLib.appendingPathComponent(architecture)
            guard fm.fileExists(atPath: from.path), fm.fileExists(atPath: to.path) else { continue }
            for file in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] {
                let destination = to.appendingPathComponent(file.lastPathComponent)
                // Keep the engine's original alongside, so a bad layer update
                // can be undone without rebuilding the whole app.
                let backup = to.appendingPathComponent(file.lastPathComponent + ".engine")
                if fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: backup.path) {
                    try? fm.moveItem(at: destination, to: backup)
                }
                try? fm.removeItem(at: destination)
                try? fm.copyItem(at: file, to: destination)
            }
        }
    }

    /// Puts the engine's own libraries back.
    public nonisolated func revert(in wrapper: Wrapper) {
        let wineLib = wrapper.wineRoot.appendingPathComponent("lib/wine")
        for architecture in Self.architectures {
            let dir = wineLib.appendingPathComponent(architecture)
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "engine" {
                let original = file.deletingPathExtension()
                try? fm.removeItem(at: original)
                try? fm.moveItem(at: file, to: original)
            }
        }
    }
}
