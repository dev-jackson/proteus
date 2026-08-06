// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Recognises the engine a game was built with, from the shape of its install
/// directory.
///
/// This is where the difference between "I can run a small game" and "I can run
/// a real one" lives. A Unity or Unreal title is not one executable — it is a
/// launcher stub, a shipping binary buried four folders deep, a crash handler,
/// a redistributable installer and a prerequisites folder. Picking the wrong
/// one produces an app that opens a console window and exits. The engine also
/// dictates settings no import table can reveal.
public struct EngineFingerprint: Sendable {

    public enum Engine: String, Sendable {
        case unity = "Unity"
        case unreal = "Unreal Engine"
        case gameMaker = "GameMaker"
        case godot = "Godot"
        case xna = "XNA / MonoGame"
        case dotnet = ".NET"
        case rpgMaker = "RPG Maker"
        case java = "Java"
        case electron = "Electron"
        case idTech = "id Tech / Doom engine"
        case sdl = "SDL"
        case unknown = "unknown"
    }

    public let engine: Engine
    /// The executable the engine convention says is the real game, if the
    /// layout points at one unambiguously.
    public let preferredExecutable: URL?
    /// Paths that are never the game for this engine.
    public let excludedPaths: [URL]
    /// Extra winetricks verbs this engine is known to need.
    public let requiredVerbs: [String]
    /// Arguments that take the player straight into the game.
    ///
    /// Several engines open a chooser before the game itself — GZDoom asks
    /// which WAD to run, and the answer is always the one WAD that shipped
    /// with it. Passing the answer up front removes a dialog the user did not
    /// ask for, which is the entire point of this project.
    public let launchArguments: [String]
    /// Human-readable notes, bilingual, for the review screen.
    public let notes: [(en: String, es: String)]

    public static let none = EngineFingerprint(engine: .unknown, preferredExecutable: nil,
                                               excludedPaths: [], requiredVerbs: [],
                                               launchArguments: [], notes: [])

    // MARK: - Detection

    public static func detect(root: URL, executables: [URL]) -> EngineFingerprint {
        let fm = FileManager.default
        let names = Set(((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).map { $0.lowercased() })

        func fileExists(_ relative: String) -> Bool {
            fm.fileExists(atPath: root.appendingPathComponent(relative).path)
        }

        // --- Unreal Engine -------------------------------------------------
        // The shipping binary is always <Project>/Binaries/Win64/<X>-Win64-Shipping.exe.
        // The thing at the root is a launcher stub that just re-execs it, and
        // wrapping the stub gives a game that appears to do nothing.
        if let shipping = executables.first(where: {
            $0.lastPathComponent.lowercased().hasSuffix("-win64-shipping.exe")
                || $0.lastPathComponent.lowercased().hasSuffix("-win32-shipping.exe")
        }) {
            return EngineFingerprint(
                engine: .unreal,
                preferredExecutable: shipping,
                excludedPaths: [root.appendingPathComponent("Engine/Extras"),
                                root.appendingPathComponent("Engine/Binaries/ThirdParty")],
                requiredVerbs: [], launchArguments: [],
                notes: [("Unreal Engine — launching the shipping binary directly, not the launcher stub",
                         "Unreal Engine — se ejecuta el binario final, no el lanzador")])
        }

        // --- Unity ----------------------------------------------------------
        // Unity ships `<Game>_Data` beside `<Game>.exe`; that pairing names the
        // real executable even when a dozen others are present.
        if names.contains("unityplayer.dll") || names.contains(where: { $0.hasSuffix("_data") }) {
            let dataFolder = names.first { $0.hasSuffix("_data") }
            let stem = dataFolder.map { String($0.dropLast(5)) }
            let match = stem.flatMap { s in
                executables.first { $0.deletingPathExtension().lastPathComponent.lowercased() == s }
            }
            return EngineFingerprint(
                engine: .unity,
                preferredExecutable: match,
                excludedPaths: [],
                requiredVerbs: [], launchArguments: [],
                notes: [("Unity game — the crash handler is ignored",
                         "Juego Unity — se ignora el gestor de fallos")])
        }

        // --- GameMaker ------------------------------------------------------
        if names.contains("data.win") {
            return EngineFingerprint(
                engine: .gameMaker, preferredExecutable: nil, excludedPaths: [],
                requiredVerbs: [], launchArguments: [],
                notes: [("GameMaker game", "Juego de GameMaker")])
        }

        // --- Godot ----------------------------------------------------------
        if names.contains(where: { $0.hasSuffix(".pck") }) {
            let stem = names.first { $0.hasSuffix(".pck") }.map { String($0.dropLast(4)) }
            let match = stem.flatMap { s in
                executables.first { $0.deletingPathExtension().lastPathComponent.lowercased() == s }
            }
            return EngineFingerprint(
                engine: .godot, preferredExecutable: match, excludedPaths: [],
                requiredVerbs: [], launchArguments: [],
                notes: [("Godot game", "Juego de Godot")])
        }

        // --- RPG Maker ------------------------------------------------------
        if names.contains("www") || names.contains(where: { $0.hasPrefix("rgss") && $0.hasSuffix(".dll") }) {
            return EngineFingerprint(
                engine: .rpgMaker, preferredExecutable: executables.first { $0.lastPathComponent.lowercased() == "game.exe" },
                excludedPaths: [], requiredVerbs: [], launchArguments: [],
                notes: [("RPG Maker game", "Juego de RPG Maker")])
        }

        // --- XNA / MonoGame --------------------------------------------------
        if names.contains("microsoft.xna.framework.dll")
            || names.contains(where: { $0.hasPrefix("microsoft.xna.framework") }) {
            return EngineFingerprint(
                engine: .xna, preferredExecutable: nil, excludedPaths: [],
                requiredVerbs: ["xna40"], launchArguments: [],
                notes: [("XNA game — the XNA runtime is installed for it",
                         "Juego XNA — se instala el runtime de XNA")])
        }

        // --- .NET -------------------------------------------------------------
        if names.contains(where: { $0.hasSuffix(".runtimeconfig.json") })
            || names.contains("hostfxr.dll") || names.contains("coreclr.dll") {
            return EngineFingerprint(
                engine: .dotnet, preferredExecutable: nil, excludedPaths: [],
                requiredVerbs: [], launchArguments: [],
                notes: [(".NET game — the runtime ships with it",
                         "Juego .NET — el runtime viene incluido")])
        }

        // --- id Tech / Doom source ports ---------------------------------------
        if names.contains(where: { $0.hasSuffix(".wad") || $0.hasSuffix(".pk3") }) {
            // The engine's own .pk3 files are not playable data; the game is
            // whichever .wad shipped alongside. Handing it over on the command
            // line skips the "which game file do you want?" dialog entirely.
            let wads = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".wad") }
                .sorted()
            var arguments: [String] = []
            var extraNotes: [(en: String, es: String)] = []
            if let wad = wads.first {
                arguments = ["-iwad", wad]
                extraNotes.append(("Starts straight into \(wad) — no file chooser",
                                   "Arranca directo en \(wad), sin selector de archivo"))
            }
            return EngineFingerprint(
                engine: .idTech, preferredExecutable: nil, excludedPaths: [],
                requiredVerbs: [], launchArguments: arguments,
                notes: [("Doom-engine game — mouse look and keyboard are its whole interface",
                         "Juego con motor Doom — ratón y teclado son toda su interfaz")] + extraNotes)
        }

        // --- Java / Electron ---------------------------------------------------
        if names.contains("jre") || names.contains(where: { $0.hasSuffix(".jar") }) {
            return EngineFingerprint(
                engine: .java, preferredExecutable: nil, excludedPaths: [],
                requiredVerbs: [], launchArguments: [],
                notes: [("Java game — needs the bundled Java runtime",
                         "Juego Java — necesita el runtime de Java incluido")])
        }
        if names.contains("resources") && names.contains(where: { $0.hasPrefix("libffmpeg") }) {
            return EngineFingerprint(engine: .electron, preferredExecutable: nil, excludedPaths: [],
                                     requiredVerbs: [], launchArguments: [], notes: [])
        }

        // --- SDL ---------------------------------------------------------------
        if names.contains(where: { $0.hasPrefix("sdl2") || $0.hasPrefix("sdl3") }) {
            return EngineFingerprint(
                engine: .sdl, preferredExecutable: nil, excludedPaths: [],
                requiredVerbs: [], launchArguments: [], notes: [])
        }

        _ = fileExists
        return .none
    }
}
