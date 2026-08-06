import Foundation

/// Whatever the user dropped on the window, normalised into "a directory that
/// contains Windows files" plus a verdict about what to do with it.
public struct GameSource: Sendable {
    public enum Kind: Sendable {
        case portable        // folder or archive that already contains the game
        case installer       // an installer we must run inside the prefix first
        case disc            // mounted ISO/DMG, may contain either of the above
    }

    public let kind: Kind
    public let root: URL                 // directory holding the Windows files
    public let mainExecutable: URL       // what to run: the game, or the installer
    public let candidateExecutables: [URL]
    public let suggestedName: String
    /// Set when we mounted something and must unmount it afterwards.
    public let mountedVolume: URL?
    /// `kind` describes where the game came from, which is what the user sees.
    /// This says what we have to *do* — a disc may hold an installer or may
    /// just hold the game, and those are different jobs.
    public let needsInstaller: Bool

    public enum SourceError: Error, CustomStringConvertible {
        case noExecutable(String)
        case unreadable(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .noExecutable(let p): return "no Windows program found in \(p)"
            case .unreadable(let p): return "could not read \(p)"
            case .unsupported(let p): return "unsupported file type: \(p)"
            }
        }
    }
}

public struct SourceScanner {
    let fm = FileManager.default
    let workDir: URL

    public init(workDir: URL) {
        self.workDir = workDir
    }

    /// Filenames that are never the game, no matter how prominent they look.
    static let noiseExeNames: Set<String> = [
        "unins000.exe", "uninstall.exe", "uninstaller.exe", "unins001.exe",
        "vcredist_x86.exe", "vcredist_x64.exe", "vcredist.exe",
        "dxsetup.exe", "dxwebsetup.exe", "directx.exe",
        "dotnetfx.exe", "ndp452-kb2901907-x86-x64-allos-enu.exe",
        "oalinst.exe", "physx-9.13.0604-systemsoftware.exe",
        "crashreporter.exe", "crashsender.exe", "bugreport.exe",
        "crashpad_handler.exe", "crashhandler.exe", "breakpadinjector.exe",
        "autorun.exe", "setup_1.exe", "updater.exe", "update.exe",
        "cleanup.exe", "config.exe", "settings.exe", "unitycrashhandler64.exe",
        "unitycrashhandler32.exe",
    ]

    static let noisePathFragments = [
        "/redist", "/redistributable", "/_commonredist", "/directx", "/vcredist",
        "/support/", "/tools/", "/uninstall", "/crashreport", "/uninst",
    ]

    public func scan(_ input: URL) throws -> GameSource {
        let ext = input.pathExtension.lowercased()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else {
            throw GameSource.SourceError.unreadable(input.path)
        }

        if isDir.boolValue {
            return try classify(root: input, mounted: nil, displayName: input.deletingPathExtension().lastPathComponent)
        }

        switch ext {
        case "iso", "dmg", "cdr", "img":
            let volume = try DiscMounter.mount(input)
            return try classify(root: volume, mounted: volume,
                                displayName: input.deletingPathExtension().lastPathComponent)
        case "zip", "7z", "rar":
            let extracted = try Archive.extract(input, into: workDir)
            return try classify(root: extracted, mounted: nil,
                                displayName: input.deletingPathExtension().lastPathComponent)
        case "exe", "msi":
            return try classify(root: input.deletingLastPathComponent(), mounted: nil,
                                displayName: input.deletingPathExtension().lastPathComponent,
                                forcedMain: input)
        default:
            throw GameSource.SourceError.unsupported(input.lastPathComponent)
        }
    }

    /// Decide what a directory of Windows files actually is.
    func classify(root: URL, mounted: URL?, displayName: String, forcedMain: URL? = nil) throws -> GameSource {
        // A disc or archive often wraps everything in one folder; descend
        // through single-child directories so heuristics see the real root.
        let effectiveRoot = forcedMain == nil ? descendSingleChild(root) : root
        // "cavestory.zip" unpacks to a folder called "CaveStory"; the inner
        // name is the one the author chose, so it wins as the fallback.
        var displayName = displayName
        if effectiveRoot != root, Naming.isMostlyLatin(effectiveRoot.lastPathComponent) {
            displayName = effectiveRoot.lastPathComponent
        }

        let exes = try findExecutables(in: effectiveRoot)
        guard !exes.isEmpty || forcedMain != nil else {
            throw GameSource.SourceError.noExecutable(root.path)
        }

        if let forced = forcedMain {
            let kind: GameSource.Kind = InstallerDetector.isInstaller(forced) ? .installer : .portable
            // The user pointed at one file. Whatever else happens to share its
            // folder — a Downloads directory holds anything — is not a candidate.
            return GameSource(kind: kind,
                              root: effectiveRoot,
                              mainExecutable: forced,
                              candidateExecutables: [forced],
                              suggestedName: bestName(for: forced, fallback: displayName),
                              mountedVolume: mounted,
                              needsInstaller: kind == .installer)
        }

        // Discs and archives most often want their installer run.
        if let installer = pickInstaller(from: exes, root: effectiveRoot) {
            return GameSource(kind: mounted != nil ? .disc : .installer,
                              root: effectiveRoot,
                              mainExecutable: installer,
                              candidateExecutables: exes,
                              suggestedName: discName(root: effectiveRoot, mounted: mounted)
                                  ?? bestName(for: installer, fallback: displayName),
                              mountedVolume: mounted,
                              needsInstaller: true)
        }

        let main = try pickGameExecutable(from: exes, root: effectiveRoot)
        // A disc that runs the game directly is still a disc: the files have to
        // be copied off it before it can be ejected.
        return GameSource(kind: mounted != nil ? .disc : .portable,
                          root: effectiveRoot,
                          mainExecutable: main,
                          candidateExecutables: exes,
                          suggestedName: discName(root: effectiveRoot, mounted: mounted)
                              ?? bestName(for: main, fallback: displayName),
                          mountedVolume: mounted,
                          needsInstaller: false)
    }

    func descendSingleChild(_ url: URL) -> URL {
        var current = url
        for _ in 0..<4 {
            let children = (try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            let dirs = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            let files = children.filter { !dirs.contains($0) }
            // Keep descending only while the folder is a pure wrapper.
            if dirs.count == 1 && files.allSatisfy({ isIgnorableTopLevelFile($0) }) {
                current = dirs[0]
            } else {
                break
            }
        }
        return current
    }

    func isIgnorableTopLevelFile(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return n == "autorun.inf" || n == ".ds_store" || n.hasSuffix(".txt")
            || n.hasSuffix(".nfo") || n.hasSuffix(".ico") || n.hasSuffix(".url")
    }

    public func findExecutables(in root: URL) throws -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        for case let url as URL in e {
            if found.count > 400 { break }
            let ext = url.pathExtension.lowercased()
            guard ext == "exe" || ext == "msi" else { continue }
            found.append(url)
        }
        return found
    }

    /// An `autorun.inf` naming an open target is the disc author telling us
    /// exactly which program to run; nothing beats that signal.
    func autorunTarget(in root: URL) -> URL? {
        let inf = root.appendingPathComponent("autorun.inf")
        guard let raw = try? String(contentsOf: inf, encoding: .isoLatin1) else { return nil }
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard trimmed.hasPrefix("open=") || trimmed.hasPrefix("shellexecute=") else { continue }
            var value = trimmed.split(separator: "=", maxSplits: 1)[1]
            if let space = value.firstIndex(of: " ") { value = value[value.startIndex..<space] }
            let relative = value.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"/ "))
            guard !relative.isEmpty else { continue }
            let candidate = root.appendingPathComponent(relative)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            // Discs are case-insensitive; macOS volumes may not be.
            if let match = caseInsensitiveLookup(relative, under: root) { return match }
        }
        return nil
    }

    /// A disc knows its own name twice over: `label=` in autorun.inf and the
    /// volume name. Both beat guessing from an .exe called `setup`.
    func discName(root: URL, mounted: URL?) -> String? {
        guard mounted != nil else { return nil }
        if let raw = try? String(contentsOf: root.appendingPathComponent("autorun.inf"), encoding: .isoLatin1) {
            for line in raw.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("label=") else { continue }
                let value = String(trimmed.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\t"))
                if value.count > 1 { return Naming.clean(value) }
            }
        }
        // Volume names are shouted in upper case on old discs; leave anything
        // mixed-case alone, but make an all-caps name readable.
        let volume = root.lastPathComponent
        guard volume.count > 1, Naming.isMostlyLatin(volume) else { return nil }
        if volume == volume.uppercased() && volume.count > 3 {
            return Naming.clean(volume.capitalized)
        }
        return Naming.clean(volume)
    }

    func caseInsensitiveLookup(_ relative: String, under root: URL) -> URL? {
        var current = root
        for component in relative.split(separator: "/") {
            let children = (try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)) ?? []
            guard let hit = children.first(where: { $0.lastPathComponent.lowercased() == component.lowercased() })
            else { return nil }
            current = hit
        }
        return current
    }

    func pickInstaller(from exes: [URL], root: URL) -> URL? {
        if let target = autorunTarget(in: root), InstallerDetector.isInstaller(target) { return target }
        let real = exes.filter { !isNoise($0, root: root) }
        // Prefer a top-level installer over one buried in a subfolder.
        let installers = real.filter { InstallerDetector.isInstaller($0) }
            .sorted { depth($0, from: root) < depth($1, from: root) }
        return installers.first
    }

    func pickGameExecutable(from exes: [URL], root: URL) throws -> URL {
        if let target = autorunTarget(in: root) { return target }
        let real = exes.filter { !isNoise($0, root: root) }
        let pool = real.isEmpty ? exes : real
        guard !pool.isEmpty else { throw GameSource.SourceError.noExecutable(root.path) }
        if pool.count == 1 { return pool[0] }

        let folderName = root.lastPathComponent.lowercased()
        var scored: [(url: URL, score: Int)] = []
        for url in pool {
            var score = 0
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            // The game binary is nearly always the biggest one.
            score += min(size / 1_000_000, 60)
            // Sitting at the root beats being three folders deep.
            score += max(0, 20 - depth(url, from: root) * 8)
            // Named after the folder it lives in: strong signal.
            if folderName.contains(stem) || stem.contains(folderName) { score += 30 }
            // GUI subsystem beats a console tool.
            if let pe = try? PEFile(url: url) {
                if pe.subsystem == .gui { score += 25 } else { score -= 25 }
                if pe.hasIcon { score += 15 }
                // A binary that talks to Direct3D is the game, not a config tool.
                if pe.importedDLLs.contains(where: {
                    $0.hasPrefix("d3d") || $0 == "ddraw.dll" || $0.hasPrefix("xaudio")
                        || $0 == "dinput8.dll" || $0.hasPrefix("xinput") || $0 == "dsound.dll"
                }) { score += 40 }
            }
            for word in ["launcher", "config", "setup", "editor", "server", "dedicated", "tool", "benchmark"]
            where stem.contains(word) {
                score -= 35
            }
            scored.append((url, score))
        }
        scored.sort { $0.score > $1.score }
        return scored[0].url
    }

    func isNoise(_ url: URL, root: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if Self.noiseExeNames.contains(name) { return true }
        let path = url.path.lowercased()
        let rootPath = root.path.lowercased()
        let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
        return Self.noisePathFragments.contains { relative.contains($0) }
    }

    func depth(_ url: URL, from root: URL) -> Int {
        max(0, url.pathComponents.count - root.pathComponents.count - 1)
    }

    func bestName(for exe: URL, fallback: String) -> String {
        let cleanFallback = Naming.clean(fallback)
        guard let pe = try? PEFile(url: exe), let declared = pe.declaredName else {
            return cleanFallback
        }
        let cleanDeclared = Naming.clean(declared)
        // A Japanese or Cyrillic ProductName is authentic but unreadable to
        // most people; if the folder or file name is plain Latin, that is the
        // name the user already thinks of the game by.
        if !Naming.isMostlyLatin(cleanDeclared) && Naming.isMostlyLatin(cleanFallback) {
            return cleanFallback
        }
        return cleanDeclared.isEmpty ? cleanFallback : cleanDeclared
    }
}

public enum Naming {
    /// Words that describe the package rather than the game.
    static let installerPhrases = [
        "installer for windows", "setup for windows", "install wizard",
        "installation program", "setup program", "installer", "instalador",
        "setup wizard", "for windows",
    ]

    /// Turn "OpenTTD_14.1_win64-setup" or "OpenTTD Installer for Windows"
    /// into "OpenTTD".
    public static func clean(_ raw: String) -> String {
        var s = raw
        // Cut the packaging vocabulary out first; what remains is the title.
        for phrase in installerPhrases {
            if let range = s.range(of: phrase, options: [.caseInsensitive]) {
                s = String(s[s.startIndex..<range.lowerBound])
            }
        }
        for junk in ["_setup", "-setup", " setup", "_installer", "-installer",
                     "_win64", "_win32", "-win64", "-win32", "_x64", "_x86"] {
            s = s.replacingOccurrences(of: junk, with: "", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "_", with: " ")
        // Strip a trailing version number, but only when it *looks* like one.
        // A bare integer is usually part of the title — "Warzone 2100",
        // "Descent 3" — so require a dot or a leading "v" before dropping it.
        while let last = s.split(separator: " ").last, looksLikeVersion(String(last)) {
            s = s.split(separator: " ").dropLast().joined(separator: " ")
            if s.isEmpty { break }
        }
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:")))
        // Never hand back an empty or filesystem-hostile name.
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return s.isEmpty ? "Windows Game" : s
    }

    /// "1.18.4", "v3", "14.1" — yes. "2100", "3" — no, those are titles.
    static func looksLikeVersion(_ token: String) -> Bool {
        let body = token.lowercased().hasPrefix("v") ? String(token.dropFirst()) : token
        guard !body.isEmpty, body.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        if body.contains(".") { return true }
        return token.lowercased().hasPrefix("v")
    }

    /// True when the text is readable as Latin script, ignoring punctuation.
    public static func isMostlyLatin(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let latin = letters.filter { $0.value < 0x0250 }
        return Double(latin.count) / Double(letters.count) > 0.6
    }
}
