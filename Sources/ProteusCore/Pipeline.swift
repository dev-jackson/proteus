// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// The whole job, start to finish: something the user dropped on the window
/// becomes an app in /Applications. Every stage reports bilingual progress so
/// the UI never has to invent wording for a state it does not understand.
public actor InstallPipeline {

    public struct Stage: Sendable {
        public let en: String
        public let es: String
        public let fraction: Double?
        public let detail: String?

        public init(en: String, es: String, fraction: Double? = nil, detail: String? = nil) {
            self.en = en; self.es = es; self.fraction = fraction; self.detail = detail
        }
    }

    /// What we learned before touching anything — shown to the user as
    /// "here is what this game needs", which is the whole point of the app.
    public struct Analysis: Sendable {
        public let name: String
        public let kind: String            // "installer" | "portable" | "disc"
        public let architecture: String
        public let prescription: Prescription
        public let mainExecutable: URL
        public let downloadBytes: Int64
        public let candidateCount: Int
        /// Only meaningful for installers; nil for a portable game.
        public let installerFramework: String?
    }

    public struct Outcome: Sendable {
        public let appPath: URL
        public let name: String
        public let warnings: [String]
        /// Result of actually starting the game before handing it over.
        public let verdict: SmokeTest.Verdict?
        /// Whether keyboard and mouse events actually reached the game.
        public let input: InputCheck.Report?
        /// What the game's own picture looked like, and what had to be changed
        /// to make it look right.
        public let display: AutoRepair.Outcome?
        /// Set when the game did not start and re-running the installer by
        /// hand is the obvious next move.
        public let installerForManualRun: URL?
    }

    public enum PipelineError: Error, CustomStringConvertible {
        case analysisFailed(String)
        case gameNotFoundAfterInstall
        case installerFailed(String)
        case notEnoughSpace(needed: Int64, free: Int64)

        public var description: String {
            switch self {
            case .analysisFailed(let s): return s
            case .gameNotFoundAfterInstall:
                return "the installer finished but no game program appeared"
            case .installerFailed(let s): return "the installer did not complete: \(s)"
            case .notEnoughSpace(let needed, let free):
                return "this game needs about \(InstallPipeline.readableSize(needed)) and there is only "
                    + "\(InstallPipeline.readableSize(free)) free. Free up some space and try again."
            }
        }
    }

    let fm = FileManager.default
    let runtime: Runtime
    let workDir: URL
    let installRoot: URL

    /// Whether to run the keyboard/mouse check. Off in tests that only care
    /// about the build, on for real installs.
    let checkInput: Bool

    /// The launcher copied into every wrapper so the game gets its own
    /// identity. Defaults to the one shipped beside this binary.
    let launcherBinary: URL?

    public init(runtime: Runtime = Runtime(),
                workDir: URL? = nil,
                installRoot: URL = URL(fileURLWithPath: "/Applications"),
                checkInput: Bool = true,
                launcherBinary: URL? = nil) {
        self.launcherBinary = launcherBinary ?? InstallPipeline.defaultLauncher()
        self.checkInput = checkInput
        self.runtime = runtime
        self.workDir = workDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Proteus", isDirectory: true)
        self.installRoot = installRoot
    }

    /// Looks for `proteus-launcher` next to whatever is running: the app bundle
    /// keeps it in Resources, a development build leaves it in the build
    /// directory beside the executable.
    static func defaultLauncher() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("proteus-launcher"))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(executable.appendingPathComponent("proteus-launcher"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Analyse

    public func analyze(_ input: URL) async throws -> (Analysis, GameSource) {
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let scanner = SourceScanner(workDir: workDir)
        let source = try scanner.scan(input)

        // A Windows Installer package has no PE header at all, so the whole
        // read-the-binary approach does not apply. What it can tell us is its
        // name and architecture; the real analysis happens after it runs, on
        // the program it installed.
        if source.mainExecutable.pathExtension.lowercased() == "msi" {
            return try await analyseMSI(source)
        }

        let pe: PEFile
        do {
            pe = try PEFile(url: source.mainExecutable)
        } catch {
            throw PipelineError.analysisFailed("\(source.mainExecutable.lastPathComponent): \(error)")
        }

        // Read the other executables too — a thin launcher hides the real
        // dependency list one process away.
        let siblings = (try? fm.contentsOfDirectory(at: source.mainExecutable.deletingLastPathComponent(),
                                                    includingPropertiesForKeys: nil)) ?? []
        let otherPEs = source.candidateExecutables
            .prefix(12)
            .filter { $0 != source.mainExecutable }
            .compactMap { try? PEFile(url: $0) }

        // A disc or installer is read for what it carries, not what it imports;
        // the real prescription is computed once the game exists on disk.
        let isInstaller = source.needsInstaller
        let discFiles = isInstaller ? allFiles(under: source.root, limit: 600) : siblings
        // Reading the whole binary for run-time DLL names is only worth it for
        // the actual game; an installer's strings say nothing about it.
        let dynamic = isInstaller ? [] : pe.dynamicallyLoadedDLLs()
        let fingerprint = isInstaller ? EngineFingerprint.none
            : EngineFingerprint.detect(root: source.mainExecutable.deletingLastPathComponent(),
                                       executables: source.candidateExecutables)
        let prescription = DependencyResolver.resolve(.init(
            mainExe: pe,
            otherExes: Array(otherPEs),
            siblingFiles: isInstaller ? discFiles : siblings,
            dynamicDLLs: dynamic,
            engine: fingerprint,
            known: isInstaller ? nil : KnownTitle.match(source.mainExecutable.deletingLastPathComponent()),
            analysingInstaller: isInstaller,
            installedBytes: isInstaller ? 0 : directorySize(source.mainExecutable.deletingLastPathComponent())))

        let engine = prescription.needsRosetta ? Runtime.gptkEngine : Runtime.defaultEngine
        let pending = await runtime.pendingDownloadBytes(engine: engine)

        let analysis = Analysis(
            name: source.suggestedName,
            kind: {
                switch source.kind {
                case .installer: return "installer"
                case .portable: return "portable"
                case .disc: return "disc"
                }
            }(),
            architecture: pe.machine.label,
            prescription: prescription,
            mainExecutable: source.mainExecutable,
            downloadBytes: pending,
            candidateCount: source.candidateExecutables.count,
            installerFramework: isInstaller ? InstallerDetector.framework(of: source.mainExecutable).rawValue : nil)
        return (analysis, source)
    }

    func analyseMSI(_ source: GameSource) async throws -> (Analysis, GameSource) {
        let package: MSIPackage
        do {
            package = try MSIPackage(url: source.mainExecutable)
        } catch {
            throw PipelineError.analysisFailed("\(source.mainExecutable.lastPathComponent): \(error)")
        }

        // Only disc-level evidence is available: whatever redistributables sit
        // beside the package.
        let discFiles = allFiles(under: source.root, limit: 600)
        var prescription = DependencyResolver.resolveFromDisc(files: discFiles,
                                                              is32Bit: !package.is64Bit)
        prescription.is32Bit = !package.is64Bit

        let engineChoice = Runtime.defaultEngine
        let pending = await runtime.pendingDownloadBytes(engine: engineChoice)
        let name = package.productName.map(Naming.clean) ?? source.suggestedName

        let analysis = Analysis(
            name: name,
            kind: source.kind == .disc ? "disc" : "installer",
            architecture: package.architecture,
            prescription: prescription,
            mainExecutable: source.mainExecutable,
            downloadBytes: pending,
            candidateCount: source.candidateExecutables.count,
            installerFramework: InstallerDetector.Framework.msi.rawValue)
        return (analysis, source)
    }

    /// How big the game is, which is the cheapest signal for how much it will
    /// ask of the GPU. Capped so a huge tree cannot stall analysis.
    func directorySize(_ root: URL, limit: Int = 4000) -> Int64 {
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

    /// Flat listing of a disc, capped so a bloated image cannot stall analysis.
    func allFiles(under root: URL, limit: Int) -> [URL] {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            out.append(url)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Install

    public func install(source: GameSource,
                        analysis: Analysis,
                        name: String? = nil,
                        progress: @Sendable @escaping (Stage) -> Void) async throws -> Outcome {
        var warnings: [String] = []
        let gameName = name ?? analysis.name
        defer {
            if let volume = source.mountedVolume { DiscMounter.unmount(volume) }
        }

        // 1. Runtime ---------------------------------------------------------
        let engineChoice = analysis.prescription.needsRosetta ? Runtime.gptkEngine : Runtime.defaultEngine
        progress(.init(en: "Preparing the Windows runtime", es: "Preparando el entorno de Windows", fraction: 0.02))
        let template = try await runtime.ensureTemplate { p in
            progress(.init(en: p.stageEN, es: p.stageES, fraction: p.fraction.map { 0.02 + $0 * 0.18 }))
        }
        let engineRoot = try await runtime.ensureEngineUnpacked(engineChoice) { p in
            progress(.init(en: p.stageEN, es: p.stageES, fraction: p.fraction.map { 0.20 + $0 * 0.25 }))
        }

        // 1b. Room to work ------------------------------------------------------
        // Running out of disk halfway through a 40 GB install wastes an hour
        // and leaves a broken bundle behind. The size is knowable up front, so
        // the answer belongs here rather than in a failure at 80%.
        if let shortfall = spaceShortfall(for: source, engineBytes: 2_000_000_000) {
            throw PipelineError.notEnoughSpace(needed: shortfall.needed, free: shortfall.free)
        }

        // 2. Bundle ----------------------------------------------------------
        progress(.init(en: "Creating \(gameName)", es: "Creando \(gameName)", fraction: 0.47))
        let builder = WrapperBuilder(template: template, engineRoot: engineRoot)

        // If this game is already installed, rescue anything that looks like
        // saved progress from beside its executable before the new copy
        // replaces it.
        let existing = installRoot.appendingPathComponent("\(sanitize(gameName)).app")
        if fm.fileExists(atPath: existing.path) {
            let previous = Wrapper(bundle: existing)
            if let oldGameDir = findFreshInstall(in: previous, excluding: URL(fileURLWithPath: "/nowhere")) {
                let rescued = GameData(gameName: gameName).preserveSaves(from: oldGameDir)
                if rescued > 0 {
                    progress(.init(en: "Keeping \(rescued) saved files from the previous install",
                                   es: "Conservando \(rescued) archivos guardados de la instalación anterior",
                                   fraction: 0.47))
                }
            }
        }

        let destination = uniqueDestination(for: gameName)
        let wrapper = try builder.build(named: gameName, at: destination) { en, es in
            progress(.init(en: en, es: es, fraction: 0.50))
        }
        // Name it and give it an icon straight away, so the Applications folder
        // never shows a Wine glass called "Template" while the install runs.
        try? builder.claimIdentity(wrapper, name: gameName, launcher: launcherBinary)
        _ = Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                      ["-f", destination.path], timeout: 20)

        let engine = WineEngine(wrapper: wrapper)

        // Roll back a half-built app rather than leaving debris in /Applications.
        var succeeded = false
        defer {
            // Whatever happens, no orphan Wine processes: an installer left
            // running after the window closed keeps writing into a bundle
            // nobody is watching, and shows in the Dock as "wine" forever.
            if !succeeded {
                engine.killServer()
                try? fm.removeItem(at: destination)
            }
        }

        // 3. Windows environment ---------------------------------------------
        progress(.init(en: "Setting up Windows", es: "Configurando Windows", fraction: 0.55))
        try engine.boot()

        // Give the game its own Documents, Desktop and Downloads before it can
        // write anything. The template points those at the real ones, which
        // means a Windows program could read and rewrite every personal file on
        // the Mac — and it means saves land inside the app, where a reinstall
        // destroys them.
        let gameData = GameData(gameName: gameName)
        do { try gameData.adopt(prefix: wrapper.prefix) }
        catch { warnings.append("Could not give the game its own folders: \(error)") }

        // 4. Dependencies -----------------------------------------------------
        if !analysis.prescription.winetricks.isEmpty {
            let tricks = Winetricks(cacheDir: runtimeCacheDir())
            do {
                _ = try await tricks.ensureScript()
                let total = Double(analysis.prescription.winetricks.count)
                for (index, verb) in analysis.prescription.winetricks.enumerated() {
                    progress(.init(en: "Installing \(friendly(verb))",
                                   es: "Instalando \(friendly(verb))",
                                   fraction: 0.58 + (Double(index) / total) * 0.12,
                                   detail: verb))
                    let outcome = tricks.install(verb, into: wrapper, engine: engine)
                    if !outcome.installed {
                        warnings.append("\(friendly(verb)): \(outcome.detail)")
                    }
                    engine.waitForServerIdle()
                }
            } catch {
                warnings.append("Optional components were skipped: \(error)")
            }
        }

        // 5. Get the game into drive_c ----------------------------------------
        let gameDir: URL
        if source.needsInstaller {
            progress(.init(en: "Running the installer", es: "Ejecutando el instalador", fraction: 0.72))
            gameDir = try runInstaller(source: source, wrapper: wrapper, engine: engine,
                                       name: gameName, warnings: &warnings, progress: progress)
        } else {
            progress(.init(en: "Copying game files", es: "Copiando archivos del juego", fraction: 0.72))
            gameDir = try copyPortable(source: source, into: wrapper, name: gameName)
        }

        // 6. Find the real game binary now that it exists ----------------------
        progress(.init(en: "Locating the game", es: "Localizando el juego", fraction: 0.86))
        let scanner = SourceScanner(workDir: workDir)
        let installedExes = try scanner.findExecutables(in: gameDir)
        guard !installedExes.isEmpty else { throw PipelineError.gameNotFoundAfterInstall }
        let gameExe = (try? scanner.pickGameExecutable(from: installedExes, root: gameDir)) ?? installedExes[0]

        // Re-run the dependency read against the installed game: this is where
        // an installer-based title finally reveals what it actually links.
        var finalPrescription = analysis.prescription
        if source.needsInstaller, let installedPE = try? PEFile(url: gameExe) {
            let siblings = (try? fm.contentsOfDirectory(at: gameExe.deletingLastPathComponent(),
                                                        includingPropertiesForKeys: nil)) ?? []
            let others = installedExes.prefix(10).filter { $0 != gameExe }.compactMap { try? PEFile(url: $0) }
            let installedEngine = EngineFingerprint.detect(root: gameExe.deletingLastPathComponent(),
                                                           executables: installedExes)
            let refined = DependencyResolver.resolve(.init(
                mainExe: installedPE,
                otherExes: Array(others),
                siblingFiles: siblings,
                dynamicDLLs: installedPE.dynamicallyLoadedDLLs(),
                engine: installedEngine,
                known: KnownTitle.match(gameDir),
                installedBytes: directorySize(gameDir)))
            finalPrescription.renderer = refined.renderer
            finalPrescription.reasons = refined.reasons
            finalPrescription.usesMouse = refined.usesMouse
            finalPrescription.usesGamepad = refined.usesGamepad
            finalPrescription.engineName = refined.engineName
            finalPrescription.launchArguments = refined.launchArguments
            finalPrescription.needsRosetta = refined.needsRosetta
            finalPrescription.plistOverrides.merge(refined.plistOverrides) { _, new in new }
            // Install anything the installer's own binary never hinted at.
            let extra = refined.winetricks.filter { !finalPrescription.winetricks.contains($0) }
            if !extra.isEmpty {
                let tricks = Winetricks(cacheDir: runtimeCacheDir())
                if (try? await tricks.ensureScript()) != nil {
                    for verb in extra {
                        progress(.init(en: "Installing \(friendly(verb))",
                                       es: "Instalando \(friendly(verb))", fraction: 0.90, detail: verb))
                        let outcome = tricks.install(verb, into: wrapper, engine: engine)
                        if !outcome.installed { warnings.append("\(friendly(verb)): \(outcome.detail)") }
                    }
                }
                finalPrescription.winetricks += extra
            }
        }

        // 6-. The right engine, now that we know what the game is ----------------
        // The engine had to be picked before the installer could run, and for an
        // installer that is before anything about the game is knowable. A
        // DirectX 12 title therefore gets built on the general engine and then
        // asks for D3DMetal, which only the Game Porting Toolkit build carries —
        // so the game starts, fails to create a graphics device, and never opens
        // a window. Swap the engine now; the Windows prefix is separate and
        // survives untouched.
        if finalPrescription.needsRosetta, !Runtime.hasGPTK(wrapper) {
            progress(.init(en: "Switching to the DirectX 12 engine",
                           es: "Cambiando al motor de DirectX 12", fraction: 0.89))
            do {
                let gptk = try await runtime.ensureEngineUnpacked(Runtime.gptkEngine) { p in
                    progress(.init(en: p.stageEN, es: p.stageES, fraction: 0.89))
                }
                try builder.replaceEngine(in: wrapper, withUnpacked: gptk)
            } catch {
                warnings.append("This game wants DirectX 12, and the engine that provides it could not be installed: \(error)")
            }
        }

        // 6-. Saved progress from a previous install -----------------------------
        let restored = gameData.restoreSaves(into: gameDir)
        if restored > 0 {
            progress(.init(en: "Restored \(restored) saved files",
                           es: "Restaurados \(restored) archivos guardados", fraction: 0.905))
        }

        // 6a. Data the installer skipped -----------------------------------------
        // A silent install is not always a complete one. Where the missing
        // piece is known and freely available, fetch it here rather than
        // leaving the game to ask — its own downloader runs inside the prefix
        // and is markedly less reliable than ours.
        let missingPacks = ContentPack.missing(for: gameDir)
        if !missingPacks.isEmpty {
            let installer = ContentPackInstaller()
            for pack in missingPacks {
                progress(.init(en: "Fetching \(pack.summaryEN)",
                               es: "Descargando \(pack.summaryES)", fraction: 0.90))
                do {
                    try await installer.install(pack, into: gameDir)
                } catch {
                    warnings.append("Could not add \(pack.summaryEN): \(error)")
                }
            }
        }

        // 6b. Newest graphics layer ---------------------------------------------
        // The engine ships whatever DXMT existed when it was built. Since the
        // renderer was chosen deliberately, keeping it current is free speed.
        if finalPrescription.renderer == .dxmt {
            progress(.init(en: "Installing the latest Direct3D 11 layer",
                           es: "Instalando la última capa de Direct3D 11", fraction: 0.92))
            do {
                let layers = TranslationLayers()
                let root = try await layers.ensure(TranslationLayers.dxmt)
                try layers.install(root, into: wrapper)
            } catch {
                warnings.append("Kept the engine's own Direct3D 11 layer: \(error)")
            }
        }

        // 7. Wire the bundle up -------------------------------------------------
        progress(.init(en: "Finishing the app", es: "Terminando la app", fraction: 0.94))
        guard let winPath = wrapper.windowsPath(for: gameExe) else {
            throw PipelineError.gameNotFoundAfterInstall
        }
        try builder.configure(wrapper, name: gameName, exeWindowsPath: winPath,
                              prescription: finalPrescription, iconSource: gameExe,
                              launcher: launcherBinary)
        try applyRendererOverrides(finalPrescription, engine: engine)

        engine.waitForServerIdle()
        engine.killServer()

        // 8. Prove it actually starts, and that it can be played -----------------
        progress(.init(en: "Checking that it starts", es: "Comprobando que arranca", fraction: 0.96))
        let smoke = SmokeTest(engine: engine, wrapper: wrapper)
        let verdict = smoke.run(exeWindowsPath: winPath,
                                arguments: finalPrescription.launchArguments)
        if !verdict.passed, let diagnosis = verdict.diagnosisEN {
            warnings.append(diagnosis)
        }

        // A window is not the same as a game that looks right. Read the frame
        // the game drew and, if it is wrong, work through configurations until
        // one is not. This is the only stage that can catch a renderer that
        // technically works and visibly does not.
        var repair: AutoRepair.Outcome?
        if verdict.passed {
            progress(.init(en: "Checking how it looks", es: "Comprobando cómo se ve", fraction: 0.97))
            let repairer = AutoRepair(engine: engine, wrapper: wrapper, workDir: workDir)
            let outcome = repairer.repair(exeWindowsPath: winPath,
                                          executableName: gameExe.lastPathComponent,
                                          baseArguments: finalPrescription.launchArguments,
                                          engineName: finalPrescription.engineName,
                                          renderer: finalPrescription.renderer) { en, es in
                progress(.init(en: en, es: es, fraction: 0.975))
            }
            repair = outcome
            if !outcome.extraArguments.isEmpty {
                finalPrescription.launchArguments += outcome.extraArguments
                try? builder.configure(wrapper, name: gameName, exeWindowsPath: winPath,
                                       prescription: finalPrescription, iconSource: nil,
                                       launcher: nil)
            }
            if !outcome.finalVerdict.isHealthy {
                warnings.append("The picture still looks wrong: \(outcome.finalVerdict.summaryEN)")
            }
        }

        // A window is not the same as a playable game. Send real keyboard and
        // mouse events and watch the game's own pixels for a reaction.
        var inputReport: InputCheck.Report?
        if verdict.passed, checkInput {
            progress(.init(en: "Checking keyboard and mouse",
                           es: "Comprobando teclado y ratón", fraction: 0.98))
            inputReport = smoke.runWithInputCheck(exeWindowsPath: winPath,
                                                  executableName: gameExe.lastPathComponent,
                                                  arguments: finalPrescription.launchArguments)
            if let report = inputReport, report.keyboard != .delivered, report.mouse != .delivered {
                warnings.append("Wine did not deliver any test keyboard or mouse events to the game window.")
            }
        }

        // Refresh Launch Services so the icon appears immediately instead of
        // after a random delay or a logout.
        _ = Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                      ["-f", destination.path], timeout: 30)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)

        succeeded = true
        progress(.init(en: "Ready", es: "Listo", fraction: 1.0))

        // When a silent install produced a game that will not start, the
        // installer's own UI is the reliable way out. Keep it reachable
        // instead of leaving the user with a broken icon and no explanation.
        let fallbackInstaller: URL? = {
            guard !verdict.passed, source.needsInstaller else { return nil }
            return stashInstaller(source.mainExecutable, in: wrapper)
        }()

        return Outcome(appPath: destination, name: gameName, warnings: warnings,
                       verdict: verdict, input: inputReport, display: repair,
                       installerForManualRun: fallbackInstaller)
    }

    /// Copies the installer inside the bundle so "run it yourself" still works
    /// after the disc is ejected or the download is deleted.
    func stashInstaller(_ installer: URL, in wrapper: Wrapper) -> URL? {
        let dir = wrapper.driveC.appendingPathComponent("Proteus")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(installer.lastPathComponent)
        if !fm.fileExists(atPath: destination.path) {
            guard (try? fm.copyItem(at: installer, to: destination)) != nil else { return nil }
        }
        return destination
    }

    /// Finishes a wrapper whose install completed but was never configured.
    ///
    /// An install can be interrupted after the files have landed — the window
    /// closed, the machine slept, the app was quit. The installer itself is a
    /// separate process and carries on regardless, so the game ends up fully
    /// present inside a bundle that still thinks it is empty: no program set,
    /// no icon, no renderer. Everything after the copy is repeatable, so rather
    /// than throw away a finished 40 GB install, pick it up where it stopped.
    public func finishInterrupted(app: URL,
                                  progress: @Sendable @escaping (Stage) -> Void) async throws -> Outcome {
        let wrapper = Wrapper(bundle: app)
        let engine = WineEngine(wrapper: wrapper)
        var warnings: [String] = []
        let gameName = (try? wrapper.plist()["CFBundleName"] as? String) as? String
            ?? app.deletingPathExtension().lastPathComponent

        progress(.init(en: "Looking for the game", es: "Buscando el juego", fraction: 0.3))
        let scanner = SourceScanner(workDir: workDir)
        guard let gameDir = findFreshInstall(in: wrapper, excluding: URL(fileURLWithPath: "/nowhere")) else {
            throw PipelineError.gameNotFoundAfterInstall
        }
        let executables = try scanner.findExecutables(in: gameDir)
        guard !executables.isEmpty else { throw PipelineError.gameNotFoundAfterInstall }
        let gameExe = (try? scanner.pickGameExecutable(from: executables, root: gameDir)) ?? executables[0]

        progress(.init(en: "Working out what it needs",
                       es: "Averiguando lo que necesita", fraction: 0.5))
        var prescription = Prescription()
        if let pe = try? PEFile(url: gameExe) {
            let siblings = (try? fm.contentsOfDirectory(at: gameExe.deletingLastPathComponent(),
                                                        includingPropertiesForKeys: nil)) ?? []
            let others = executables.prefix(10).filter { $0 != gameExe }.compactMap { try? PEFile(url: $0) }
            let engineFingerprint = EngineFingerprint.detect(root: gameExe.deletingLastPathComponent(),
                                                             executables: executables)
            prescription = DependencyResolver.resolve(.init(
                mainExe: pe, otherExes: Array(others), siblingFiles: siblings,
                dynamicDLLs: pe.dynamicallyLoadedDLLs(), engine: engineFingerprint,
                installedBytes: directorySize(gameDir)))
        }

        // The engine may be the wrong one: a DirectX 12 game built on the
        // general engine has no D3DMetal and cannot start.
        if prescription.needsRosetta, !Runtime.hasGPTK(wrapper) {
            progress(.init(en: "Switching to the DirectX 12 engine",
                           es: "Cambiando al motor de DirectX 12", fraction: 0.55))
            do {
                let gptk = try await runtime.ensureEngineUnpacked(Runtime.gptkEngine)
                let swapper = WrapperBuilder(template: app, engineRoot: gptk)
                try swapper.replaceEngine(in: wrapper, withUnpacked: gptk)
            } catch {
                warnings.append("Could not install the DirectX 12 engine: \(error)")
            }
        }

        // Anything the game still needs that a silent install would have missed.
        for pack in ContentPack.missing(for: gameDir) {
            progress(.init(en: "Fetching \(pack.summaryEN)",
                           es: "Descargando \(pack.summaryES)", fraction: 0.6))
            do { try await ContentPackInstaller().install(pack, into: gameDir) }
            catch { warnings.append("Could not add \(pack.summaryEN): \(error)") }
        }

        progress(.init(en: "Finishing the app", es: "Terminando la app", fraction: 0.8))
        guard let winPath = wrapper.windowsPath(for: gameExe) else {
            throw PipelineError.gameNotFoundAfterInstall
        }
        let builder = WrapperBuilder(template: app, engineRoot: app)
        try builder.configure(wrapper, name: gameName, exeWindowsPath: winPath,
                              prescription: prescription, iconSource: gameExe,
                              launcher: launcherBinary)

        progress(.init(en: "Checking that it starts", es: "Comprobando que arranca", fraction: 0.9))
        let smoke = SmokeTest(engine: engine, wrapper: wrapper)
        let verdict = smoke.run(exeWindowsPath: winPath, arguments: prescription.launchArguments)
        if !verdict.passed, let diagnosis = verdict.diagnosisEN { warnings.append(diagnosis) }
        engine.killServer()

        _ = Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                      ["-f", app.path], timeout: 30)
        progress(.init(en: "Ready", es: "Listo", fraction: 1.0))
        return Outcome(appPath: app, name: gameName, warnings: warnings,
                       verdict: verdict, input: nil, display: nil, installerForManualRun: nil)
    }

    /// Runs an installer with its interface visible, for when silent mode left
    /// something out. Blocks until the user finishes.
    public func runInstallerInteractively(app: URL, installer: URL) throws {
        let wrapper = Wrapper(bundle: app)
        let engine = WineEngine(wrapper: wrapper)
        guard let winPath = wrapper.windowsPath(for: installer) else { return }
        _ = try engine.run([winPath], timeout: 3600)
        engine.waitForServerIdle()
        engine.killServer()
    }

    // MARK: - Steps

    func copyPortable(source: GameSource, into wrapper: Wrapper, name: String) throws -> URL {
        let games = wrapper.driveC.appendingPathComponent("Games")
        try fm.createDirectory(at: games, withIntermediateDirectories: true)
        let destination = games.appendingPathComponent(sanitize(name))
        try? fm.removeItem(at: destination)

        // Copy the folder that holds the executable, not the whole disc: an ISO
        // root full of redistributables would double the app size for nothing.
        let sourceDir = source.mainExecutable.deletingLastPathComponent()
        let root = sourceDir.path.hasPrefix(source.root.path) ? sourceDir : source.root
        try fm.copyItem(at: root, to: destination)

        // Discs are read-only; a game that cannot write its save file looks
        // broken in a way the user will blame on us.
        clearReadOnly(at: destination)
        return destination
    }

    func runInstaller(source: GameSource, wrapper: Wrapper, engine: WineEngine,
                      name: String, warnings: inout [String],
                      progress: @Sendable (Stage) -> Void) throws -> URL {
        let installer = source.mainExecutable
        let framework = InstallerDetector.framework(of: installer)
        let targetWindows = "C:\\Games\\" + sanitize(name)
        let targetURL = wrapper.driveC.appendingPathComponent("Games").appendingPathComponent(sanitize(name))
        try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)

        // Silence for the duration. A silent install has no window, so music
        // coming out of nowhere with nothing on screen to stop it reads as a
        // fault rather than a feature. Sound goes back on below — muting the
        // prefix permanently would leave the game itself silent.
        //
        // Deliberately not fatal: a prefix that will not take this setting is
        // still a prefix that can install a game.
        try? engine.setAudioEnabled(false)
        defer { try? engine.setAudioEnabled(true) }

        // Discs must be visible to the installer; map the source root as D:.
        if source.kind == .disc {
            linkDrive(letter: "d", to: source.root, in: wrapper)
        }

        // Windows Installer packages are not run, they are handed to msiexec.
        if framework == .msi {
            progress(.init(en: "Installing \(name)", es: "Instalando \(name)",
                           fraction: 0.74, detail: framework.rawValue))
            let began = Date()
            let estimate = estimatedSize(for: source, installer: installer)
            let result = try engine.runWatchingProgress(
                MSIPackage.silentArguments(for: installer, targetWindowsPath: targetWindows),
                watching: watchedDirectories(wrapper, target: targetURL),
                workingDirectory: installer.deletingLastPathComponent()) { activity in
                    progress(Self.installProgress(name: name, activity: activity,
                                                  estimate: estimate, framework: framework,
                                                  began: began))
                }
            engine.waitForServerIdle()
            if installedSomething(at: targetURL) { return targetURL }
            if let discovered = findFreshInstall(in: wrapper, excluding: targetURL) { return discovered }
            throw PipelineError.installerFailed(
                Self.meaningfulTail(result.stdout + result.stderr))
        }

        var attempts = framework.silentFlags
        if attempts.isEmpty { attempts = [["/S"], ["/silent"], ["/quiet"]] }

        var lastLog = ""
        for (index, flags) in attempts.enumerated() {
            var args = [installer.path] + flags
            if let dirFlag = framework.honoursDirFlag {
                // NSIS demands /D= last and unquoted; the closure encodes that.
                args += dirFlag(targetWindows)
            }
            progress(.init(en: "Installing \(name)", es: "Instalando \(name)",
                           fraction: 0.74, detail: framework.rawValue))
            // Report the bytes as they land. A big game spends half an hour or
            // more here, and a progress bar that has not moved is
            // indistinguishable from a hang — the user closes the window and
            // loses the work, which is exactly what happened before this.
            let began = Date()
            let estimate = estimatedSize(for: source, installer: installer)
            let result = try engine.runWatchingProgress(
                args,
                watching: watchedDirectories(wrapper, target: targetURL),
                workingDirectory: installer.deletingLastPathComponent()) { activity in
                    progress(Self.installProgress(name: name, activity: activity,
                                                  estimate: estimate, framework: framework,
                                                  began: began))
                }
            engine.waitForServerIdle()
            lastLog = Self.meaningfulTail(result.stdout + result.stderr)

            if installedSomething(at: targetURL) { return targetURL }
            // Installers that ignore our target directory still install; go
            // find where they actually put it before giving up.
            if let discovered = findFreshInstall(in: wrapper, excluding: targetURL) {
                return discovered
            }
            if index == attempts.count - 1 {
                throw PipelineError.installerFailed(
                    lastLog.isEmpty ? "\(framework.rawValue) produced no files" : lastLog)
            }
            warnings.append("Silent install with \(flags.joined(separator: " ")) produced nothing; retrying")
        }
        throw PipelineError.installerFailed(lastLog)
    }

    /// MoltenVK announces its whole feature set on every launch. Left in, it
    /// buries the one line that says why an installer failed.
    static func meaningfulTail(_ log: String, lines: Int = 6) -> String {
        let noise = ["mvk-info", "vk_khr", "vk_ext", "vk_mvk", "gpu family", "gpu memory",
                     "metal shading", "read-write texture", "vulkan extensions",
                     "pipelinecacheuuid", "vendorid", "deviceid", "supports the following"]
        let kept = log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let lower = line.lowercased()
                return !line.isEmpty && !noise.contains { lower.contains($0) }
                    && !lower.hasPrefix("model:") && !lower.hasPrefix("type:")
            }
        return kept.suffix(lines).joined(separator: " / ")
    }

    /// Places an installer may write to.
    ///
    /// The destination alone is not enough: Inno Setup unpacks everything into
    /// the Windows temp directory first and only then copies it into place, so
    /// watching only the target shows a few megabytes and then nothing for the
    /// whole extraction — which reads exactly like a hang.
    func watchedDirectories(_ wrapper: Wrapper, target: URL) -> [URL] {
        var directories = [target,
                           wrapper.driveC.appendingPathComponent("Program Files"),
                           wrapper.driveC.appendingPathComponent("Program Files (x86)"),
                           wrapper.driveC.appendingPathComponent("Games")]
        let users = wrapper.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            directories.append(user.appendingPathComponent("Temp"))
            directories.append(user.appendingPathComponent("AppData/Local/Temp"))
        }
        directories.append(wrapper.driveC.appendingPathComponent("windows/temp"))
        return directories
    }

    /// Whether the install would run the disk dry, and by how much.
    ///
    /// The wrapper itself costs about 2 GB (engine plus a fresh Windows), and
    /// the game costs roughly what its source holds. A margin is kept on top,
    /// because a disk with nothing left over is its own kind of broken.
    func spaceShortfall(for source: GameSource, engineBytes: Int64) -> (needed: Int64, free: Int64)? {
        let installRootPath = installRoot.path
        guard let attributes = try? fm.attributesOfFileSystem(forPath: installRootPath),
              let free = attributes[.systemFreeSize] as? Int64 else { return nil }

        let payload = source.mountedVolume != nil
            ? directorySize(source.root, limit: 40_000)
            : Self.estimatedInstalledSize(of: source.mainExecutable)
        guard payload > 0 else { return nil }

        let margin: Int64 = 2_000_000_000
        let needed = payload + engineBytes + margin
        return free < needed ? (needed, free) : nil
    }

    /// The estimate has to come from the thing that holds the data.
    ///
    /// For a disc that is the disc: the `setup.exe` sitting on a 39 GB image is
    /// a few megabytes, and estimating from it puts the finished size at maybe
    /// 12 MB — which the install passes in seconds, so the percentage vanishes
    /// immediately and never comes back. The user sees a byte counter and no
    /// bar for the entire install.
    func estimatedSize(for source: GameSource, installer: URL) -> Int64 {
        if source.mountedVolume != nil {
            // What the disc actually carries, which is close to what lands.
            let size = directorySize(source.root, limit: 40_000)
            if size > 0 { return size }
        }
        return Self.estimatedInstalledSize(of: installer)
    }

    /// A rough finished size, so the bar can move.
    ///
    /// Nobody can know the real total before the install ends, but "roughly
    /// right and moving" beats "exact and absent". A compressed installer
    /// expands to a few times its own size; a disc image lands at about what it
    /// already occupies. The estimate is only ever used to draw a bar, and it
    /// is capped below 100% so it cannot claim to be finished.
    static func estimatedInstalledSize(of source: URL) -> Int64 {
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > 0 else { return 0 }
        let extension_ = source.pathExtension.lowercased()
        // A disc image lands at roughly what it already occupies; a compressed
        // installer expands to a few times its own size.
        let factor: Double = (extension_ == "iso" || extension_ == "img") ? 1.0 : 2.5
        return Int64(Double(size) * factor)
    }

    /// Progress as a fraction, or nil when the estimate has been overtaken.
    ///
    /// Capping at 99% sounds harmless and is not: a game that installs more
    /// than the estimate sits at 99% for the rest of the run, which is exactly
    /// the "it stopped" feeling this whole mechanism exists to remove. Past
    /// 95% of the estimate the number is no longer trustworthy, so it goes away
    /// and the byte counter — which is always true — carries on alone.
    static func installShare(bytes: Int64, estimate: Int64) -> Double? {
        guard estimate > 0 else { return nil }
        let share = Double(bytes) / Double(estimate)
        return share < 0.95 ? share : nil
    }

    /// Turns one sample of installer activity into something worth reading.
    ///
    /// There are three states and they need saying differently, because the
    /// only failure that matters here is a person concluding it has hung and
    /// closing the window — which throws away the whole install.
    ///
    /// - Writing files: bytes, and a percentage while the estimate still holds.
    /// - Working with nothing to show: say *that*, and drop the percentage.
    ///   A compressed installer decompresses for minutes at a time; a bar
    ///   frozen at 41% reads as broken, "Extracting" reads as busy.
    /// - Past the estimate: the estimate was wrong. The byte count is always
    ///   true, so it carries on alone.
    static func installProgress(name: String,
                                activity: WineEngine.InstallActivity,
                                estimate: Int64,
                                framework: InstallerDetector.Framework,
                                began: Date) -> Stage {
        let elapsed = "\(framework.rawValue) · \(Self.elapsed(since: began))"

        if activity.working {
            let size = activity.bytes > 0 ? " — \(Self.readableSize(activity.bytes))" : ""
            return .init(en: "Extracting \(name)\(size) — this part can take a while",
                         es: "Extrayendo \(name)\(size) — esta parte puede tardar",
                         fraction: nil,
                         detail: elapsed)
        }

        let share = Self.installShare(bytes: activity.bytes, estimate: estimate)
        let percent = share.map { " (\(Int($0 * 100))%)" } ?? ""
        return .init(en: "Installing \(name) — \(Self.readableSize(activity.bytes))\(percent)",
                     es: "Instalando \(name) — \(Self.readableSize(activity.bytes))\(percent)",
                     fraction: share,
                     detail: elapsed)
    }

    /// "3 min" reads as progress; a raw timestamp does not.
    static func elapsed(since start: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func readableSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func installedSomething(at url: URL) -> Bool {
        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.contains { $0.lowercased().hasSuffix(".exe") }
            || contents.count > 2
    }

    /// Installers routinely land in Program Files regardless of what we asked.
    func findFreshInstall(in wrapper: Wrapper, excluding: URL) -> URL? {
        let roots = ["Program Files", "Program Files (x86)", "Games"]
            .map { wrapper.driveC.appendingPathComponent($0) }
        var best: (url: URL, size: Int)?
        for root in roots {
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children {
                guard child != excluding,
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                // Wine seeds these; they are never the game.
                let name = child.lastPathComponent.lowercased()
                if ["windows nt", "internet explorer", "common files", "windows media player",
                    "microsoft", "uninstall information"].contains(where: { name.contains($0) }) { continue }
                let exeCount = ((try? fm.contentsOfDirectory(atPath: child.path)) ?? [])
                    .filter { $0.lowercased().hasSuffix(".exe") }.count
                guard exeCount > 0 else { continue }
                if best == nil || exeCount > best!.size { best = (child, exeCount) }
            }
        }
        return best?.url
    }

    func linkDrive(letter: String, to target: URL, in wrapper: Wrapper) {
        let dosDevices = wrapper.prefix.appendingPathComponent("dosdevices")
        try? fm.createDirectory(at: dosDevices, withIntermediateDirectories: true)
        let link = dosDevices.appendingPathComponent("\(letter):")
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    }

    func clearReadOnly(at root: URL) {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        for case let url as URL in e {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? fm.setAttributes([.posixPermissions: isDir ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    func applyRendererOverrides(_ prescription: Prescription, engine: WineEngine) throws {
        // Windowed-by-default: a game that grabs the whole display and then
        // fails leaves the user with no way back except a hard reboot.
        try engine.applyRegistry([
            (path: "HKCU\\Software\\Wine\\X11 Driver", key: "Decorated", type: "REG_SZ", value: "Y"),
            (path: "HKCU\\Software\\Wine\\X11 Driver", key: "GrabFullscreen", type: "REG_SZ", value: "N"),
        ])
    }

    func uniqueDestination(for name: String) -> URL {
        let base = sanitize(name)
        var candidate = installRoot.appendingPathComponent("\(base).app")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = installRoot.appendingPathComponent("\(base) \(counter).app")
            counter += 1
        }
        return candidate
    }

    func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runtimeCacheDir() -> URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Proteus/Components")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Verb names are jargon; the user gets the product name instead.
    func friendly(_ verb: String) -> String {
        let map = [
            "vcrun2002": "Visual C++ 2002", "vcrun2003": "Visual C++ 2003",
            "vcrun2005": "Visual C++ 2005", "vcrun2008": "Visual C++ 2008",
            "vcrun2010": "Visual C++ 2010", "vcrun2012": "Visual C++ 2012",
            "vcrun2013": "Visual C++ 2013", "vcrun2022": "Visual C++ 2015-2022",
            "d3dx9": "DirectX 9 libraries", "d3dx11_43": "DirectX 11 libraries",
            "d3dcompiler_43": "shader compiler", "d3dcompiler_47": "shader compiler",
            "openal": "OpenAL audio", "physx": "PhysX", "mfc42": "MFC 4.2",
        ]
        return map[verb] ?? verb
    }
}
