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

/// Everything Proteus decides rests on reading the executable correctly. If
/// the import table is misread the game gets the wrong graphics translation
/// and fails at startup with a message about Direct3D that means nothing to
/// the person holding it — so this is the layer worth pinning down.
final class PEFileTests: XCTestCase {

    func testReadsA64BitGUIProgram() throws {
        let url = try PEBuilder(bitness: .pe64, subsystem: 2).write()
        let pe = try PEFile(url: url)

        XCTAssertEqual(pe.machine, .amd64)
        XCTAssertEqual(pe.subsystem, .gui)
        XCTAssertFalse(pe.isManagedDotNet)
    }

    func testReadsA32BitConsoleProgram() throws {
        // The data directories sit 16 bytes earlier in PE32. Reading a 32-bit
        // file with the 64-bit offsets finds nothing and reports a program
        // that imports nothing at all — which looks like a valid answer.
        let url = try PEBuilder(bitness: .pe32, subsystem: 3, imports: ["KERNEL32.dll"]).write()
        let pe = try PEFile(url: url)

        XCTAssertEqual(pe.machine, .i386)
        XCTAssertEqual(pe.subsystem, .console)
        XCTAssertEqual(pe.importedDLLs, ["kernel32.dll"])
    }

    func testReadsTheImportTable() throws {
        let url = try PEBuilder(imports: ["d3d11.dll", "XINPUT1_3.dll", "KERNEL32.dll"]).write()
        let pe = try PEFile(url: url)

        XCTAssertEqual(pe.importedDLLs, ["d3d11.dll", "xinput1_3.dll", "kernel32.dll"])
    }

    func testReadsDelayImportsSeparately() throws {
        // A delayed import is still a hard dependency — it just arrives later.
        // Its descriptor is 32 bytes rather than 20, and reading it with the
        // wrong stride yields plausible-looking rubbish rather than an error.
        let url = try PEBuilder(imports: ["KERNEL32.dll"],
                                delayImports: ["d3dx9_43.dll"]).write()
        let pe = try PEFile(url: url)

        XCTAssertEqual(pe.importedDLLs, ["kernel32.dll"])
        XCTAssertEqual(pe.delayImportedDLLs, ["d3dx9_43.dll"])
    }

    func testFindsLibrariesLoadedAtRuntime() throws {
        // The case that motivates the whole layer: a program whose import
        // table mentions no graphics library at all, but which cannot draw a
        // pixel without one. GZDoom is exactly this.
        let url = try PEBuilder(imports: ["KERNEL32.dll"],
                                loosePlainStrings: ["opengl32.dll", "vulkan-1.dll"]).write()
        let pe = try PEFile(url: url)

        XCTAssertFalse(pe.importedDLLs.contains("opengl32.dll"),
                       "the point of this test is that it is NOT imported")

        let latent = pe.dynamicallyLoadedDLLs()
        XCTAssertTrue(latent.contains("opengl32.dll"))
        XCTAssertTrue(latent.contains("vulkan-1.dll"))
    }

    func testFindsASymbolReference() throws {
        let url = try PEBuilder(imports: ["KERNEL32.dll"],
                                loosePlainStrings: ["RegisterRawInputDevices"]).write()
        let pe = try PEFile(url: url)

        XCTAssertTrue(pe.referencesSymbol("RegisterRawInputDevices"))
        XCTAssertFalse(pe.referencesSymbol("SomethingThatIsNotThere"))
    }

    // MARK: - Refusing what is not a program

    func testRejectsAFileThatIsNotAnExecutable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proteus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("readme.txt")
        try Data(repeating: 0x41, count: 4096).write(to: url)

        XCTAssertThrowsError(try PEFile(url: url)) { error in
            XCTAssertEqual(error as? PEFile.ParseError, .notMZ)
        }
    }

    func testRejectsAFileTooSmallToHoldAHeader() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proteus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stub.exe")
        try Data([0x4D, 0x5A]).write(to: url)

        XCTAssertThrowsError(try PEFile(url: url)) { error in
            XCTAssertEqual(error as? PEFile.ParseError, .tooSmall)
        }
    }

    /// A truncated download, a file still being copied, a disc that read badly.
    /// All of them arrive here, and none of them should take the app down.
    func testSurvivesAHeaderThatPointsPastTheEndOfTheFile() throws {
        var data = Data(count: 0x200)
        data.replaceSubrange(0..<2, with: [0x4D, 0x5A])
        data.replaceSubrange(0x3C..<0x40, with: [0xFF, 0xFF, 0xFF, 0x7F])  // absurd e_lfanew

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proteus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("truncated.exe")
        try data.write(to: url)

        XCTAssertThrowsError(try PEFile(url: url))
    }
}
