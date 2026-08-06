// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// ISO handling. macOS mounts plain ISO9660/UDF images natively; the awkward
/// cases are the ones a Windows game disc actually ships as.
public enum DiscMounter {

    public enum MountError: Error, CustomStringConvertible {
        case attachFailed(String)
        case noMountPoint
        case unsupportedImage(String)

        public var description: String {
            switch self {
            case .attachFailed(let s): return "could not open the disc image: \(s)"
            case .noMountPoint: return "the disc image mounted but exposed no volume"
            case .unsupportedImage(let s):
                return "this image format needs conversion first (\(s))"
            }
        }
    }

    @discardableResult
    public static func mount(_ image: URL) throws -> URL {
        // -nobrowse keeps the volume out of Finder's sidebar; the user never
        // asked to see a disc, they asked to play a game.
        let result = Shell.run("/usr/bin/hdiutil",
                               ["attach", image.path, "-nobrowse", "-readonly", "-plist"])
        guard result.exitCode == 0 else {
            throw MountError.attachFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let volume = parseMountPoint(plist: result.stdout) else {
            throw MountError.noMountPoint
        }
        return volume
    }

    public static func unmount(_ volume: URL) {
        _ = Shell.run("/usr/bin/hdiutil", ["detach", volume.path, "-quiet"])
    }

    static func parseMountPoint(plist: String) -> URL? {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]]
        else { return nil }
        // Prefer the entity that carries a real mount point; the raw device
        // entries have none.
        let points = entities.compactMap { $0["mount-point"] as? String }.filter { !$0.isEmpty }
        guard let best = points.max(by: { $0.count < $1.count }) else { return nil }
        return URL(fileURLWithPath: best)
    }
}

public enum Archive {
    public enum ArchiveError: Error, CustomStringConvertible {
        case extractionFailed(String)
        public var description: String {
            switch self { case .extractionFailed(let s): return "could not unpack the archive: \(s)" }
        }
    }

    public static func extract(_ archive: URL, into workDir: URL) throws -> URL {
        let dest = workDir.appendingPathComponent(
            archive.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // ditto handles zip natively and preserves the structure faithfully.
        let ext = archive.pathExtension.lowercased()
        let result: Shell.Result
        if ext == "zip" {
            result = Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, dest.path])
        } else {
            // bsdtar covers 7z/rar-in-tar cases without extra tooling.
            result = Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", dest.path])
        }
        guard result.exitCode == 0 else {
            throw ArchiveError.extractionFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return dest
    }
}

public enum Shell {
    public struct Result {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        /// True when we stopped the process at the timeout rather than it
        /// finishing on its own. For a smoke test that is the success case.
        public let timedOut: Bool

        init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }
    }

    @discardableResult
    public static func run(_ launchPath: String,
                           _ arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil,
                           timeout: TimeInterval? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let environment {
            var env = ProcessInfo.processInfo.environment
            env.merge(environment) { _, new in new }
            process.environment = env
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Read both pipes off-thread; a chatty wine process fills the 64 KB
        // buffer and deadlocks otherwise.
        let sink = OutputSink()
        out.fileHandleForReading.readabilityHandler = { h in
            sink.appendOut(h.availableData)
        }
        err.fileHandleForReading.readabilityHandler = { h in
            sink.appendErr(h.availableData)
        }

        do { try process.run() } catch {
            return Result(exitCode: -1, stdout: "", stderr: "\(error)")
        }

        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 1.0)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process.waitUntilExit()

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let rest = try? out.fileHandleForReading.readToEnd() { sink.appendOut(rest) }
        if let rest = try? err.fileHandleForReading.readToEnd() { sink.appendErr(rest) }

        let (o, e) = sink.strings()
        return Result(exitCode: process.terminationStatus, stdout: o, stderr: e, timedOut: timedOut)
    }

    /// Pipe readers fire on an arbitrary queue, so the buffers need an owner
    /// that is safe to touch from anywhere.
    public final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        public init() {}

        public func appendOut(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); out.append(data); lock.unlock()
        }

        public func appendErr(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); err.append(data); lock.unlock()
        }

        public func strings() -> (String, String) {
            lock.lock()
            defer { lock.unlock() }
            return (String(data: out, encoding: .utf8) ?? "",
                    String(data: err, encoding: .utf8) ?? "")
        }
    }
}
