// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import CoreGraphics
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
    /// - Parameters:
    ///   - destination: where the game will end up. Measured separately,
    ///     because it is the only directory whose size means "how much of this
    ///     game is installed".
    ///   - watching: the staging areas as well — temp folders an installer
    ///     unpacks into before copying across.
    public func runWatchingProgress(_ arguments: [String],
                                    destination: URL,
                                    watching: [URL],
                                    stallFor: TimeInterval = 900,
                                    // How long a dialogue may sit there, with
                                    // nothing being written, before the silent
                                    // attempt is abandoned.
                                    //
                                    // Fifteen seconds, and it was five
                                    // minutes. "Who wants to wait five
                                    // minutes?" — nobody, and there was never
                                    // a reason to. The dialogue is spotted in
                                    // about five; everything after that was
                                    // caution about interrupting an installer
                                    // that might still have been working.
                                    //
                                    // Measuring a working install removed the
                                    // need for the caution entirely. It opens
                                    // no window at all beyond wine's virtual
                                    // desktop: three processes, three windows,
                                    // every one of them 500×500. A window that
                                    // is not the desktop, while nothing
                                    // whatever is being written, is already
                                    // the answer.
                                    //
                                    // What is left is one more sampling cycle,
                                    // so that something which merely flashes
                                    // up and goes away is not mistaken for
                                    // something waiting. That is all the delay
                                    // is for, and it is the whole of it.
                                    promptAfter: TimeInterval = 15,
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
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // A zero-length read means the writer has gone. Left armed, the handler is
            // called again immediately and forever, which is a busy loop on a dead
            // descriptor — it was measured burning a whole core for fourteen hours.
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            sink.appendOut(chunk)
        }

        do { try process.run() } catch {
            return Shell.Result(exitCode: -1, stdout: "", stderr: "\(error)")
        }

        let started = Date()
        var lastSize: Int64 = -1
        var lastActivity = Date()
        var lastSample = Date.distantPast
        var timedOut = false
        var lastGrowth = Date()
        var waitingOn: String?
        // The destination is measured whether or not the caller listed it.
        let allWatched = ([destination] + watching).reduce(into: [URL]()) { unique, url in
            if !unique.contains(where: { $0.path == url.path }) { unique.append(url) }
        }
        var peak: [String: Int64] = [:]

        while process.isRunning {
            Thread.sleep(forTimeInterval: 5)
            let now = Date()
            if now.timeIntervalSince(started) > hardCap { timedOut = true; break }

            // Sample on a fixed cadence rather than off the last growth: tying
            // it to growth meant the display froze between samples, which is
            // the very thing this exists to prevent.
            guard now.timeIntervalSince(lastSample) > 4 || lastSize < 0 else { continue }
            lastSample = now

            // A high-water mark per directory, summed.
            //
            // The obvious readings both fail. Summing current sizes counts the
            // same bytes twice while a staged copy is in flight, and collapses
            // when the installer deletes its temp folder — the number goes
            // *backwards*. Taking the largest directory instead freezes for the
            // entire copy phase: the destination has to grow past whatever the
            // temp folder reached before the display moves at all, which on a
            // large game is many minutes of a number that will not budge.
            //
            // High-water marks fix both. Every directory contributes the most
            // it ever held, so the total only ever rises, and it rises the
            // moment *any* of them grows — during extraction and during the
            // copy that follows.
            for directory in allWatched {
                let size = Self.directorySize(directory)
                if size > (peak[directory.path] ?? 0) { peak[directory.path] = size }
            }
            let size = peak.values.reduce(0, +)
            let installed = peak[destination.path] ?? 0
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
            // Identified by the bundle they run from, because wine's children
            // detach from us entirely — see `processes(inBundle:)`.
            let family = Self.processes(inBundle: wrapper.bundle.path)
            let cpu = family.cpu
            let busy = cpu >= Self.workingCPUThreshold
            // Looked for every cycle, not only once the deadline is near. A
            // dialogue during a *silent* install is worth saying out loud the
            // moment it appears — see the note on `promptAfter`.
            let dialogue = Self.suppressedDialogue(ownedBy: family.pids)

            if grew {
                lastSize = size
                lastActivity = now
                lastGrowth = now
            } else if busy {
                lastActivity = now
            }

            // A "silent" installer that is not silent after all.
            //
            // Found by sampling one that had been at 100% CPU for minutes with
            // nothing on disk: the busy thread was in NtUserPeekMessage →
            // NtYieldExecution, a message pump spinning on a question nobody
            // was there to answer. It had a window titled "Setup", one pixel
            // by one pixel — /VERYSILENT hid the dialogue but did not answer
            // it. Left alone it would spin until the six-hour cap.
            //
            // CPU is why this needs its own check: a spinning pump looks
            // exactly as busy as real work, so the liveness rule above would
            // happily wait forever. Disk growth is the honest measure of
            // progress, and a titled window is the evidence of what it is
            // waiting for.
            if now.timeIntervalSince(lastGrowth) > promptAfter, let title = dialogue {
                waitingOn = title
                break
            }

            // Reported every sample, unconditionally.
            //
            // It used to be reported only when something had grown or the CPU
            // was busy, and an installer sitting on its own wizard is neither:
            // it waits on a click at nearly zero percent. So the single state
            // most worth describing was the one that produced no report at all
            // — the code knew it was waiting on a dialogue while the display
            // said nothing whatever. Caught by driving a real installer
            // without its silent flags, which is the only way this shows up.
            //
            // There is always something true to say. Even with nothing moving
            // the elapsed time advances, and a number that changes is the
            // difference between waiting and wondering.
            //
            // `working` tells the caller to stop showing a percentage that
            // cannot move, and say what is actually happening instead.
            progress(InstallActivity(bytes: max(size, 0),
                                     installed: installed,
                                     working: !grew && busy,
                                     cpu: cpu,
                                     waitingOn: dialogue))

            if now.timeIntervalSince(lastActivity) > stallFor {
                timedOut = true
                break
            }
        }

        // Killing the process we launched is not enough, and assuming it was
        // cost fourteen hours of a wedged install burning two cores.
        //
        // Wine detaches: the loader exits, and the extractor carries on with
        // ppid 1 in a process group of its own. It still holds the write end
        // of this pipe, so `readToEnd()` below waits for an end-of-file that
        // will never arrive, and the readability handler spins on the same
        // descriptor at full tilt. The loop had already decided to stop; what
        // followed it never returned.
        //
        // So everything running from this bundle goes, identified the same way
        // it is measured — by the executable it runs from.
        if process.isRunning || !Self.processes(inBundle: wrapper.bundle.path).pids.isEmpty {
            process.terminate()
            for pid in Self.processes(inBundle: wrapper.bundle.path).pids { kill(pid, SIGTERM) }
            Thread.sleep(forTimeInterval: 1.5)
            for pid in Self.processes(inBundle: wrapper.bundle.path).pids { kill(pid, SIGKILL) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        // Deliberately not `readToEnd()`. Whatever the handler collected is
        // the log; waiting for the descriptor to close is exactly the trap
        // above, and a truncated log is worth incomparably more than a
        // complete one that never arrives.
        try? pipe.fileHandleForReading.close()

        let (out, _) = sink.strings()
        return Shell.Result(exitCode: process.terminationStatus, stdout: out, stderr: "",
                            timedOut: timedOut, waitingOn: waitingOn)
    }

    /// What the installer is doing right now.
    ///
    /// Two different things count as progress and they need telling apart: a
    /// growing byte count can drive a percentage, whereas a process working
    /// hard on nothing visible can only be reported honestly as "still going".
    public struct InstallActivity: Sendable {
        /// Every byte the installer has written anywhere, ever. Only goes up.
        public let bytes: Int64
        /// Bytes that have reached the place the game will actually live.
        /// This, and not `bytes`, is what a percentage should be measured on.
        public let installed: Int64
        /// Busy, but with nothing to show for it yet — decompressing.
        public let working: Bool
        /// Combined CPU of the installer's process tree, in percent.
        public let cpu: Double
        /// The title of a dialogue the installer has put on screen. Reported
        /// the moment it appears — long before any decision is made about it.
        public let waitingOn: String?

        public init(bytes: Int64, installed: Int64 = 0, working: Bool = false,
                    cpu: Double = 0, waitingOn: String? = nil) {
            self.bytes = bytes
            self.installed = installed
            self.working = working
            self.cpu = cpu
            self.waitingOn = waitingOn
        }
    }

    /// The title of a window this process tree has put on screen, if any.
    ///
    /// Wine always has windows: `explorer.exe /desktop` keeps an untitled one
    /// alive for the whole session. So an untitled window means nothing and
    /// only a *named* one counts — a dialogue has a title, a desktop does not.
    /// The one that prompted this was called "Setup", and measured one pixel
    /// square, because /VERYSILENT hides a dialogue without answering it.
    /// Detected by *size*, because the title is not available to us.
    ///
    /// This was written against `kCGWindowName` and worked perfectly in a test
    /// run from a terminal — and never once in the app. Window titles require
    /// Screen Recording permission. The terminal had been granted it long ago
    /// and quietly lent it to the test; Proteus has not, and never should have
    /// to ask for it to install a game. Every title it reads comes back nil,
    /// so the check could not fire, and four rounds of fixes sat behind a
    /// condition that was false by construction.
    ///
    /// Window *bounds* need no permission at all. Measured against a silent
    /// install that works and one that is stuck, on the same machine:
    ///
    ///     working   10 processes   3 windows   0 of 1×1
    ///     stuck     10 processes  12 windows   1 of 1×1
    ///
    /// A window one pixel square is not something a person can see or click.
    /// It exists because the installer created a dialogue and silent mode
    /// collapsed it rather than answering it — which is exactly the condition
    /// worth reporting. (The user/system CPU split was measured too, and is
    /// useless: 42/58 working against 77/23 stuck, the opposite way round from
    /// what one would guess.)
    ///
    /// - Returns: nil when nothing is waiting; otherwise the dialogue's title
    ///   if we happen to be able to read it, or an empty string if not.
    static func suppressedDialogue(ownedBy family: Set<pid_t>) -> String? {
        guard !family.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var found = false
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  family.contains(owner) else { continue }

            let title = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespaces)

            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = bounds["Width"] as? Double ?? 0
            let height = bounds["Height"] as? Double ?? 0

            // Wine gives every process a window for its virtual desktop, and
            // during a silent install that is the *only* thing any of them
            // has. Measured on a working install: three processes, three
            // windows, all 500×500. Measured on a stuck one: a dialogue
            // collapsed to 1×1, plus menu bars at 1512×33.
            //
            // So the desktop is the baseline and anything else is real
            // interface — whether it is a hidden dialogue silent mode squashed
            // or a wizard sitting in plain sight waiting to be clicked.
            let isDesktop = width == Self.wineDesktopSize && height == Self.wineDesktopSize
            guard width > 0, height > 0, !isDesktop else { continue }
            // A title, when the permission happens to be there, makes the
            // message concrete: "asking about Setup" beats "asking something".
            if let title, !title.isEmpty { return title }
            found = true
        }
        return found ? "" : nil
    }

    /// The path with every symlink resolved, the way the kernel reports it.
    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    /// The size of wine's own virtual-desktop window, which every process gets
    /// and which therefore means nothing on its own.
    static let wineDesktopSize: Double = 500

    /// Above this, the installer is considered to be working rather than hung.
    ///
    /// Low on purpose. A single busy thread reads as ~100%, and the number only
    /// has to separate "doing something" from "doing nothing" — an idle,
    /// genuinely wedged process sits near zero, not near ten.
    static let workingCPUThreshold: Double = 8

    /// Combined CPU of a process and everything it spawned.
    static func processTreeCPU(rootPID: pid_t) -> Double {
        snapshot(rootPID: rootPID).cpu
    }

    /// Every process belonging to this install, and their combined CPU.
    ///
    /// Identity is the executable's path, not parentage.
    ///
    /// Walking parents and process groups was the obvious approach and it is
    /// wrong. Wine detaches: the extractor that does all the work ends up with
    /// ppid 1 and a process group of its own, so it is not reachable from the
    /// loader we launched by either route. Everything measured about it —
    /// its CPU, the dialogue it was waiting on — was invisible, which is why
    /// nothing fired.
    ///
    /// `proc_pidpath` reports the real Mach-O behind a process whatever wine
    /// has done to its arguments, and every one of them runs from
    /// `…/SharedSupport/wine/Runtime.app/Contents/MacOS/`. A path inside this
    /// bundle is exact, cheap, and cannot be lost by reparenting.
    static func processes(inBundle bundlePath: String) -> (cpu: Double, pids: Set<pid_t>) {
        // Resolved with `realpath`, and not with `resolvingSymlinksInPath`,
        // which was the first attempt and does not work.
        //
        // `proc_pidpath` always reports the real path — `/private/tmp/…` — and
        // Foundation deliberately leaves `/tmp` alone, treating it as the
        // canonical spelling. So the comparison silently matched nothing, the
        // process list came back empty, and with it the CPU reading and the
        // dialogue check. Caught by a reproduction installed under /tmp.
        let root = Self.realPath(bundlePath)
        let listing = Shell.run("/bin/ps", ["-Ao", "pid=,pcpu="])
        guard listing.exitCode == 0 else { return (0, []) }

        var total: Double = 0
        var found: Set<pid_t> = []
        var buffer = [CChar](repeating: 0, count: 4096)

        for line in listing.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = pid_t(parts[0]), let cpu = Double(parts[1]) else { continue }
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            guard String(cString: buffer).hasPrefix(root) else { continue }
            found.insert(pid)
            total += cpu
        }
        return (total, found)
    }

    /// Kept for the case where there is no bundle to match against.
    static func snapshot(rootPID: pid_t) -> (cpu: Double, pids: Set<pid_t>) {
        let listing = Shell.run("/bin/ps", ["-Ao", "pid=,ppid=,pgid=,pcpu="])
        guard listing.exitCode == 0 else { return (0, []) }

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

        guard let root = table[rootPID] else { return (0, []) }

        var total: Double = 0
        var seen: Set<pid_t> = []
        var queue: [pid_t] = [rootPID]
        for (pid, entry) in table where entry.pgid == root.pgid { queue.append(pid) }

        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted, let entry = table[pid] else { continue }
            total += entry.cpu
            queue.append(contentsOf: children[pid] ?? [])
        }
        return (total, seen)
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
