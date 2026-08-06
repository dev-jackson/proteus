// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// What a game needs in order to run, derived from evidence rather than
/// guesswork. Every field carries the reason it was set so the UI can explain
/// itself instead of showing a wall of checkboxes.
public struct Prescription: Sendable {
    public struct Reason: Sendable, Hashable {
        public let requirement: String   // human label, EN
        public let requirementES: String // human label, ES
        public let evidence: String      // "imports d3d9.dll"
        public init(requirement: String, requirementES: String, evidence: String) {
            self.requirement = requirement
            self.requirementES = requirementES
            self.evidence = evidence
        }
    }

    /// Graphics backend chosen for the wrapper.
    public enum Renderer: String, Sendable {
        /// The game speaks OpenGL or Vulkan directly and never asks for
        /// Direct3D. Naming a DirectX translator for it is not merely useless,
        /// it is misleading — and it sent the repair loop off trying to fix a
        /// colour problem by swapping translators the game does not use.
        case native       // no DirectX at all
        case wined3d      // safest, OpenGL-backed, best for DX ≤9 and 2D
        case dxmt         // DX10/11 via Metal
        case d3dmetal     // DX11/12 via Metal (Apple's, needs Rosetta)
        case dxvk         // DX10/11 via Vulkan/MoltenVK

        public var plistKeys: [String: Bool] {
            [
                "DXMT": self == .dxmt,
                "D3DMETAL": self == .d3dmetal,
                "DXVK": self == .dxvk,
            ]
        }

        /// Whether swapping DirectX translators could possibly help this game.
        public var translatesDirectX: Bool { self != .native }

        public var summaryEN: String {
            switch self {
            case .native: return "native OpenGL/Vulkan — no DirectX translation"
            case .wined3d: return "DirectX → OpenGL (WineD3D)"
            case .dxmt: return "DirectX 11 → Metal (DXMT)"
            case .d3dmetal: return "DirectX 12 → Metal (D3DMetal)"
            case .dxvk: return "DirectX → Vulkan → Metal (DXVK)"
            }
        }

        public var summaryES: String {
            switch self {
            case .native: return "OpenGL/Vulkan nativo — sin traducción DirectX"
            case .wined3d: return "DirectX → OpenGL (WineD3D)"
            case .dxmt: return "DirectX 11 → Metal (DXMT)"
            case .d3dmetal: return "DirectX 12 → Metal (D3DMetal)"
            case .dxvk: return "DirectX → Vulkan → Metal (DXVK)"
            }
        }
    }

    public var renderer: Renderer = .native
    /// winetricks verbs to install before first launch.
    public var winetricks: [String] = []
    /// Wrapper Info.plist toggles, keyed exactly as the wrapper expects them.
    public var plistOverrides: [String: Int] = [:]
    public var reasons: [Reason] = []
    /// Set when the binary is 32-bit — worth surfacing, still supported.
    public var is32Bit = false
    public var needsRosetta = false
    /// Which input devices the game actually talks to, so the review screen can
    /// say what will work rather than leaving the user to find out.
    public var usesKeyboard = true
    public var usesMouse = false
    public var usesGamepad = false
    public var engineName: String?
    /// Arguments that skip a chooser and start the game itself.
    public var launchArguments: [String] = []

    public init() {}
}

/// Everything we managed to observe about a game before deciding anything.
/// Collected in one place so the resolver has a single input and the reasoning
/// stays auditable.
public struct Evidence: Sendable {
    public let mainExe: PEFile
    public let otherExes: [PEFile]
    /// Files sitting next to the game, used for bundled-DLL and disc checks.
    public let siblingFiles: [URL]
    /// DLLs named in the binary but absent from its import table: everything a
    /// modern engine loads at run time.
    public let dynamicDLLs: Set<String>
    public let engine: EngineFingerprint
    /// Hand-written knowledge about this specific game, where evidence ends.
    public let known: KnownTitle?
    public let analysingInstaller: Bool
    /// Total size of the game on disk, used to tell a 2 MB freeware platformer
    /// from a multi-gigabyte 3D title. They want opposite trade-offs.
    public let installedBytes: Int64

    /// A game worth spending GPU translation on: big, or built with an engine
    /// that is 3D by definition. These get the fastest path even when it is the
    /// less battle-tested one, because the slow path makes them unplayable.
    public var looksDemanding: Bool {
        if [.unreal, .unity, .idTech].contains(engine.engine) { return true }
        return installedBytes > 300_000_000
    }

    public init(mainExe: PEFile, otherExes: [PEFile] = [], siblingFiles: [URL] = [],
                dynamicDLLs: Set<String> = [], engine: EngineFingerprint = .none,
                known: KnownTitle? = nil,
                analysingInstaller: Bool = false, installedBytes: Int64 = 0) {
        self.installedBytes = installedBytes
        self.known = known
        self.mainExe = mainExe
        self.otherExes = otherExes
        self.siblingFiles = siblingFiles
        self.dynamicDLLs = dynamicDLLs
        self.engine = engine
        self.analysingInstaller = analysingInstaller
    }
}

/// Maps observed imports and on-disk evidence to concrete runtime setup.
/// This is the part every other tool leaves to the user.
public enum DependencyResolver {

    /// One rule: if any of `dlls` is imported, apply `apply`.
    struct Rule {
        let dlls: [String]
        let requirement: String
        let requirementES: String
        let apply: (inout Prescription) -> Void
    }

    // Visual C++ runtimes. Wine ships none of these; a missing msvcp140.dll is
    // the single most common "game does nothing when I double-click" cause.
    static let vcRuntimes: [(dll: String, verb: String, label: String)] = [
        ("msvcr70.dll",   "vcrun2002", "Visual C++ 2002"),
        ("msvcr71.dll",   "vcrun2003", "Visual C++ 2003"),
        ("msvcr80.dll",   "vcrun2005", "Visual C++ 2005"),
        ("msvcp80.dll",   "vcrun2005", "Visual C++ 2005"),
        ("msvcr90.dll",   "vcrun2008", "Visual C++ 2008"),
        ("msvcp90.dll",   "vcrun2008", "Visual C++ 2008"),
        ("msvcr100.dll",  "vcrun2010", "Visual C++ 2010"),
        ("msvcp100.dll",  "vcrun2010", "Visual C++ 2010"),
        ("msvcr110.dll",  "vcrun2012", "Visual C++ 2012"),
        ("msvcp110.dll",  "vcrun2012", "Visual C++ 2012"),
        ("msvcr120.dll",  "vcrun2013", "Visual C++ 2013"),
        ("msvcp120.dll",  "vcrun2013", "Visual C++ 2013"),
        ("msvcr140.dll",  "vcrun2022", "Visual C++ 2015-2022"),
        ("msvcp140.dll",  "vcrun2022", "Visual C++ 2015-2022"),
        ("vcruntime140.dll", "vcrun2022", "Visual C++ 2015-2022"),
        ("vcruntime140_1.dll", "vcrun2022", "Visual C++ 2015-2022"),
        ("mfc42.dll",     "mfc42",     "MFC 4.2"),
        ("mfc140u.dll",   "vcrun2022", "Visual C++ 2015-2022"),
    ]

    /// Runtime assemblies a manifest can name, and the component that supplies
    /// each. Far more reliable than inferring a version from a DLL file name.
    static let manifestRuntimes: [String: String] = [
        "Microsoft.VC80.CRT": "vcrun2005",
        "Microsoft.VC80.MFC": "vcrun2005",
        "Microsoft.VC80.ATL": "vcrun2005",
        "Microsoft.VC90.CRT": "vcrun2008",
        "Microsoft.VC90.MFC": "vcrun2008",
        "Microsoft.VC90.ATL": "vcrun2008",
        "Microsoft.VC100.CRT": "vcrun2010",
        "Microsoft.VC110.CRT": "vcrun2012",
        "Microsoft.VC120.CRT": "vcrun2013",
        "Microsoft.VC140.CRT": "vcrun2022",
    ]

    static let runtimeLabels: [String: String] = [
        "vcrun2005": "Visual C++ 2005", "vcrun2008": "Visual C++ 2008",
        "vcrun2010": "Visual C++ 2010", "vcrun2012": "Visual C++ 2012",
        "vcrun2013": "Visual C++ 2013", "vcrun2022": "Visual C++ 2015-2022",
    ]

    /// - Parameter analysingInstaller: when true the binary being read is a
    ///   setup program, not the game. Installers link `ddraw` for their splash
    ///   screen and ship their own runtime checks, so believing their import
    ///   table produces confident nonsense. Only disc-level evidence counts.
    public static func resolve(_ evidence: Evidence) -> Prescription {
        let mainExe = evidence.mainExe
        let siblingFiles = evidence.siblingFiles
        var p = Prescription()
        if evidence.analysingInstaller {
            return resolveFromDisc(files: siblingFiles, is32Bit: mainExe.machine == .i386)
        }
        p.engineName = evidence.engine.engine == .unknown ? nil : evidence.engine.engine.rawValue

        // Consider DLLs imported by the main binary plus any other executable
        // shipped next to it — launchers routinely defer the real work — and
        // the ones loaded at run time, which is how every engine since about
        // 2005 selects its renderer.
        var imports = Set(mainExe.importedDLLs)
        // Delay-loaded libraries are declared dependencies too — a game that
        // delay-loads Direct3D so it can fall back gracefully still needs it.
        imports.formUnion(mainExe.delayImportedDLLs)
        for exe in evidence.otherExes {
            imports.formUnion(exe.importedDLLs)
            imports.formUnion(exe.delayImportedDLLs)
        }
        let dynamic = evidence.dynamicDLLs
        /// True when the game references a library at all, statically or not.
        func uses(_ name: String) -> Bool { imports.contains(name) || dynamic.contains(name) }
        func usesAny(prefix: String) -> Bool {
            imports.contains { $0.hasPrefix(prefix) } || dynamic.contains { $0.hasPrefix(prefix) }
        }

        // Bundled DLLs sitting next to the exe are already satisfied; don't
        // install a system copy over the game's own build.
        let bundled = Set(siblingFiles
            .filter { $0.pathExtension.lowercased() == "dll" }
            .map { $0.lastPathComponent.lowercased() })

        p.is32Bit = mainExe.machine == .i386

        // --- Graphics -------------------------------------------------------
        func note(_ en: String, _ es: String, _ evidence: String) {
            p.reasons.append(.init(requirement: en, requirementES: es, evidence: evidence))
        }

        /// Says whether the evidence for a library was a real import or a
        /// run-time load, so the reason line stays honest about its source.
        func how(_ name: String) -> String {
            imports.contains(name) ? "imports \(name)" : "loads \(name) at run time"
        }

        if uses("d3d12.dll") || uses("d3d12core.dll") {
            p.renderer = .d3dmetal
            p.needsRosetta = true
            note("DirectX 12 → Metal", "DirectX 12 → Metal", how("d3d12.dll"))
        } else if uses("d3d11.dll") || uses("dxgi.dll") {
            p.renderer = .dxmt
            note("DirectX 11 → Metal", "DirectX 11 → Metal",
                 how(uses("d3d11.dll") ? "d3d11.dll" : "dxgi.dll"))
        } else if uses("d3d10.dll") || uses("d3d10_1.dll") {
            p.renderer = .dxmt
            note("DirectX 10 → Metal", "DirectX 10 → Metal", how("d3d10.dll"))
        } else if uses("d3d9.dll") || uses("d3d8.dll") {
            // A demanding DirectX 9 game wants the GPU, and DXVK reaches Metal
            // through Vulkan far faster than wined3d's OpenGL path. A small 2D
            // game does not care about throughput and gains from wined3d being
            // the better-tested route, so the choice follows the workload.
            if evidence.looksDemanding {
                p.renderer = .dxvk
                note("DirectX 9 → Vulkan → Metal (for speed)",
                     "DirectX 9 → Vulkan → Metal (por velocidad)",
                     how(uses("d3d9.dll") ? "d3d9.dll" : "d3d8.dll") + ", demanding 3D game")
            } else {
                p.renderer = .wined3d
                note("DirectX 9 (OpenGL translation)", "DirectX 9 (traducción a OpenGL)",
                     how(uses("d3d9.dll") ? "d3d9.dll" : "d3d8.dll"))
            }
        } else if uses("ddraw.dll") {
            p.renderer = .wined3d
            note("DirectDraw (legacy 2D)", "DirectDraw (2D antiguo)", how("ddraw.dll"))
        } else if uses("vulkan-1.dll") {
            // Vulkan reaches Metal through MoltenVK, which the wrapper already
            // carries. No DirectX translator belongs in the way, and claiming
            // one would be a lie about what the game does.
            p.renderer = .native
            p.plistOverrides["MOLTENVKCX"] = 1
            note("Vulkan → Metal (MoltenVK)", "Vulkan → Metal (MoltenVK)", how("vulkan-1.dll"))
        } else if uses("opengl32.dll") {
            p.renderer = .native
            note("OpenGL, translated natively by Wine",
                 "OpenGL, traducido nativamente por Wine", how("opengl32.dll"))
        } else {
            // Nothing said what it draws with. WineD3D covers the widest range
            // and costs nothing when unused, so it is the safe default.
            p.renderer = .wined3d
        }

        // A game that can do both prefers OpenGL under Wine: MoltenVK adds a
        // translation hop and Vulkan support in Wine is the newer, rougher path.
        if uses("vulkan-1.dll") && uses("opengl32.dll") {
            p.plistOverrides["MOLTENVKCX"] = 1
            note("Prefers OpenGL over Vulkan (steadier under Wine)",
                 "Prefiere OpenGL sobre Vulkan (más estable en Wine)",
                 "offers both renderers")
        }

        // --- C/C++ runtimes -------------------------------------------------
        var verbs: [String] = []
        var seenLabels = Set<String>()

        // The manifest is the authoritative answer where it exists. An import
        // of `msvcp90.dll` leaves the service pack to guesswork; the manifest
        // says `Microsoft.VC90.CRT` outright, so it is read first and the
        // import-name guessing below only fills gaps.
        for assembly in mainExe.manifestAssemblies {
            guard let verb = Self.manifestRuntimes[assembly] ?? Self.manifestRuntimes[
                assembly.split(separator: ".").prefix(2).joined(separator: ".")] else { continue }
            if !verbs.contains(verb) { verbs.append(verb) }
            if seenLabels.insert(verb).inserted {
                note("\(Self.runtimeLabels[verb] ?? verb) runtime",
                     "Runtime de \(Self.runtimeLabels[verb] ?? verb)",
                     "manifest declares \(assembly)")
            }
        }
        for entry in vcRuntimes where imports.contains(entry.dll) && !bundled.contains(entry.dll) {
            if !verbs.contains(entry.verb) { verbs.append(entry.verb) }
            if seenLabels.insert(entry.label).inserted {
                note("\(entry.label) runtime", "Runtime de \(entry.label)", "imports \(entry.dll)")
            }
        }

        // --- .NET -----------------------------------------------------------
        if mainExe.isManagedDotNet || evidence.engine.engine == .dotnet {
            // Wine Mono covers most games; a real .NET install is slow and
            // fragile, so start with Mono and only escalate if launch fails.
            note(".NET runtime (Wine Mono)", "Runtime .NET (Wine Mono)", "carries a CLR header")
            p.plistOverrides["Skip Mono"] = 0
        }

        // --- Audio ----------------------------------------------------------
        if usesAny(prefix: "xaudio2_") {
            note("XAudio2 (FAudio built in)", "XAudio2 (FAudio incluido)", "uses xaudio2_*.dll")
        }
        if uses("openal32.dll") && !bundled.contains("openal32.dll") {
            verbs.append("openal")
            note("OpenAL audio", "Audio OpenAL", how("openal32.dll"))
        }

        if mainExe.requiresAdministrator {
            // Wine grants it without a prompt, but a game that asks is usually
            // one that writes into Program Files, which matters for saves.
            note("Asks to run as administrator", "Pide ejecutarse como administrador",
                 "manifest requestedExecutionLevel")
        }
        if !mainExe.dpiAware, mainExe.machine != .arm64 {
            // A program that never declared DPI awareness is stretched by
            // Windows on a high-density display, and by Wine on a Retina Mac.
            note("Not built for high-density displays — may look soft",
                 "No preparado para pantallas de alta densidad: puede verse borroso",
                 "manifest declares no DPI awareness")
        }

        // --- Input ----------------------------------------------------------
        // Which devices the game listens to decides whether it is playable at
        // all, and it is the question a player actually has. Wine implements
        // every one of these, but saying so up front beats finding out later.
        if usesAny(prefix: "xinput") {
            p.usesGamepad = true
            note("Gamepad (XInput)", "Mando (XInput)", "uses xinput*.dll")
        }
        if uses("dinput8.dll") || uses("dinput.dll") {
            // DirectInput is most often enumerated purely to find a joystick;
            // claiming mouse support from it alone put "mouse" on a
            // keyboard-only game, so mouse has to be proven separately.
            p.usesGamepad = true
            note("Joystick / gamepad (DirectInput)", "Joystick / mando (DirectInput)",
                 how(uses("dinput8.dll") ? "dinput8.dll" : "dinput.dll"))
        }
        // Raw input is how a first-person game reads free mouse-look. It is
        // reached through user32, so the give-away is the symbol, not a DLL.
        if mainExe.referencesSymbol("GetRawInputData") || mainExe.referencesSymbol("RegisterRawInputDevices") {
            p.usesMouse = true
            note("Raw mouse input (free look)", "Entrada de ratón cruda (vista libre)",
                 "calls RegisterRawInputDevices")
        }
        if uses("sdl2.dll") || uses("sdl3.dll") || evidence.engine.engine == .sdl {
            p.usesMouse = true
            p.usesGamepad = true
            note("SDL input — keyboard, mouse and gamepad",
                 "Entrada SDL — teclado, ratón y mando", "ships SDL")
        }
        if evidence.engine.engine == .idTech || evidence.engine.engine == .unreal
            || evidence.engine.engine == .unity {
            p.usesMouse = true
        }

        // --- Physics / middleware -------------------------------------------
        if usesAny(prefix: "physx") && !bundled.contains(where: { $0.hasPrefix("physx") }) {
            verbs.append("physx")
            note("NVIDIA PhysX", "NVIDIA PhysX", "uses physx*.dll")
        }

        // --- Redistributables shipped on the disc ---------------------------
        // An ISO that carries vcredist_x86.exe is telling us exactly what it
        // needs; trust the disc over our own guess and skip the download.
        for file in siblingFiles {
            let n = file.lastPathComponent.lowercased()
            if n.contains("vcredist") {
                note("Visual C++ runtime (found on disc)",
                     "Runtime de Visual C++ (encontrado en el disco)", n)
            }
            if n.contains("directx") || n == "dxsetup.exe" {
                note("DirectX 9 runtime (found on disc)",
                     "Runtime DirectX 9 (encontrado en el disco)", n)
                if !verbs.contains("d3dx9") { verbs.append("d3dx9") }
            }
        }

        // d3dx9_xx.dll is a helper library Wine does not implement; a game that
        // links it will abort at startup without the redistributable.
        if usesAny(prefix: "d3dx9") && !bundled.contains(where: { $0.hasPrefix("d3dx9") }) && !verbs.contains("d3dx9") {
            verbs.append("d3dx9")
            note("D3DX9 helper libraries", "Librerías auxiliares D3DX9", "uses d3dx9_*.dll")
        }
        if usesAny(prefix: "d3dx11") && !bundled.contains(where: { $0.hasPrefix("d3dx11") }) {
            verbs.append("d3dx11_43")
            note("D3DX11 helper libraries", "Librerías auxiliares D3DX11", "uses d3dx11_*.dll")
        }
        if (uses("d3dcompiler_43.dll") || uses("d3dcompiler_47.dll")) && !bundled.contains(where: { $0.hasPrefix("d3dcompiler") }) {
            verbs.append(uses("d3dcompiler_47.dll") ? "d3dcompiler_47" : "d3dcompiler_43")
            note("HLSL shader compiler", "Compilador de shaders HLSL", "uses d3dcompiler_*.dll")
        }

        // What the engine demands that no import table mentions.
        for verb in evidence.engine.requiredVerbs where !verbs.contains(verb) {
            verbs.append(verb)
        }
        for note in evidence.engine.notes {
            p.reasons.append(.init(requirement: note.en, requirementES: note.es,
                                   evidence: evidence.engine.engine.rawValue))
        }

        p.launchArguments = evidence.engine.launchArguments

        // Hand-written knowledge is applied last and says so, because a fact
        // somebody wrote down should be visible as such rather than blended
        // into what the binary appeared to declare.
        if let known = evidence.known {
            if let renderer = known.renderer { p.renderer = renderer }
            p.launchArguments += known.extraArguments
            for verb in known.extraVerbs where !verbs.contains(verb) { verbs.append(verb) }
            if known.needsGPTK { p.needsRosetta = true }
            p.reasons.append(.init(requirement: known.reasonEN, requirementES: known.reasonES,
                                   evidence: "known behaviour of \(known.nameEN)"))
        }
        p.winetricks = verbs
        // Renderer toggles are written for every backend, including the zeroes:
        // (see resolveFromDisc for the installer-only path)
        // a rebuilt wrapper must not inherit a stale flag from the template.
        p.plistOverrides.merge(p.renderer.plistKeys.mapValues { $0 ? 1 : 0 }) { _, new in new }
        return p
    }

    /// Everything we can honestly say before an installer has run: what the
    /// disc itself carries. The real prescription is computed after install,
    /// against the game's own binary.
    public static func resolveFromDisc(files: [URL], is32Bit: Bool) -> Prescription {
        var p = Prescription()
        p.is32Bit = is32Bit
        var verbs: [String] = []
        var seen = Set<String>()

        for file in files {
            let n = file.lastPathComponent.lowercased()
            if n.contains("vcredist"), seen.insert("vc").inserted {
                p.reasons.append(.init(requirement: "Visual C++ runtime (shipped with the game)",
                                       requirementES: "Runtime de Visual C++ (incluido con el juego)",
                                       evidence: n))
            }
            if (n.contains("directx") || n == "dxsetup.exe"), seen.insert("dx").inserted {
                verbs.append("d3dx9")
                p.reasons.append(.init(requirement: "DirectX 9 runtime (shipped with the game)",
                                       requirementES: "Runtime de DirectX 9 (incluido con el juego)",
                                       evidence: n))
            }
            if n.contains("dotnetfx") || n.contains("ndp4"), seen.insert("net").inserted {
                p.reasons.append(.init(requirement: ".NET runtime (shipped with the game)",
                                       requirementES: "Runtime .NET (incluido con el juego)",
                                       evidence: n))
            }
        }
        p.winetricks = verbs
        p.plistOverrides.merge(p.renderer.plistKeys.mapValues { $0 ? 1 : 0 }) { _, new in new }
        return p
    }
}
