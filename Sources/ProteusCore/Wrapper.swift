// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// A finished, double-clickable .app that contains a game, its Wine engine and
/// its own private Windows install. Nothing lives outside the bundle, so the
/// user can drag it to the Trash and be genuinely done.
public struct Wrapper: Sendable {
    public let bundle: URL

    public init(bundle: URL) { self.bundle = bundle }

    public var contents: URL { bundle.appendingPathComponent("Contents") }
    public var sharedSupport: URL { contents.appendingPathComponent("SharedSupport") }
    public var prefix: URL { sharedSupport.appendingPathComponent("prefix") }
    public var wineRoot: URL { sharedSupport.appendingPathComponent("wine") }
    /// Always the path inside `Runtime.app` when it exists.
    ///
    /// `bin/wine` is a symlink to the same binary, but executing through the
    /// symlink loses the bundle identity — the process comes back as an
    /// anonymous "wine". Verification has to launch the game exactly the way a
    /// double-click will, or it is testing something the user never runs.
    public var wineBinary: URL {
        let bundled = wineRoot.appendingPathComponent("Runtime.app/Contents/MacOS/wine")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return wineRoot.appendingPathComponent("bin/wine")
    }
    public var driveC: URL { prefix.appendingPathComponent("drive_c") }
    public var infoPlist: URL { contents.appendingPathComponent("Info.plist") }
    public var resources: URL { contents.appendingPathComponent("Resources") }
    public var frameworks: URL { contents.appendingPathComponent("Frameworks") }

    // MARK: - Info.plist

    public func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: infoPlist)
        return (try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
    }

    public func writePlist(_ dict: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: infoPlist)
    }

    public func setPlistValues(_ values: [String: Any]) throws {
        var dict = try plist()
        for (k, v) in values { dict[k] = v }
        try writePlist(dict)
    }

    /// Where the game will run from, as a Windows path.
    public func windowsPath(for url: URL) -> String? {
        let cPath = driveC.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(cPath) else { return nil }
        let relative = String(target.dropFirst(cPath.count))
        return "C:" + relative.replacingOccurrences(of: "/", with: "\\")
    }
}

/// Builds wrappers from the cached template + engine.
public struct WrapperBuilder {
    let fm = FileManager.default
    let template: URL
    /// An already-unpacked engine directory, cloned into each wrapper.
    let engineRoot: URL

    public init(template: URL, engineRoot: URL) {
        self.template = template
        self.engineRoot = engineRoot
    }

    public enum BuildError: Error, CustomStringConvertible {
        case engineUnpackFailed(String)
        case templateCopyFailed(String)
        case destinationExists(String)

        public var description: String {
            switch self {
            case .engineUnpackFailed(let s): return "could not install the Wine engine: \(s)"
            case .templateCopyFailed(let s): return "could not create the app bundle: \(s)"
            case .destinationExists(let s): return "\(s) already exists"
            }
        }
    }

    /// Creates the bundle and installs the engine. The prefix is still empty
    /// at this point — `WineEngine.boot` fills it.
    public func build(named name: String, at destination: URL,
                      progress: (String, String) -> Void = { _, _ in }) throws -> Wrapper {
        if fm.fileExists(atPath: destination.path) {
            throw BuildError.destinationExists(destination.lastPathComponent)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        progress("Creating the app", "Creando la app")
        // On APFS a clone costs no disk space and almost no time, which is what
        // makes "one self-contained app per game" affordable at ~1.4 GB each.
        // Fall back to a real copy on any other filesystem.
        let clone = Shell.run("/bin/cp", ["-Rc", template.path, destination.path], timeout: 600)
        if clone.exitCode != 0 {
            try? fm.removeItem(at: destination)
            do {
                try fm.copyItem(at: template, to: destination)
            } catch {
                throw BuildError.templateCopyFailed(error.localizedDescription)
            }
        }
        let wrapper = Wrapper(bundle: destination)

        progress("Installing the Wine engine", "Instalando el motor de Wine")
        try installEngine(into: wrapper)

        // The template ships symlinks that assume its own name; make sure the
        // drive_c shortcut still resolves after the copy.
        let driveCLink = wrapper.contents.appendingPathComponent("drive_c")
        if (try? fm.destinationOfSymbolicLink(atPath: driveCLink.path)) == nil {
            try? fm.removeItem(at: driveCLink)
            try? fm.createSymbolicLink(atPath: driveCLink.path,
                                       withDestinationPath: "SharedSupport/prefix/drive_c")
        }
        return wrapper
    }

    /// Names the app and gives it an icon before any of the slow work starts.
    ///
    /// A wrapper is born wearing the template's own icon — a Wine glass — and
    /// keeps it until the install finishes and `configure` runs. On a large
    /// game that is half an hour of a Wine glass sitting in the Applications
    /// folder under a name nobody chose. The real icon cannot be extracted yet,
    /// because the game is not on disk, but a lettered tile with the right name
    /// is honest and immediate.
    public func claimIdentity(_ wrapper: Wrapper, name: String, launcher: URL? = nil) throws {
        // Give the runtime its identity now, not at the end. The installer runs
        // through the same Wine binary, so doing this late means the whole
        // install shows up as an anonymous process called "wine" — which is
        // what the user sees in the Dock for the half hour it takes.
        if let launcher, fm.isExecutableFile(atPath: launcher.path) {
            try? installRuntimeIdentity(into: wrapper, name: name,
                                        bundleID: "com.proteus.game." + slug(name),
                                        launcher: launcher)
        }
        let icns = wrapper.resources.appendingPathComponent("Proteus.icns")
        try? fm.removeItem(at: icns)
        try? IconExtractor.writePlaceholderICNS(named: name, to: icns)
        try wrapper.setPlistValues([
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIconFile": "Proteus",
            "ProteusManaged": true,
            "ProteusInstalling": true,
        ])
        if launcher != nil {
            try wrapper.setPlistValues(["CFBundleExecutable": "ProteusLauncher"])
        }

        // Seal here, not only at the end. This is the moment the template's
        // signature stops matching — a launcher has just been written in and
        // Info.plist rewritten — and it is *before* the long part of the
        // install. Leaving it broken until `configure` meant macOS saw an
        // invalid bundle for the entire hour in between, and refused to open it
        // with "is damaged", while the progress bar still said "Setting up
        // Windows".
        //
        // The whole-bundle sweep happens here for the same reason: right now
        // this is a few hundred megabytes of template and engine, and clearing
        // quarantine from all of it costs almost nothing. After the game lands
        // the same walk would cross tens of gigabytes.
        seal(wrapper, sweepEverything: true)
    }

    /// Makes the finished bundle something macOS will actually open.
    ///
    /// Two things conspire to produce *"is damaged and can't be opened. You
    /// should move it to the Trash"* — the worst dialogue macOS has, because it
    /// is wrong and it recommends destroying the user's install.
    ///
    /// **The quarantine flag.** Games arrive as downloads, so their files carry
    /// `com.apple.quarantine`, and it spreads to the bundle built around them.
    /// Gatekeeper then assesses this app as if the user had downloaded it —
    /// which they did not; Proteus assembled it here, on this machine, minutes
    /// ago. Clearing the flag is not a bypass: it is telling the truth about
    /// where the bundle came from, the same as any app a compiler writes.
    ///
    /// **The broken seal.** The template arrives signed. Then a name, an icon,
    /// an Info.plist and a launcher are written into it, which is exactly what
    /// a signature exists to detect. A *broken* signature is worse than none:
    /// no signature means "unknown developer", a broken one means "damaged".
    ///
    /// Signing the launcher on its own does not work, and it is worth saying
    /// why, because it is the obvious thing to try. The linker already gives it
    /// an ad-hoc signature — `flags=0x20002(adhoc,linker-signed)` — but that is
    /// the signature of a *bare binary*. macOS judges the enclosing bundle,
    /// expects a sealed resource directory to go with it, finds none, and
    /// reports exactly this:
    ///
    ///     code has no resources but signature indicates they must be present
    ///
    /// So the bundle is signed, as a bundle. `--deep` is used here, having been
    /// deliberately avoided when signing Proteus itself for distribution: this
    /// is an ad-hoc seal on a bundle assembled locally that will never leave
    /// this machine, and its nested pieces — the template's own helper apps —
    /// arrive unsigned and block a shallow signature outright. Different job,
    /// different tool.
    ///
    /// Measured at about a second on a 1.5 GB game: codesign hashes the code,
    /// not the Windows prefix, so this does not scale with the size of the
    /// install.
    /// - Parameter sweepEverything: also clear quarantine from every file
    ///   inside. Worth doing once, early, while the bundle is a few hundred
    ///   megabytes of template and engine; ruinous later, when the same walk
    ///   crosses tens of gigabytes of installed game.
    public func seal(_ wrapper: Wrapper, sweepEverything: Bool = false) {
        let flags = sweepEverything ? ["-dr"] : ["-d"]
        _ = Shell.run("/usr/bin/xattr", flags + ["com.apple.quarantine", wrapper.bundle.path],
                      timeout: 300)

        _ = Shell.run("/usr/bin/codesign",
                      ["--force", "--deep", "--sign", "-", wrapper.bundle.path],
                      timeout: 600)
    }

    /// Gives the game its own identity.
    ///
    /// Wine run as a bare binary registers with macOS as an anonymous process
    /// literally called "wine" — no display name, no bundle identifier. The
    /// game shows up as "wine" in the Dock and in Force Quit, and nothing that
    /// addresses apps by identity (accessibility, automation, screen-recording
    /// permissions) can reach it. Every Wine wrapper on macOS has this problem.
    ///
    /// Executing the same binary from inside a small .app bundle fixes it: the
    /// process becomes "Cave Story" with the wrapper's own identifier. The path
    /// passed to exec has to be the bundle path — a symlink or shell shim is
    /// resolved too late and the identity is lost — so the wrapper's launcher
    /// is replaced with one that execs the runtime bundle directly.
    func installRuntimeIdentity(into wrapper: Wrapper, name: String, bundleID: String,
                                launcher: URL) throws {
        let runtime = wrapper.wineRoot.appendingPathComponent("Runtime.app")
        let runtimeContents = runtime.appendingPathComponent("Contents")
        let runtimeMacOS = runtimeContents.appendingPathComponent("MacOS")

        // This runs twice: once when the bundle is created, so the installer
        // already carries the game's name, and again at the end. It has to be
        // idempotent — deleting and rebuilding on the second pass destroys the
        // engine, because `bin` is by then a symlink *into* what was deleted
        // and there is nothing left to move back.
        let alreadyBuilt = fm.isExecutableFile(atPath: runtimeMacOS.appendingPathComponent("wine").path)
        if !alreadyBuilt {
            try? fm.removeItem(at: runtime)
            try fm.createDirectory(at: runtimeMacOS, withIntermediateDirectories: true)

            // The binaries move in rather than being copied: wine finds
            // wineserver beside itself, and two copies of a 40 MB binary help
            // nobody.
            let bin = wrapper.wineRoot.appendingPathComponent("bin")
            for entry in (try? fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.moveItem(at: entry, to: runtimeMacOS.appendingPathComponent(entry.lastPathComponent))
            }
            // Keep `bin` pointing at the same files: winetricks and anything
            // else that knows the classic layout still works.
            try? fm.removeItem(at: bin)
            try fm.createSymbolicLink(atPath: bin.path, withDestinationPath: "Runtime.app/Contents/MacOS")
        }

        // Wine resolves its data directories relative to the executable.
        for directory in ["lib", "share"] {
            let link = runtimeContents.appendingPathComponent(directory)
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../\(directory)")
        }

        let plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "wine",
            "CFBundleIdentifier": bundleID,
            "CFBundlePackageType": "APPL",
            "NSHighResolutionCapable": true,
            "LSMinimumSystemVersion": "10.15",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: runtimeContents.appendingPathComponent("Info.plist"))

        // Replace the wrapper's launcher with ours, which knows to exec the
        // bundle path. Keep the original beside it so the wrapper's own
        // configuration tools still have something to call.
        let macOS = wrapper.contents.appendingPathComponent("MacOS")
        let target = macOS.appendingPathComponent("ProteusLauncher")
        try? fm.removeItem(at: target)
        try fm.copyItem(at: launcher, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    /// Replaces the engine inside a wrapper that already exists.
    ///
    /// The engine has to be chosen before the installer can run, and for an
    /// installer that is before anything is known about the game — its needs
    /// only become readable once its files are on disk. A DirectX 12 game
    /// therefore gets built on the general engine and then asks for D3DMetal,
    /// which only ships with the Game Porting Toolkit build. The result starts,
    /// cannot create a graphics device and never opens a window.
    ///
    /// The Windows prefix lives beside the engine rather than inside it, so
    /// swapping the engine keeps the install intact.
    public func replaceEngine(in wrapper: Wrapper, withUnpacked newEngine: URL) throws {
        let target = wrapper.wineRoot
        let runtimeName = "Runtime.app"
        let hadRuntime = fm.fileExists(atPath: target.appendingPathComponent(runtimeName).path)
        let identity = hadRuntime
            ? try? Data(contentsOf: target.appendingPathComponent("\(runtimeName)/Contents/Info.plist"))
            : nil

        let staging = target.deletingLastPathComponent().appendingPathComponent("wine.new")
        try? fm.removeItem(at: staging)
        let clone = Shell.run("/bin/cp", ["-Rc", newEngine.path, staging.path], timeout: 900)
        if clone.exitCode != 0 {
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: newEngine, to: staging)
        }

        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)

        // Rebuild the identity bundle on the new engine, reusing the plist so
        // the game keeps its name.
        if let identity {
            let runtimeMacOS = target.appendingPathComponent("\(runtimeName)/Contents/MacOS")
            try? fm.createDirectory(at: runtimeMacOS, withIntermediateDirectories: true)
            let bin = target.appendingPathComponent("bin")
            for entry in (try? fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.moveItem(at: entry, to: runtimeMacOS.appendingPathComponent(entry.lastPathComponent))
            }
            try? fm.removeItem(at: bin)
            try? fm.createSymbolicLink(atPath: bin.path, withDestinationPath: "\(runtimeName)/Contents/MacOS")
            for directory in ["lib", "share"] {
                let link = target.appendingPathComponent("\(runtimeName)/Contents/\(directory)")
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../\(directory)")
            }
            try? identity.write(to: target.appendingPathComponent("\(runtimeName)/Contents/Info.plist"))
        }
    }

    func installEngine(into wrapper: Wrapper) throws {
        try? fm.removeItem(at: wrapper.wineRoot)
        try fm.createDirectory(at: wrapper.sharedSupport, withIntermediateDirectories: true)

        // Clone rather than copy: the engine is ~1 GB and identical in every
        // wrapper, so on APFS the tenth game costs the same disk as the first.
        let clone = Shell.run("/bin/cp", ["-Rc", engineRoot.path, wrapper.wineRoot.path], timeout: 900)
        if clone.exitCode != 0 {
            try? fm.removeItem(at: wrapper.wineRoot)
            do {
                try fm.copyItem(at: engineRoot, to: wrapper.wineRoot)
            } catch {
                throw BuildError.engineUnpackFailed(error.localizedDescription)
            }
        }

        // tar restores the mode bits, but a defensive chmod costs nothing and
        // saves an unexplainable "permission denied" later.
        for binary in ["wine", "wineserver", "wine64", "wine-preloader", "wine64-preloader"] {
            let path = wrapper.wineRoot.appendingPathComponent("bin/\(binary)")
            if fm.fileExists(atPath: path.path) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            }
        }
    }

    /// Applies identity (name, bundle id, icon) and the resolved prescription.
    public func configure(_ wrapper: Wrapper,
                          name: String,
                          exeWindowsPath: String,
                          prescription: Prescription,
                          iconSource: URL?,
                          launcher: URL? = nil) throws {
        let bundleID = "com.proteus.game." + slug(name)
        var values: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": bundleID,
            "Program Name and Path": exeWindowsPath,
            // The template defaults to background-only; a game needs a Dock tile.
            "NSBGOnly": "0",
            "ProteusManaged": true,
            // Installation is over; the app is a real game now.
            "ProteusInstalling": false,
            "ProteusRenderer": prescription.renderer.rawValue,
            // Kept so "reset settings" has a truth to return to after the
            // player has experimented.
            "ProteusOriginalRenderer": prescription.renderer.rawValue,
            "ProteusOriginalFlags": prescription.launchArguments.joined(separator: " "),
            // Why each decision was made, kept so the settings panel can
            // explain itself instead of presenting bare switches. A setting
            // whose reason is visible is one a person can judge.
            "ProteusReasons": prescription.reasons.map {
                ["en": $0.requirement, "es": $0.requirementES, "why": $0.evidence]
            },
            "ProteusEngine": prescription.engineName ?? "",
        ]
        // Arguments the engine needs to start the game rather than a chooser.
        if !prescription.launchArguments.isEmpty {
            values["Program Flags"] = prescription.launchArguments.joined(separator: " ")
        }
        values.merge(prescription.plistOverrides) { _, new in new }

        if let iconSource {
            let icns = wrapper.resources.appendingPathComponent("Proteus.icns")
            try? fm.removeItem(at: icns)
            try IconExtractor.makeICNS(from: iconSource, named: name, to: icns)
            values["CFBundleIconFile"] = "Proteus"
        }
        // The launcher has to be in place before CFBundleExecutable points at
        // it, or a double-click finds nothing to run.
        if let launcher, fm.isExecutableFile(atPath: launcher.path) {
            try installRuntimeIdentity(into: wrapper, name: name, bundleID: bundleID, launcher: launcher)
            values["CFBundleExecutable"] = "ProteusLauncher"
        }
        try wrapper.setPlistValues(values)

        // Last, after every write. Renaming the bundle, swapping its icon and
        // rewriting Info.plist is precisely what the template's signature
        // exists to detect, and a signature that no longer matches is reported
        // to the user as "is damaged and can't be opened. You should move it to
        // the Trash" — advice that destroys a working install.
        seal(wrapper)
    }

    func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).lowercased()
            .split(separator: "-").joined(separator: "-")
    }
}
