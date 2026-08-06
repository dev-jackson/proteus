// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Drives Wine inside a wrapper without ever showing the user a terminal.
public struct WineEngine {
    public let wrapper: Wrapper

    public init(wrapper: Wrapper) { self.wrapper = wrapper }

    public enum WineError: Error, CustomStringConvertible {
        case bootFailed(String)
        case runFailed(command: String, code: Int32, log: String)
        case missingEngine

        public var description: String {
            switch self {
            case .bootFailed(let s): return "Windows environment failed to start: \(s)"
            case .runFailed(let cmd, let code, _): return "\(cmd) exited with code \(code)"
            case .missingEngine: return "the Wine engine is missing from the app"
            }
        }
    }

    /// Environment every wine invocation needs. Getting DYLD_FALLBACK_LIBRARY_PATH
    /// wrong is the classic "dyld: library not loaded" failure, so the wrapper's
    /// own Frameworks folder is always on the path.
    public func environment(extra: [String: String] = [:]) -> [String: String] {
        let wine = wrapper.wineRoot
        var env: [String: String] = [
            "WINEPREFIX": wrapper.prefix.path,
            "WINEDLLPATH": wine.appendingPathComponent("lib/wine").path,
            "DYLD_FALLBACK_LIBRARY_PATH": [
                wine.appendingPathComponent("lib").path,
                wrapper.frameworks.path,
                "/usr/local/lib", "/usr/lib",
            ].joined(separator: ":"),
            "PATH": wine.appendingPathComponent("bin").path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            // Quiet by default; the failure paths raise it deliberately.
            "WINEDEBUG": "-all",
            "WINEESYNC": "1",
            "WINEMSYNC": "1",
            // Never let Wine stop to ask about Gecko/Mono during automation.
            "WINEDLLOVERRIDES": "mscoree,mshtml=",
        ]
        env.merge(extra) { _, new in new }
        return env
    }

    @discardableResult
    public func run(_ arguments: [String],
                    extraEnvironment: [String: String] = [:],
                    timeout: TimeInterval = 900,
                    workingDirectory: URL? = nil) throws -> Shell.Result {
        guard FileManager.default.isExecutableFile(atPath: wrapper.wineBinary.path) else {
            throw WineError.missingEngine
        }
        return Shell.run(wrapper.wineBinary.path, arguments,
                         environment: environment(extra: extraEnvironment),
                         currentDirectory: workingDirectory,
                         timeout: timeout)
    }

    /// Creates the Windows filesystem and registry. First run of a new prefix
    /// takes a while; everything after it is fast.
    public func boot(timeout: TimeInterval = 300) throws {
        let result = try run(["wineboot", "--init"], timeout: timeout)
        // wineboot frequently returns non-zero while still having produced a
        // perfectly good prefix, so judge it by what landed on disk.
        let windows = wrapper.driveC.appendingPathComponent("windows")
        guard FileManager.default.fileExists(atPath: windows.path) else {
            throw WineError.bootFailed(lastLines(result.stderr, 6))
        }
        waitForServerIdle()
    }

    /// Wine keeps a background server alive after each command; letting it
    /// settle avoids registry writes racing the next step.
    public func waitForServerIdle(timeout: TimeInterval = 30) {
        let server = wrapper.wineRoot.appendingPathComponent("bin/wineserver")
        guard FileManager.default.isExecutableFile(atPath: server.path) else { return }
        _ = Shell.run(server.path, ["-w"], environment: environment(), timeout: timeout)
    }

    public func killServer() {
        let server = wrapper.wineRoot.appendingPathComponent("bin/wineserver")
        guard FileManager.default.isExecutableFile(atPath: server.path) else { return }
        _ = Shell.run(server.path, ["-k"], environment: environment(), timeout: 20)
    }

    /// Runs a command that may take a very long time, and judges it by whether
    /// it is still doing work rather than by a stopwatch.
    ///
    /// A fixed timeout cannot serve both cases: thirty minutes is generous for
    /// a 200 MB game and nowhere near enough for a 40 GB one, where it kills a
    /// perfectly healthy install two thirds of the way through and leaves the
    /// user with an app that does nothing. So the deadline follows the work:
    /// as long as the target directory keeps growing, the installer is alive
    /// and gets more time.
    ///
    /// - Parameters:
    ///   - watching: directories whose growth counts as progress.
    ///   - stallFor: how long to allow with no growth before giving up.
    ///   - hardCap: an absolute ceiling, so a runaway process still ends.
    @discardableResult
    public func runWatchingProgress(_ arguments: [String],
                                    watching: [URL],
                                    stallFor: TimeInterval = 900,
                                    hardCap: TimeInterval = 6 * 3600,
                                    workingDirectory: URL? = nil,
                                    progress: (Int64) -> Void = { _ in }) throws -> Shell.Result {
        guard FileManager.default.isExecutableFile(atPath: wrapper.wineBinary.path) else {
            throw WineError.missingEngine
        }

        let process = Process()
        process.executableURL = wrapper.wineBinary
        process.arguments = arguments
        process.environment = environment()
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let pipe = Pipe()
        let sink = Shell.OutputSink()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { sink.appendOut($0.availableData) }

        do { try process.run() } catch {
            return Shell.Result(exitCode: -1, stdout: "", stderr: "\(error)")
        }

        let started = Date()
        var lastSize: Int64 = -1
        var lastGrowth = Date()
        var lastSample = Date.distantPast
        var timedOut = false

        while process.isRunning {
            Thread.sleep(forTimeInterval: 5)
            let now = Date()
            if now.timeIntervalSince(started) > hardCap { timedOut = true; break }

            // Sample on a fixed cadence rather than off the last growth: tying
            // it to growth meant the display froze between samples, which is
            // the very thing this exists to prevent.
            if now.timeIntervalSince(lastSample) > 4 || lastSize < 0 {
                lastSample = now
                // The largest single directory, not the sum. Inno Setup
                // unpacks into the Windows temp folder and *then* copies into
                // place, so adding them counts the same bytes twice, races past
                // any sensible estimate and pins the bar at 99% for the rest of
                // the install. The front of the work is whichever directory is
                // currently biggest.
                let size = watching.map { Self.directorySize($0) }.max() ?? 0
                if size > lastSize {
                    lastSize = size
                    lastGrowth = now
                    progress(size)
                } else if now.timeIntervalSince(lastGrowth) > stallFor {
                    timedOut = true
                    break
                }
            }
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 1.0)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { sink.appendOut(rest) }

        let (out, _) = sink.strings()
        return Shell.Result(exitCode: process.terminationStatus, stdout: out, stderr: "",
                            timedOut: timedOut)
    }

    /// Cheap recursive size. Capped: an installer writing hundreds of thousands
    /// of files should not turn the progress check into the slow part.
    static func directorySize(_ root: URL, limit: Int = 20_000) -> Int64 {
        let fm = FileManager()
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                    options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        var seen = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            seen += 1
            if seen >= limit { break }
        }
        return total
    }

    /// Applies registry settings that make games behave, e.g. windowed mode and
    /// DLL overrides for a translation layer.
    public func applyRegistry(_ entries: [(path: String, key: String, type: String, value: String)]) throws {
        for entry in entries {
            _ = try run(["reg", "add", entry.path, "/v", entry.key,
                         "/t", entry.type, "/d", entry.value, "/f"], timeout: 60)
        }
    }

    func lastLines(_ text: String, _ n: Int) -> String {
        text.split(whereSeparator: \.isNewline).suffix(n).joined(separator: "\n")
    }
}
