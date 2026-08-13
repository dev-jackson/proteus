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
        clearQuarantine()
        return Shell.run(wrapper.wineBinary.path, arguments,
                         environment: environment(extra: extraEnvironment),
                         currentDirectory: workingDirectory,
                         timeout: timeout)
    }

    /// Clears the quarantine flag from the bundle before running anything in it.
    ///
    /// macOS gives files created by a quarantined process the same flag, and a
    /// game arrives as a download — so its installer is quarantined, and
    /// everything it writes inside the wrapper inherits that. Sooner or later
    /// the flag reaches the bundle itself, and the moment it does, macOS starts
    /// refusing to open an app it watched us assemble, with "is damaged and
    /// can't be opened. You should move it to the Trash."
    ///
    /// Clearing it once at the end is not enough, because the dialogue appears
    /// *during* the install — the report that prompted this had the progress
    /// bar still reading "Setting up Windows" behind it. So it is cleared here
    /// instead: every path that runs anything Windows goes through this
    /// function, whether that is wineboot, winetricks, the installer or the
    /// game.
    ///
    /// One `xattr` call on a single directory, and only the bundle root, which
    /// is what the system reads. Not a bypass of anything: the bundle was built
    /// on this machine, minutes ago, by this program.
    func clearQuarantine() {
        _ = Shell.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", wrapper.bundle.path],
                      timeout: 30)
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
                                    progress: (InstallActivity) -> Void = { _ in }) throws -> Shell.Result {
        guard FileManager.default.isExecutableFile(atPath: wrapper.wineBinary.path) else {
            throw WineError.missingEngine
        }

        clearQuarantine()

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
        var lastActivity = Date()
        var lastSample = Date.distantPast
        var timedOut = false

        while process.isRunning {
            Thread.sleep(forTimeInterval: 5)
            let now = Date()
            if now.timeIntervalSince(started) > hardCap { timedOut = true; break }

            // Sample on a fixed cadence rather than off the last growth: tying
            // it to growth meant the display froze between samples, which is
            // the very thing this exists to prevent.
            guard now.timeIntervalSince(lastSample) > 4 || lastSize < 0 else { continue }
            lastSample = now

            // The largest single directory, not the sum. Inno Setup unpacks
            // into the Windows temp folder and *then* copies into place, so
            // adding them counts the same bytes twice, races past any sensible
            // estimate and pins the bar at 99% for the rest of the install.
            // The front of the work is whichever directory is currently
            // biggest.
            let size = watching.map { Self.directorySize($0) }.max() ?? 0
            let grew = size > lastSize

            // Bytes on disk are not the only sign of life, and treating them
            // that way killed healthy installs.
            //
            // A compressed installer spends long stretches decompressing:
            // minutes of solid CPU producing almost nothing on disk, then a
            // burst of files. Heavily packed ones do this for half an hour at a
            // time. Judged on bytes alone that is indistinguishable from a
            // hang, so the deadline fired and a good install was terminated
            // two thirds of the way through.
            //
            // So the process tree gets a vote. If it is burning CPU it is
            // working, whatever the disk says.
            let cpu = Self.processTreeCPU(rootPID: process.processIdentifier)
            let busy = cpu >= Self.workingCPUThreshold

            if grew {
                lastSize = size
                lastActivity = now
            } else if busy {
                lastActivity = now
            }

            if grew || busy {
                // `working` tells the caller to stop showing a percentage that
                // cannot move, and say what is actually happening instead.
                progress(InstallActivity(bytes: max(size, 0),
                                         working: !grew && busy,
                                         cpu: cpu))
            } else if now.timeIntervalSince(lastActivity) > stallFor {
                timedOut = true
                break
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

    /// What the installer is doing right now.
    ///
    /// Two different things count as progress and they need telling apart: a
    /// growing byte count can drive a percentage, whereas a process working
    /// hard on nothing visible can only be reported honestly as "still going".
    public struct InstallActivity: Sendable {
        /// Bytes written so far, by the largest watched directory.
        public let bytes: Int64
        /// Busy, but with nothing to show for it yet — decompressing.
        public let working: Bool
        /// Combined CPU of the installer's process tree, in percent.
        public let cpu: Double

        public init(bytes: Int64, working: Bool = false, cpu: Double = 0) {
            self.bytes = bytes
            self.working = working
            self.cpu = cpu
        }
    }

    /// Above this, the installer is considered to be working rather than hung.
    ///
    /// Low on purpose. A single busy thread reads as ~100%, and the number only
    /// has to separate "doing something" from "doing nothing" — an idle,
    /// genuinely wedged process sits near zero, not near ten.
    static let workingCPUThreshold: Double = 8

    /// Combined CPU of a process and everything it spawned.
    ///
    /// Wine does not keep its children tidy: the loader hands off to a `.tmp`
    /// extractor, `wineserver` runs alongside, and some of it reparents away
    /// from us. So descendants are followed by parentage *and* by process
    /// group, and anything reachable either way counts.
    ///
    /// One `ps` call, parsed in memory. Polling this every few seconds must not
    /// itself become the load.
    static func processTreeCPU(rootPID: pid_t) -> Double {
        let listing = Shell.run("/bin/ps", ["-Ao", "pid=,ppid=,pgid=,pcpu="])
        guard listing.exitCode == 0 else { return 0 }

        struct Entry { let ppid: pid_t; let pgid: pid_t; let cpu: Double }
        var table: [pid_t: Entry] = [:]
        var children: [pid_t: [pid_t]] = [:]

        for line in listing.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]),
                  let pgid = pid_t(parts[2]), let cpu = Double(parts[3]) else { continue }
            table[pid] = Entry(ppid: ppid, pgid: pgid, cpu: cpu)
            children[ppid, default: []].append(pid)
        }

        guard let root = table[rootPID] else { return 0 }

        var total: Double = 0
        var seen: Set<pid_t> = []
        var queue: [pid_t] = [rootPID]

        // Anything sharing the loader's process group is part of this install
        // even when the parent chain has been broken.
        for (pid, entry) in table where entry.pgid == root.pgid { queue.append(pid) }

        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted, let entry = table[pid] else { continue }
            total += entry.cpu
            queue.append(contentsOf: children[pid] ?? [])
        }
        return total
    }

    /// Cheap recursive size. Capped: an installer writing hundreds of thousands
    /// of files should not turn the progress check into the slow part.
    ///
    /// The cap used to be 20,000, which was low enough to cause the bug it was
    /// meant to avoid. Past that many files the walk stopped early, the total
    /// stopped rising, and a large game — which is exactly the case that needs
    /// a progress bar — showed a frozen one and was then killed for stalling.
    /// Big games routinely hold six figures of files.
    static func directorySize(_ root: URL, limit: Int = 400_000) -> Int64 {
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

    /// Turns sound off, or back on, for everything in this prefix.
    ///
    /// Installers play music. Inno Setup and NSIS both support a soundtrack and
    /// plenty of games ship one, which made sense in 1998 next to a wizard with
    /// a picture of a spaceship on it.
    ///
    /// Here there is no wizard. Proteus runs installers silently, so the window
    /// the person is looking at is a progress bar in a Mac app — and music
    /// starts playing from a program with no visible interface, out of nowhere,
    /// with nothing to stop it. It reads as something having gone wrong.
    ///
    /// Setting the audio driver to nothing is Wine's own supported way of doing
    /// this (`winecfg` calls it "Driver: none"). It is a property of the
    /// prefix, not of the process, so it must be put back afterwards or the
    /// game itself would be mute.
    public func setAudioEnabled(_ enabled: Bool) throws {
        try applyRegistry([
            (path: "HKCU\\Software\\Wine\\Drivers", key: "Audio",
             type: "REG_SZ", value: enabled ? "coreaudio" : ""),
        ])
    }

    func lastLines(_ text: String, _ n: Int) -> String {
        text.split(whereSeparator: \.isNewline).suffix(n).joined(separator: "\n")
    }
}
