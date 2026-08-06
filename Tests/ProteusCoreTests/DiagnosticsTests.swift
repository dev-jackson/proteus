// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import XCTest
@testable import ProteusCore

/// A log is only useful if a person can read it. Wine's raw output is roughly
/// nine parts MoltenVK reciting its extension inventory to one part the line
/// that says why the game died, and pasting all of it into a bug report helps
/// nobody. These pin down the filtering that makes the difference.
final class LogFilterTests: XCTestCase {

    func testDropsTheVulkanInventory() {
        let raw = """
        VK_KHR_surface
        VK_EXT_debug_utils
        [mvk-info] GPU device: Apple M2
        err:d3d:wined3d_adapter_init failed
        """
        let filtered = GameActions.filterLog(raw, lines: 100)

        XCTAssertTrue(filtered.contains("wined3d_adapter_init"),
                      "the one line that matters must survive")
        XCTAssertFalse(filtered.contains("VK_KHR_surface"))
        XCTAssertFalse(filtered.contains("mvk-info"))
    }

    func testCollapsesLinesThatDifferOnlyInAPointer() {
        // Wine will happily emit the same warning ten thousand times with a
        // different handle each time. Ten thousand lines and one line carry
        // exactly the same information; only one of them can be read.
        let raw = (0..<50).map { "fixme:win:NtUserGetPointerInfo hwnd 0x\($0)0a4 stub" }
            .joined(separator: "\n")
        let filtered = GameActions.filterLog(raw, lines: 100)
        let lines = filtered.split(separator: "\n")

        XCTAssertEqual(lines.count, 2, "one example plus a count of the rest")
        XCTAssertTrue(filtered.contains("49 more"))
    }

    func testKeepsTheMostRecentLines() {
        // The end of a log is where a crash is. Truncating from the wrong end
        // would throw away the only part worth having.
        let raw = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let filtered = GameActions.filterLog(raw, lines: 10)

        XCTAssertTrue(filtered.contains("line 500"))
        XCTAssertFalse(filtered.contains("line 400"))
    }

    func testAnEmptyLogDoesNotProduceRubbish() {
        XCTAssertEqual(GameActions.filterLog("", lines: 100), "")
        XCTAssertEqual(GameActions.filterLog("\n\n   \n", lines: 100), "")
    }
}

/// The renderer choice is the single setting most likely to be wrong, and the
/// one a person is least equipped to judge. Whatever it picks, it has to be
/// able to say what it picked in words that mean something.
final class RendererTests: XCTestCase {

    func testEveryRendererExplainsItselfInBothLanguages() {
        for renderer in [Prescription.Renderer.native, .wined3d, .dxmt, .d3dmetal, .dxvk] {
            XCTAssertFalse(renderer.summaryEN.isEmpty, "\(renderer) has no English summary")
            XCTAssertFalse(renderer.summaryES.isEmpty, "\(renderer) has no Spanish summary")
        }
    }

    func testOnlyNativeMeansNoTranslationIsHappening() {
        XCTAssertFalse(Prescription.Renderer.native.translatesDirectX)
        for renderer in [Prescription.Renderer.wined3d, .dxmt, .d3dmetal, .dxvk] {
            XCTAssertTrue(renderer.translatesDirectX, "\(renderer) does translate DirectX")
        }
    }

    /// The engine toggles live in Info.plist, and exactly one of them may be
    /// on. Two at once is not a worse choice — it is a wrapper that does not
    /// start, and the symptom is a game that opens no window.
    func testAtMostOneEngineToggleIsEverSwitchedOn() {
        for renderer in [Prescription.Renderer.native, .wined3d, .dxmt, .d3dmetal, .dxvk] {
            let on = renderer.plistKeys.filter { $0.value }.count
            XCTAssertLessThanOrEqual(on, 1, "\(renderer) switches on \(on) engines")
        }
    }
}
