// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import CoreGraphics
import XCTest
@testable import ProteusCore

/// The one case the unit tests cannot reach: a real installer, really waiting.
///
/// Everything about this failure was learned from installs that could not be
/// repeated on demand — fourteen hours wasted, twice, on a diagnosis that was
/// wrong. So it is reproduced here deliberately, with a free game, by running
/// an installer *without* its silent flags. That is precisely the condition
/// silent mode produces by accident: a window nobody can answer.
///
/// Off by default. It drives real Wine and takes a couple of minutes:
///
///     PROTEUS_INTEGRATION=1 PROTEUS_WRAPPER=/Applications/OpenTTD.app swift test
///
final class StuckInstallerIntegrationTests: XCTestCase {

    private func requirements() throws -> (WineEngine, URL) {
        guard ProcessInfo.processInfo.environment["PROTEUS_INTEGRATION"] == "1" else {
            throw XCTSkip("set PROTEUS_INTEGRATION=1 to run this against real Wine")
        }
        guard let path = ProcessInfo.processInfo.environment["PROTEUS_WRAPPER"] else {
            throw XCTSkip("set PROTEUS_WRAPPER to a built game bundle")
        }
        let wrapper = Wrapper(bundle: URL(fileURLWithPath: path))
        guard FileManager.default.isExecutableFile(atPath: wrapper.wineBinary.path) else {
            throw XCTSkip("\(path) has no Wine engine in it")
        }

        let installer = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("test-games/openttd-installer.exe")
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw XCTSkip("test-games/openttd-installer.exe is not here")
        }
        return (WineEngine(wrapper: wrapper), installer)
    }

    /// Points the real detector at a bundle that is installing right now, and
    /// says what it sees. Used to confirm against a live case rather than a
    /// contrived one:
    ///
    ///     PROTEUS_INTEGRATION=1 PROTEUS_PROBE=/Applications/Something.app \
    ///       swift test --filter testWhatTheDetectorSeesRightNow
    func testWhatTheDetectorSeesRightNow() throws {
        guard ProcessInfo.processInfo.environment["PROTEUS_INTEGRATION"] == "1",
              let path = ProcessInfo.processInfo.environment["PROTEUS_PROBE"] else {
            throw XCTSkip("set PROTEUS_INTEGRATION=1 and PROTEUS_PROBE=<bundle>")
        }
        let family = WineEngine.processes(inBundle: path)
        let dialogue = WineEngine.suppressedDialogue(ownedBy: family.pids)
        print("""

        ── live probe ───────────────────────────────
          bundle     \(path)
          processes  \(family.pids.count)
          cpu        \(Int(family.cpu))%
          dialogue   \(dialogue.map { $0.isEmpty ? "yes (title unavailable)" : "yes: \($0)" } ?? "none")
        ─────────────────────────────────────────────
        """)
        XCTAssertFalse(family.pids.isEmpty, "nothing is running from \(path)")
    }

    /// Run an installer with no silent flags, and it puts up its wizard and
    /// waits. Three things then have to happen, and each one was broken at
    /// some point:
    ///
    /// 1. The dialogue is noticed at all. Walking parents and process groups
    ///    missed it entirely, because wine reparents its worker to init.
    /// 2. The wait ends. It is supposed to give up after `promptAfter`.
    /// 3. **The call returns.** It did not — `readToEnd()` waited on a pipe
    ///    the detached child still held open, so the run wedged *after*
    ///    correctly deciding to stop, and sat there for fourteen hours.
    func testAnInstallerWaitingOnADialogueIsNoticedAndTheRunEnds() throws {
        let (engine, installer) = try requirements()

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proteus-stuck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var sawDialogueWhileRunning: String?
        var geometryThatTriggeredIt: [String] = []
        let began = Date()

        // 45 seconds rather than the shipping five minutes: the behaviour is
        // identical and a test that takes five minutes gets skipped.
        let result = try engine.runWatchingProgress(
            [installer.path],
            destination: scratch,
            watching: [scratch],
            stallFor: 600,
            promptAfter: 45,
            hardCap: 240) { activity in
                if sawDialogueWhileRunning == nil { sawDialogueWhileRunning = activity.waitingOn }
                // Recorded so the *reason* is visible, not inferred. The title
                // is only read once a window has already failed the desktop
                // test, so what is listed here is what actually fired.
                guard geometryThatTriggeredIt.isEmpty, activity.waitingOn != nil else { return }
                let family = WineEngine.processes(inBundle: engine.wrapper.bundle.path).pids
                let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                for window in windows {
                    guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                          family.contains(owner) else { continue }
                    let b = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
                    let w = b["Width"] as? Double ?? 0, h = b["Height"] as? Double ?? 0
                    guard w > 0, h > 0 else { continue }
                    let desktop = w == WineEngine.wineDesktopSize && h == WineEngine.wineDesktopSize
                    geometryThatTriggeredIt.append("\(Int(w))x\(Int(h))\(desktop ? " (desktop, ignored)" : "  ← triggered")")
                }
            }

        let elapsed = Date().timeIntervalSince(began)

        // 3, the one that cost fourteen hours: it came back at all.
        XCTAssertLessThan(elapsed, 200,
                          "the call did not return promptly — the pipe drain is blocking again")

        // The detection must not depend on the window's title. Titles need
        // Screen Recording permission; a terminal has it and lends it to this
        // test, while Proteus does not and never asks. Four rounds of fixes
        // passed here and could not possibly work in the app because of it.
        // So: assert it is found by geometry, exactly as the app must find it.
        XCTAssertNotNil(sawDialogueWhileRunning,
                        "not detected at all")

        // 1 and 2.
        XCTAssertNotNil(result.waitingOn,
                        "an installer sitting on its own wizard was not recognised as waiting")
        XCTAssertNotNil(sawDialogueWhileRunning,
                        "the dialogue must be reported through progress while it is happening, "
                        + "not only in the final result")

        // Nothing of ours may outlive the call. This is what makes a second
        // attempt possible, and what stops two installs fighting over a prefix.
        let survivors = WineEngine.processes(inBundle: engine.wrapper.bundle.path).pids
        XCTAssertTrue(survivors.isEmpty, "left \(survivors.count) wine process(es) running")

        print("""

        ── stuck-installer integration ──────────────
          returned after   \(Int(elapsed))s
          waiting on       \(result.waitingOn ?? "—")
          seen while live  \(sawDialogueWhileRunning ?? "—")
          survivors        \(survivors.count)
          windows seen     \(geometryThatTriggeredIt.joined(separator: "\n                           "))
        ─────────────────────────────────────────────
        """)
    }
}

/// "You never see the installer" — the report that mattered most, and the one
/// a passing test suite had said nothing about.
///
///     PROTEUS_INTEGRATION=1 PROTEUS_WRAPPER=/Applications/OpenTTD.app \
///       swift test --filter testTheInstallerActuallyAppears
final class InteractiveInstallerAppearsTests: XCTestCase {

    func testTheInstallerActuallyAppears() throws {
        guard ProcessInfo.processInfo.environment["PROTEUS_INTEGRATION"] == "1",
              let path = ProcessInfo.processInfo.environment["PROTEUS_WRAPPER"] else {
            throw XCTSkip("set PROTEUS_INTEGRATION=1 and PROTEUS_WRAPPER=<bundle>")
        }
        let installer = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("test-games/stuck-installer.exe")
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw XCTSkip("build test-games/stuck-installer.exe first")
        }

        let app = URL(fileURLWithPath: path)
        let pipeline = InstallPipeline(installRoot: app.deletingLastPathComponent())

        // The installer lives outside the wrapper, which is the whole point:
        // `windowsPath` cannot name it, and the old guard returned instead of
        // launching anything at all.
        XCTAssertNil(Wrapper(bundle: app).windowsPath(for: installer),
                     "the installer must be outside the wrapper for this to mean anything")

        // It blocks until the person closes it, so it runs alongside.
        Thread.detachNewThread {
            try? pipeline.runInstallerInteractively(app: app, installer: installer)
        }
        defer {
            for pid in WineEngine.processes(inBundle: app.path).pids { kill(pid, SIGKILL) }
        }

        var seen: [String] = []
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, seen.isEmpty {
            Thread.sleep(forTimeInterval: 3)
            let family = WineEngine.processes(inBundle: app.path).pids
            guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
            else { continue }
            for window in windows {
                guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                      family.contains(owner) else { continue }
                let b = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let w = b["Width"] as? Double ?? 0, h = b["Height"] as? Double ?? 0
                guard w > 0, h > 0,
                      !(w == WineEngine.wineDesktopSize && h == WineEngine.wineDesktopSize) else { continue }
                seen.append("\(Int(w))x\(Int(h))")
            }
        }

        print("""

        ── does the installer appear? ───────────────
          windows       \(seen.isEmpty ? "none" : seen.joined(separator: ", "))
        ─────────────────────────────────────────────
        """)
        XCTAssertFalse(seen.isEmpty,
                       "no window appeared — the interactive run is a no-op again")

        // The window is torn down the moment this returns, which is right for
        // a test and useless for a person trying to see it. PROTEUS_HOLD keeps
        // it on screen long enough to look at, or to photograph.
        if let hold = ProcessInfo.processInfo.environment["PROTEUS_HOLD"].flatMap(Double.init) {
            Thread.sleep(forTimeInterval: hold)
        }
    }
}
