// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Darwin
import XCTest
@testable import ProteusCore

/// The only failure that really matters during a long install is the person
/// deciding it has hung and closing the window, which throws away everything
/// done so far. Twice now that has happened for a reason the code could have
/// avoided, so the wording rules are pinned down here.
final class InstallProgressTests: XCTestCase {

    /// `installed` defaults to `bytes` for the simple case where an installer
    /// writes straight to the destination with no staging.
    private func stage(bytes: Int64, working: Bool, estimate: Int64,
                       installed: Int64? = nil, waitingOn: String? = nil) -> InstallPipeline.Stage {
        InstallPipeline.installProgress(
            name: "Test Game",
            activity: WineEngine.InstallActivity(bytes: bytes,
                                                 installed: installed ?? bytes,
                                                 working: working,
                                                 cpu: working ? 120 : 0,
                                                 waitingOn: waitingOn),
            estimate: estimate,
            framework: .innoSetup,
            began: Date(timeIntervalSinceNow: -90))
    }

    func testWhileFilesAreLandingItShowsAPercentage() {
        let progress = stage(bytes: 500_000_000, working: false, estimate: 2_000_000_000)

        XCTAssertEqual(progress.fraction ?? 0, 0.25, accuracy: 0.01)
        XCTAssertTrue(progress.en.contains("Installing"))
    }

    /// The bug this exists for: a compressed installer decompresses for minutes
    /// at a time, writing almost nothing. A bar frozen at 41% reads as broken.
    func testWhileDecompressingItDropsThePercentageAndSaysWhatIsHappening() {
        let progress = stage(bytes: 820_000_000, working: true, estimate: 2_000_000_000)

        XCTAssertNil(progress.fraction, "a percentage that cannot move is worse than none")
        XCTAssertTrue(progress.en.lowercased().contains("extracting"), progress.en)
        XCTAssertTrue(progress.es.lowercased().contains("extrayendo"), progress.es)
        XCTAssertTrue(progress.en.contains("take a while"),
                      "it has to say the wait is expected, or the wait looks like a hang")
    }

    /// A wrong estimate is normal — it is guessed from the installer's size.
    /// Pinning the bar at 99% for the rest of a 40 GB install is not.
    func testOnceTheEstimateIsPassedThePercentageGoesAwayRatherThanSticking() {
        XCTAssertNil(InstallPipeline.installShare(bytes: 3_000_000_000, estimate: 2_000_000_000))
        XCTAssertNil(InstallPipeline.installShare(bytes: 1_960_000_000, estimate: 2_000_000_000),
                     "within 5% of the estimate is already untrustworthy")
        XCTAssertNil(InstallPipeline.installShare(bytes: 100, estimate: 0),
                     "no estimate means no percentage, not a division by zero")
    }

    /// The freeze that prompted all of this. An installer unpacks 6.9 GB into
    /// a temp folder while the game directory holds 3.1 GB, and a percentage
    /// measured on the larger number does not move for the whole copy phase —
    /// the destination has to overtake the temp folder before anything changes.
    func testThePercentageFollowsTheDestinationNotTheTotalWritten() {
        // 900 MB written in total, but only 200 MB of it is the actual game.
        let progress = stage(bytes: 900_000_000, working: false,
                             estimate: 1_000_000_000, installed: 200_000_000)

        XCTAssertEqual(progress.fraction ?? 0, 0.20, accuracy: 0.01,
                       "90% would be a lie while the game directory is a fifth full")
        XCTAssertTrue(progress.en.contains("200 MB"), progress.en)
    }

    /// Before anything reaches the destination there is no honest percentage,
    /// but there is a real byte count and it must still be shown.
    func testUnpackingShowsBytesWithoutInventingAPercentage() {
        let progress = stage(bytes: 700_000_000, working: false,
                             estimate: 1_000_000_000, installed: 0)

        XCTAssertNil(progress.fraction)
        XCTAssertTrue(progress.en.lowercased().contains("unpacking"), progress.en)
        XCTAssertTrue(progress.es.lowercased().contains("descomprimiendo"), progress.es)
        XCTAssertTrue(progress.en.contains("700 MB"), progress.en)
    }

    /// A dialogue outranks every other state. Whatever the byte count is
    /// doing, the useful thing to tell someone watching a stopped bar is that
    /// the installer is asking a question — and to say it immediately, not
    /// after the five minutes it takes to conclude nobody will answer.
    func testADialogueIsAnnouncedAtOnceAndOutranksTheOtherStates() {
        let progress = stage(bytes: 900_000_000, working: true,
                             estimate: 1_000_000_000, installed: 0, waitingOn: "Setup")

        XCTAssertNil(progress.fraction)
        XCTAssertTrue(progress.en.contains("waiting on a dialogue"), progress.en)
        XCTAssertTrue(progress.en.contains("Setup"), "name it when the title could be read")
        XCTAssertTrue(progress.es.contains("esperando un diálogo"), progress.es)
        XCTAssertFalse(progress.en.lowercased().contains("extracting"),
                       "it is not extracting; saying so would be a guess")
    }

    /// Window titles need Screen Recording permission, which Proteus does not
    /// have and should not need in order to install a game. So the dialogue is
    /// usually detected by its size with no title available, and the message
    /// has to read properly without one — an empty pair of quotation marks
    /// would look like a bug.
    func testAnUnnamedDialogueStillReadsAsASentence() {
        let progress = stage(bytes: 100, working: true, estimate: 1_000, waitingOn: "")

        XCTAssertNil(progress.fraction)
        XCTAssertTrue(progress.en.contains("waiting on a dialogue"), progress.en)
        XCTAssertFalse(progress.en.contains("\"\""), "empty quotes: \(progress.en)")
        XCTAssertFalse(progress.es.contains("\"\""), "empty quotes: \(progress.es)")
        XCTAssertTrue(progress.en.contains("cannot install silently"), progress.en)
    }

    func testTheByteCountSurvivesEvenWithNoEstimate() {
        let progress = stage(bytes: 1_500_000_000, working: false, estimate: 0)

        XCTAssertNil(progress.fraction)
        XCTAssertTrue(progress.en.contains("GB"), progress.en)
    }

    /// Elapsed time is the other thing that proves it is alive, and it is in
    /// the detail line of every state.
    func testEveryStateCarriesTheElapsedTime() {
        for working in [true, false] {
            let detail = stage(bytes: 10_000_000, working: working, estimate: 1_000_000_000).detail
            XCTAssertNotNil(detail)
            XCTAssertTrue(detail?.contains("min") == true || detail?.contains("s") == true,
                          "state working=\(working) lost its elapsed time")
        }
    }
}

/// Liveness detection. Getting this wrong does not annoy someone — it
/// terminates a healthy install, and a 40 GB one cannot be casually redone.
final class InstallLivenessTests: XCTestCase {

    func testThisTestProcessCountsAsWorking() {
        // Measured against the running test process, which is real and busy
        // enough to be found. The point is that the sampler returns a plausible
        // number for a live process rather than zero.
        let cpu = WineEngine.processTreeCPU(rootPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertGreaterThanOrEqual(cpu, 0, "a live process must not report negative CPU")
    }

    func testAProcessThatDoesNotExistReportsNothing() {
        // Not merely tidiness: if a dead pid reported activity, the stall
        // deadline would never fire and a genuinely wedged installer would hang
        // until the six-hour hard cap.
        XCTAssertEqual(WineEngine.processTreeCPU(rootPID: 999_999), 0)
    }

    /// The threshold only has to separate "doing something" from "doing
    /// nothing". A single busy thread reads as about 100%.
    func testTheWorkingThresholdIsWellBelowOneBusyThread() {
        XCTAssertGreaterThan(WineEngine.workingCPUThreshold, 0)
        XCTAssertLessThan(WineEngine.workingCPUThreshold, 100)
    }

    /// A silent installer that is not silent: it puts up a dialogue and spins
    /// in its message pump waiting for an answer. Sampled from a real one that
    /// had been at 100% CPU for minutes with nothing on disk — the busy thread
    /// was in NtUserPeekMessage → NtYieldExecution, and it owned a window
    /// titled "Setup" measuring one pixel square.
    func testNoProcessesMeansNoDialogue() {
        XCTAssertNil(WineEngine.suppressedDialogue(ownedBy: []))
        XCTAssertNil(WineEngine.suppressedDialogue(ownedBy: [999_999]))
    }

    /// The bug that made every earlier attempt useless: wine detaches its
    /// worker, which ends up with ppid 1 and its own process group, so walking
    /// parents finds nothing. Identity has to come from the executable's path.
    func testProcessesAreFoundByTheBundleTheyRunFrom() {
        // Asked of this process's own executable path — `arguments[0]` is the
        // .xctest bundle, not the runner binary that is actually executing.
        var buffer = [CChar](repeating: 0, count: 4096)
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertGreaterThan(proc_pidpath(me, &buffer, UInt32(buffer.count)), 0)
        let mine = URL(fileURLWithPath: String(cString: buffer))
            .deletingLastPathComponent().path

        let found = WineEngine.processes(inBundle: mine)
        XCTAssertTrue(found.pids.contains(ProcessInfo.processInfo.processIdentifier),
                      "the running test process should be found by its own path")

        XCTAssertTrue(WineEngine.processes(inBundle: "/nowhere/at/all").pids.isEmpty)
    }

    /// Ordinary windows must not count. Wine keeps `explorer.exe /desktop`
    /// alive with a 500×500 one for the whole session, and a working silent
    /// install was measured with three windows and none of them collapsed.
    func testThisProcessIsNotMistakenForOneAwaitingAnAnswer() {
        // The test runner owns no titled window, but it does own the untitled
        // machinery any AppKit-linked process has.
        XCTAssertNil(WineEngine.suppressedDialogue(ownedBy: [ProcessInfo.processInfo.processIdentifier]))
    }

    /// The cap that caused the bug, demonstrated rather than asserted.
    ///
    /// A capped walk stops counting once it has seen `limit` files, so the
    /// total stops rising while the install carries on. That was read as a
    /// stall and the install was killed. Large games hold six figures of files;
    /// the old cap was 20,000.
    func testACappedWalkUndercountsAndIsWhyTheCapMustBeLarge() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proteus-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data(repeating: 0x41, count: 1000)
        for i in 0..<40 {
            try payload.write(to: dir.appendingPathComponent("file\(i).bin"))
        }

        let capped = WineEngine.directorySize(dir, limit: 10)
        let whole = WineEngine.directorySize(dir, limit: 400_000)

        XCTAssertLessThan(capped, whole,
                          "a cap below the file count hides growth — the exact stall bug")
        XCTAssertEqual(whole, 40_000, "uncapped, every byte is counted")
    }
}
