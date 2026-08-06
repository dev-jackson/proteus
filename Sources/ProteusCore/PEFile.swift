import Foundation

/// Minimal PE/COFF reader. We only need four things out of a Windows binary:
/// what CPU it wants, whether it draws a window, which DLLs it imports
/// (that is the dependency list nobody else bothers to read), and its icon.
public struct PEFile: Sendable {
    public enum Machine: UInt16, Sendable {
        case i386 = 0x014c
        case amd64 = 0x8664
        case arm64 = 0xaa64

        public var label: String {
            switch self {
            case .i386: return "32-bit (x86)"
            case .amd64: return "64-bit (x64)"
            case .arm64: return "ARM64"
            }
        }
    }

    public enum Subsystem: UInt16, Sendable {
        case native = 1
        case gui = 2
        case console = 3
        case other = 0
    }

    public let url: URL
    public let machine: Machine
    public let subsystem: Subsystem
    /// Lowercased DLL names from the import directory, e.g. `d3d9.dll`.
    public let importedDLLs: [String]
    /// Strings from the VERSIONINFO resource (ProductName, FileDescription…).
    public let versionStrings: [String: String]
    /// Whether the binary carries at least one icon group.
    public let hasIcon: Bool
    /// Runtime assemblies the embedded manifest asks Windows to load.
    ///
    /// This is the strongest dependency signal a binary carries and almost
    /// nobody reads it. An import of `msvcp90.dll` leaves the service pack to
    /// guesswork; the manifest says
    /// `Microsoft.VC90.CRT version="9.0.21022.8"` outright. It also states
    /// whether the program demands administrator rights and whether it
    /// understands high-DPI displays, neither of which appears anywhere else.
    public let manifestAssemblies: [String]
    public let requiresAdministrator: Bool
    public let dpiAware: Bool

    /// DLLs the binary delay-loads: declared like imports, but only resolved
    /// when first called. Games routinely delay-load Direct3D so they can fall
    /// back if it is missing, which hides the dependency from a naive reader.
    public let delayImportedDLLs: [String]

    /// True when the binary is actually managed code. Native MSVC programs
    /// routinely carry an `mscoree.dll` import stub they never use, so the
    /// import table alone reports .NET for plain C++ games; the CLR header is
    /// the only honest signal.
    public let isManagedDotNet: Bool

    let data: Data
    let sections: [Section]
    let resourceDirRVA: UInt32
    let resourceDirSize: UInt32

    struct Section: Sendable {
        let name: String
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawPointer: UInt32
        let rawSize: UInt32
    }

    public enum ParseError: Error, CustomStringConvertible {
        case tooSmall
        case notMZ
        case notPE
        case unsupportedMachine(UInt16)

        public var description: String {
            switch self {
            case .tooSmall: return "file too small to be a Windows executable"
            case .notMZ: return "not a Windows executable (missing MZ header)"
            case .notPE: return "not a Windows executable (missing PE header)"
            case .unsupportedMachine(let m):
                return String(format: "unknown CPU architecture 0x%04x", m)
            }
        }
    }

    public init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.data = data
        guard data.count > 0x40 else { throw ParseError.tooSmall }
        guard data.u16(0) == 0x5A4D else { throw ParseError.notMZ }

        let peOffset = Int(data.u32(0x3C))
        guard peOffset > 0, data.count > peOffset + 24 else { throw ParseError.notPE }
        guard data.u32(peOffset) == 0x0000_4550 else { throw ParseError.notPE }

        let coff = peOffset + 4
        let rawMachine = data.u16(coff)
        guard let machine = Machine(rawValue: rawMachine) else {
            throw ParseError.unsupportedMachine(rawMachine)
        }
        self.machine = machine

        let sectionCount = Int(data.u16(coff + 2))
        let optHeaderSize = Int(data.u16(coff + 16))
        let opt = coff + 20
        guard data.count > opt + 2 else { throw ParseError.tooSmall }

        let magic = data.u16(opt)
        let isPE32Plus = magic == 0x20b
        // Subsystem and the data-directory table sit at different offsets in
        // PE32 vs PE32+ because ImageBase changes width.
        let subsystemOffset = opt + 68
        self.subsystem = Subsystem(rawValue: data.u16(subsystemOffset)) ?? .other

        let dataDirOffset = opt + (isPE32Plus ? 112 : 96)
        func directory(_ index: Int) -> (rva: UInt32, size: UInt32) {
            let base = dataDirOffset + index * 8
            guard data.count > base + 8 else { return (0, 0) }
            return (data.u32(base), data.u32(base + 4))
        }
        let importDir = directory(1)
        let resourceDir = directory(2)
        let delayImportDir = directory(13)
        // Data directory 14 is the CLR runtime header; present only for .NET.
        self.isManagedDotNet = directory(14).rva != 0
        self.resourceDirRVA = resourceDir.rva
        self.resourceDirSize = resourceDir.size

        // Section table follows the optional header.
        var sections: [Section] = []
        let sectionBase = opt + optHeaderSize
        for i in 0..<sectionCount {
            let s = sectionBase + i * 40
            guard data.count > s + 40 else { break }
            let nameBytes = data.subdata(in: s..<(s + 8))
            let name = String(bytes: nameBytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
            sections.append(Section(name: name,
                                    virtualAddress: data.u32(s + 12),
                                    virtualSize: data.u32(s + 8),
                                    rawPointer: data.u32(s + 20),
                                    rawSize: data.u32(s + 16)))
        }
        self.sections = sections

        self.importedDLLs = PEFile.readImports(data: data, sections: sections, dir: importDir)
        // The delay-import descriptor is 32 bytes with the DLL name at +12,
        // laid out closely enough to the normal one to share the reader.
        self.delayImportedDLLs = PEFile.readImports(data: data, sections: sections,
                                                    dir: delayImportDir, stride: 32, nameOffset: 12)
        let (version, icon) = PEFile.readResourceSummary(data: data, sections: sections, dir: resourceDir)
        self.versionStrings = version
        self.hasIcon = icon

        let manifest = PEFile.readManifest(data: data, sections: sections, dir: resourceDir)
        self.manifestAssemblies = PEFile.assemblies(in: manifest)
        self.requiresAdministrator = manifest.contains("requireAdministrator")
        self.dpiAware = manifest.lowercased().contains("<dpiaware>true")
            || manifest.lowercased().contains("permonitor")
    }

    // MARK: - RVA mapping

    func fileOffset(forRVA rva: UInt32) -> Int? {
        PEFile.fileOffset(forRVA: rva, sections: sections, count: data.count)
    }

    static func fileOffset(forRVA rva: UInt32, sections: [Section], count: Int) -> Int? {
        for s in sections {
            let size = max(s.virtualSize, s.rawSize)
            if rva >= s.virtualAddress && rva < s.virtualAddress &+ size {
                let offset = Int(s.rawPointer) + Int(rva - s.virtualAddress)
                return offset < count ? offset : nil
            }
        }
        return nil
    }

    // MARK: - Imports

    private static func readImports(data: Data, sections: [Section], dir: (rva: UInt32, size: UInt32),
                                    stride: Int = 20, nameOffset: Int = 12) -> [String] {
        guard dir.rva != 0,
              var cursor = fileOffset(forRVA: dir.rva, sections: sections, count: data.count)
        else { return [] }

        var names: [String] = []
        var seen = Set<String>()
        // IMAGE_IMPORT_DESCRIPTOR is 20 bytes, its delay-load cousin 32; both
        // end on an all-zero entry and hold the DLL name as an RVA.
        while cursor + stride <= data.count, names.count < 512 {
            let nameRVA = data.u32(cursor + nameOffset)
            let originalFirstThunk = data.u32(cursor)
            let firstThunk = data.u32(cursor + stride - 4)
            if nameRVA == 0 && originalFirstThunk == 0 && firstThunk == 0 { break }
            if nameRVA != 0, let nameOffset = fileOffset(forRVA: nameRVA, sections: sections, count: data.count),
               let name = data.cString(at: nameOffset) {
                let lower = name.lowercased()
                if !lower.isEmpty, seen.insert(lower).inserted { names.append(lower) }
            }
            cursor += stride
        }
        return names
    }

    /// The RT_MANIFEST resource, as text.
    static func readManifest(data: Data, sections: [Section], dir: (rva: UInt32, size: UInt32)) -> String {
        guard dir.rva != 0,
              let root = fileOffset(forRVA: dir.rva, sections: sections, count: data.count)
        else { return "" }

        for typeEntry in resourceEntries(data: data, at: root)
        where typeEntry.id == 24 && typeEntry.isDirectory {          // RT_MANIFEST
            for nameEntry in resourceEntries(data: data, at: root + Int(typeEntry.offset))
            where nameEntry.isDirectory {
                for langEntry in resourceEntries(data: data, at: root + Int(nameEntry.offset))
                where !langEntry.isDirectory {
                    let entry = root + Int(langEntry.offset)
                    guard entry + 8 <= data.count else { continue }
                    guard let offset = fileOffset(forRVA: data.u32(entry),
                                                  sections: sections, count: data.count) else { continue }
                    let size = Int(data.u32(entry + 4))
                    guard size > 0, offset + size <= data.count else { continue }
                    return String(decoding: data.subdata(in: offset..<(offset + size)), as: UTF8.self)
                }
            }
        }
        return ""
    }

    /// Assembly names from `<dependentAssembly><assemblyIdentity name="…">`.
    static func assemblies(in manifest: String) -> [String] {
        guard !manifest.isEmpty else { return [] }
        var found: [String] = []
        var seen = Set<String>()
        var search = manifest[...]
        while let nameRange = search.range(of: "name=\"") {
            let rest = search[nameRange.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { break }
            let value = String(rest[rest.startIndex..<close])
            // Only the Microsoft runtime assemblies matter here; the manifest
            // also names the application itself and its controls.
            if value.hasPrefix("Microsoft."), seen.insert(value).inserted {
                found.append(value)
            }
            search = rest[close...]
        }
        return found
    }

    // MARK: - Resources

    /// Walks the resource tree once to answer "is there an icon?" and to pull
    /// the VERSIONINFO strings we use for naming the wrapper.
    private static func readResourceSummary(data: Data, sections: [Section], dir: (rva: UInt32, size: UInt32)) -> ([String: String], Bool) {
        guard dir.rva != 0,
              let root = fileOffset(forRVA: dir.rva, sections: sections, count: data.count)
        else { return ([:], false) }

        var hasIcon = false
        var version: [String: String] = [:]

        for entry in resourceEntries(data: data, at: root) {
            guard entry.isDirectory else { continue }
            switch entry.id {
            case 14: // RT_GROUP_ICON
                hasIcon = true
            case 16: // RT_VERSION
                let langDirs = resourceEntries(data: data, at: root + Int(entry.offset))
                for lang in langDirs where lang.isDirectory {
                    let leaves = resourceEntries(data: data, at: root + Int(lang.offset))
                    for leaf in leaves where !leaf.isDirectory {
                        let dataEntry = root + Int(leaf.offset)
                        guard dataEntry + 8 <= data.count else { continue }
                        let rva = data.u32(dataEntry)
                        let size = Int(data.u32(dataEntry + 4))
                        guard let off = fileOffset(forRVA: rva, sections: sections, count: data.count),
                              off + size <= data.count, size > 0 else { continue }
                        version = parseVersionInfo(data.subdata(in: off..<(off + size)))
                    }
                }
            default:
                break
            }
        }
        return (version, hasIcon)
    }

    struct ResourceEntry {
        let id: UInt32
        let isDirectory: Bool
        let offset: UInt32
    }

    static func resourceEntries(data: Data, at offset: Int) -> [ResourceEntry] {
        guard offset + 16 <= data.count else { return [] }
        let namedCount = Int(data.u16(offset + 12))
        let idCount = Int(data.u16(offset + 14))
        var out: [ResourceEntry] = []
        let total = namedCount + idCount
        guard total < 4096 else { return [] }
        for i in 0..<total {
            let e = offset + 16 + i * 8
            guard e + 8 <= data.count else { break }
            let nameField = data.u32(e)
            let offsetField = data.u32(e + 4)
            out.append(ResourceEntry(id: nameField & 0x7FFF_FFFF,
                                     isDirectory: offsetField & 0x8000_0000 != 0,
                                     offset: offsetField & 0x7FFF_FFFF))
        }
        return out
    }

    /// VERSIONINFO is a nest of aligned UTF-16 blocks. Rather than model it
    /// exactly, harvest the key/value string pairs out of the StringFileInfo
    /// region — that is all we want and it survives malformed producers.
    static func parseVersionInfo(_ blob: Data) -> [String: String] {
        var strings: [String] = []
        var i = 0
        let bytes = [UInt8](blob)
        while i + 1 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 { i += 2; continue }
            var j = i
            var units: [UInt16] = []
            while j + 1 < bytes.count {
                let unit = UInt16(bytes[j]) | (UInt16(bytes[j + 1]) << 8)
                if unit == 0 { break }
                if unit < 0x20 && unit != 0x09 { units.removeAll(); break }
                units.append(unit)
                j += 2
            }
            if units.count >= 2, let s = String(utf16CodeUnits: units, count: units.count) as String? {
                strings.append(s)
            }
            i = max(j + 2, i + 2)
        }

        // Keys we care about are immediately followed by their value.
        let wanted: Set<String> = ["ProductName", "FileDescription", "CompanyName",
                                   "ProductVersion", "FileVersion", "InternalName",
                                   "OriginalFilename"]
        var out: [String: String] = [:]
        for (index, s) in strings.enumerated() where wanted.contains(s) {
            if index + 1 < strings.count {
                let value = strings[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !wanted.contains(value) { out[s] = value }
            }
        }
        return out
    }

    /// DLL names that appear as literal strings in the binary but are not in
    /// the import table — i.e. libraries the game loads with `LoadLibrary` at
    /// run time.
    ///
    /// This matters more than it sounds. Every modern engine picks its
    /// renderer at startup: GZDoom imports neither `opengl32.dll` nor
    /// `vulkan-1.dll`, yet cannot draw a pixel without one of them. Reading
    /// only the import table would report "needs nothing" for a 3D game.
    public func dynamicallyLoadedDLLs(scanLimit: Int = 96 * 1024 * 1024) -> Set<String> {
        let imported = Set(importedDLLs)
        var found = Set<String>()
        let bytes = data.prefix(scanLimit)
        let suffix: [UInt8] = Array(".dll".utf8)

        // Walk the file looking for ASCII runs that end in ".dll". Names are
        // short and printable, so a small state machine beats a regex here.
        var current: [UInt8] = []
        current.reserveCapacity(64)
        var wideRun: [UInt8] = []

        func consider(_ raw: [UInt8]) {
            guard raw.count > 4, raw.count < 64 else { return }
            let lower = raw.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            guard lower.suffix(4).elementsEqual(suffix) else { return }
            guard let name = String(bytes: lower, encoding: .utf8) else { return }
            // Reject anything with a path separator or space: those are format
            // strings and log lines, not library names.
            guard !name.contains("/"), !name.contains("\\"), !name.contains(" ") else { return }
            if !imported.contains(name) { found.insert(name) }
        }

        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte >= 0x20 && byte < 0x7F {
                current.append(byte)
                if current.count > 128 { current.removeAll(keepingCapacity: true) }
            } else {
                if byte == 0 {
                    // UTF-16LE strings look like 'd',0,'3',0,… — reassemble the
                    // odd bytes so wide-character names are seen too.
                    if let last = current.last, current.count == 1 {
                        wideRun.append(last)
                        current.removeAll(keepingCapacity: true)
                        index = bytes.index(after: index)
                        continue
                    }
                }
                if !wideRun.isEmpty {
                    consider(wideRun)
                    wideRun.removeAll(keepingCapacity: true)
                }
                consider(current)
                current.removeAll(keepingCapacity: true)
            }
            index = bytes.index(after: index)
        }
        consider(current)
        consider(wideRun)
        return found
    }

    /// Whether an exported-function name appears anywhere in the binary.
    ///
    /// Used for APIs that live inside a DLL the game imports anyway — raw mouse
    /// input comes from `user32.dll`, which every Windows program links, so the
    /// DLL name proves nothing and the symbol name proves everything.
    public func referencesSymbol(_ symbol: String, scanLimit: Int = 96 * 1024 * 1024) -> Bool {
        let needle = Data(symbol.utf8)
        return data.prefix(scanLimit).range(of: needle) != nil
    }

    /// Best human name for this binary, or nil if the file says nothing useful.
    public var declaredName: String? {
        for key in ["ProductName", "FileDescription", "InternalName"] {
            if let v = versionStrings[key], v.count > 1, !v.lowercased().hasSuffix(".exe") {
                return v
            }
        }
        return nil
    }
}

// MARK: - Little-endian reads

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var v: UInt32 = 0
        for i in (0..<4).reversed() {
            v = (v << 8) | UInt32(self[startIndex + offset + i])
        }
        return v
    }

    func cString(at offset: Int) -> String? {
        guard offset >= 0, offset < count else { return nil }
        var bytes: [UInt8] = []
        var i = startIndex + offset
        while i < endIndex, self[i] != 0, bytes.count < 512 {
            bytes.append(self[i])
            i += 1
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
