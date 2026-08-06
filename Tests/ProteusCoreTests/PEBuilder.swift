// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Builds a real, minimal Windows executable in memory.
///
/// The alternative would be checking a few .exe files into the repository as
/// fixtures, which is how most projects test a binary parser. That is worse in
/// three ways: the files are opaque blobs nobody can inspect in a diff, they
/// come from somewhere with a licence attached, and they can only ever test
/// the cases that happen to exist in them.
///
/// Built here, the input is described in the test that uses it — "a 64-bit GUI
/// program importing d3d11" — and a new case is three lines rather than a
/// hunt for a program that happens to have the right shape.
struct PEBuilder {

    enum Bitness {
        case pe32, pe64
        var magic: UInt16 { self == .pe64 ? 0x20b : 0x10b }
        var machine: UInt16 { self == .pe64 ? 0x8664 : 0x014c }
        /// Where the data directories start, measured from the optional
        /// header. PE32+ widens ImageBase and drops BaseOfData, and the whole
        /// table moves with it.
        var dataDirectoryOffset: Int { self == .pe64 ? 112 : 96 }
    }

    var bitness: Bitness = .pe64
    /// 2 is the Windows GUI subsystem, 3 is the console.
    var subsystem: UInt16 = 2
    var imports: [String] = []
    var delayImports: [String] = []
    /// Loaded with LoadLibrary at runtime: present in the file as a plain
    /// string, absent from every table. The reason a 3D game can look as if it
    /// needs nothing at all.
    var loosePlainStrings: [String] = []

    // The layout is fixed rather than computed, because a parser that only
    // works on tightly packed files is not being tested honestly.
    private let peOffset = 0x80
    private let sectionRVA: UInt32 = 0x1000
    private let sectionFileOffset: UInt32 = 0x400

    func build() -> Data {
        var out = Data(count: Int(sectionFileOffset))

        // ---- DOS header: enough of one to be recognised and point onwards.
        out.replaceSubrange(0..<2, with: [0x4D, 0x5A])            // "MZ"
        out.write(u32: UInt32(peOffset), at: 0x3C)

        // ---- The section's contents, assembled first so the tables inside it
        //      can be given real addresses.
        var section = Data()
        let importTable = layOutImportTable(&section, imports, stride: 20, nameOffset: 12)
        let delayTable = layOutImportTable(&section, delayImports, stride: 32, nameOffset: 12)
        for text in loosePlainStrings {
            section.append(contentsOf: Array(text.utf8) + [0])
        }
        while section.count % 0x200 != 0 { section.append(0) }

        // ---- PE signature and COFF header.
        let optionalHeaderSize = bitness.dataDirectoryOffset + 16 * 8
        out.write(u32: 0x0000_4550, at: peOffset)                 // "PE\0\0"
        let coff = peOffset + 4
        out.write(u16: bitness.machine, at: coff)
        out.write(u16: 1, at: coff + 2)                           // one section
        out.write(u16: UInt16(optionalHeaderSize), at: coff + 16)
        out.write(u16: 0x0002, at: coff + 18)                     // EXECUTABLE_IMAGE

        // ---- Optional header. Only the fields the parser reads are set; the
        //      rest stay zero, which is also what a stripped linker emits.
        let opt = coff + 20
        out.write(u16: bitness.magic, at: opt)
        out.write(u16: subsystem, at: opt + 68)

        let dirs = opt + bitness.dataDirectoryOffset
        if let table = importTable {
            out.write(u32: table.rva, at: dirs + 1 * 8)
            out.write(u32: table.size, at: dirs + 1 * 8 + 4)
        }
        if let table = delayTable {
            out.write(u32: table.rva, at: dirs + 13 * 8)
            out.write(u32: table.size, at: dirs + 13 * 8 + 4)
        }

        // ---- Section table.
        let sec = opt + optionalHeaderSize
        out.replaceSubrange(sec..<(sec + 5), with: Array(".text".utf8))
        out.write(u32: UInt32(section.count), at: sec + 8)        // VirtualSize
        out.write(u32: sectionRVA, at: sec + 12)
        out.write(u32: UInt32(section.count), at: sec + 16)       // SizeOfRawData
        out.write(u32: sectionFileOffset, at: sec + 20)

        out.append(section)
        return out
    }

    /// Appends one import descriptor array plus its name strings, and returns
    /// where it ended up. Nil when there is nothing to import — a directory
    /// entry of zero is how a file says "none", and pointing at an empty table
    /// instead would be a different thing.
    private func layOutImportTable(_ section: inout Data, _ names: [String],
                                   stride: Int, nameOffset: Int) -> (rva: UInt32, size: UInt32)? {
        guard !names.isEmpty else { return nil }

        let tableStart = section.count
        // Descriptors, then a zeroed one to terminate: the count is not stored
        // anywhere, so the terminator is the only thing that ends the walk.
        let tableSize = stride * (names.count + 1)
        section.append(Data(count: tableSize))

        for (index, name) in names.enumerated() {
            let stringOffset = section.count
            section.append(contentsOf: Array(name.utf8) + [0])
            let rva = sectionRVA + UInt32(stringOffset)
            section.write(u32: rva, at: tableStart + index * stride + nameOffset)
        }

        return (sectionRVA + UInt32(tableStart), UInt32(tableSize))
    }

    /// Writes the file to a temporary .exe and hands back its URL.
    func write(named name: String = "game.exe") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proteus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try build().write(to: url)
        return url
    }
}

private extension Data {
    mutating func write(u16 value: UInt16, at offset: Int) {
        replaceSubrange(offset..<(offset + 2), with: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func write(u32 value: UInt32, at offset: Int) {
        replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }
}
