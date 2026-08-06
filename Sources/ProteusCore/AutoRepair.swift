// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Fixes a badly-rendering game without asking anyone.
///
/// The dependency analysis picks a configuration from evidence, and it is right
/// most of the time. When it is not, the failure is not an error message — it
/// is a game that draws everything in magenta, or a black window, or a crash on
/// the second frame. No import table predicts that: it depends on this Wine
/// build, this MoltenVK, this macOS, this GPU.
///
/// So the last step is empirical. Start the game, look at what it drew, and if
/// the picture is wrong work down a ranked list of configurations, keeping the
/// first one that looks right. The user never sees any of it; they get an app
/// that works.
public struct AutoRepair {

    /// One thing to try. Arguments go to the game; overrides go to the
    /// wrapper's Info.plist, which is how the renderer is switched.
    public struct Candidate: Sendable {
        public let en: String
        public let es: String
        public let arguments: [String]
        public let plistOverrides: [String: Int]
        /// Answer a first-run question instead of only looking at the frame.
        /// When a region is given, its first button is clicked; otherwise the
        /// default button is taken with Return.
        public let answersPrompt: Bool
        public let promptRegion: FrameHealth.DialogRegion?

        public init(en: String, es: String, arguments: [String] = [],
                    plistOverrides: [String: Int] = [:], answersPrompt: Bool = false,
                    promptRegion: FrameHealth.DialogRegion? = nil) {
            self.en = en; self.es = es
            self.arguments = arguments
            self.plistOverrides = plistOverrides
            self.answersPrompt = answersPrompt
            self.promptRegion = promptRegion
        }
    }

    public struct Outcome: Sendable {
        public let finalVerdict: FrameHealth.Verdict
        public let appliedEN: String?
        public let appliedES: String?
        public let attempts: [(candidate: String, verdict: FrameHealth.Verdict)]
        public let extraArguments: [String]
        public let plistOverrides: [String: Int]

        public var repaired: Bool { finalVerdict.isHealthy && appliedEN != nil }
    }

    let engine: WineEngine
    let wrapper: Wrapper
    let workDir: URL

    public init(engine: WineEngine, wrapper: Wrapper, workDir: URL) {
        self.engine = engine
        self.wrapper = wrapper
        self.workDir = workDir
    }

    // MARK: - What to try, and in what order

    /// Candidates ranked by how likely they are to help *and* how little they
    /// give up. Performance comes first: a heavy game made playable by falling
    /// back to a software renderer is not made playable at all, so the
    /// slow-but-safe options sit at the bottom and the fast ones at the top.
    public static func candidates(for verdict: FrameHealth.Verdict,
                                  engineName: String?,
                                  renderer: Prescription.Renderer) -> [Candidate] {
        var list: [Candidate] = []

        switch verdict {
        case .waitingOnDialog(let region):
            // The game is not broken, it asked a question and nobody answered.
            // Click the first button — Windows convention puts the affirmative
            // one there, and for the case this was built for it reads
            // "Yes, download the graphics".
            list.append(.init(en: "answering the game's first-run question",
                              es: "respondiendo a la pregunta de primer arranque",
                              answersPrompt: true, promptRegion: region))
            // If the click lands wrong, the default button is the next guess.
            list.append(.init(en: "pressing the dialog's default button",
                              es: "pulsando el botón por defecto del diálogo",
                              answersPrompt: true))

        // Order matters: `.colourCast` on its own matches every cast, so the
        // single-hue case has to be tested before it or it is unreachable.
        case .colourCast("single-hue"):
            // A near-empty frame with one small patch of content is usually not
            // a broken renderer at all: it is a game sitting on a first-run
            // question. OpenTTD ships without its graphics when installed
            // silently and asks permission to fetch them; the game cannot start
            // until somebody answers.
            //
            // Answering is safe to attempt and cheap to undo: Return takes the
            // default button, which Windows convention makes the affirmative
            // one, and the loop moves on if the picture does not improve.
            list.append(.init(en: "answering the game's first-run question",
                              es: "respondiendo a la pregunta de primer arranque",
                              answersPrompt: true))
            list.append(contentsOf: candidates(for: .colourCast(dominant: "generic"),
                                               engineName: engineName, renderer: renderer))

        case .colourCast:
            // A colour cast is almost always the swapchain: the game asked for
            // a surface format the translation layer hands back with the
            // channels or the colour space wrong.
            if engineName == "id Tech / Doom engine" {
                // GZDoom's own bug tracker calls this one "washed out colors in
                // Vulkan HDR mode". Turning HDR off is the documented fix, and
                // it costs nothing on a translation layer that cannot do HDR
                // properly anyway.
                list.append(.init(en: "turning off HDR output",
                                  es: "desactivando la salida HDR",
                                  arguments: ["+vid_hdr", "0"]))
                list.append(.init(en: "asking for an 8-bit colour buffer",
                                  es: "pidiendo un búfer de color de 8 bits",
                                  arguments: ["+vid_hdr", "0", "+vid_fullscreen", "0"]))
                list.append(.init(en: "switching to the OpenGL renderer",
                                  es: "cambiando al renderizador OpenGL",
                                  arguments: ["+vid_preferbackend", "0"]))
                list.append(.init(en: "switching to the software renderer",
                                  es: "cambiando al renderizador por software",
                                  arguments: ["+vid_preferbackend", "2"]))
            }
            // The wrapper ships two MoltenVK builds — CrossOver's, used by
            // default, and a stock one. A colour cast that survives every
            // renderer is usually the Vulkan-to-Metal layer itself, and
            // swapping which one is loaded costs a single relaunch.
            list.append(.init(en: "using the stock Vulkan-to-Metal layer",
                              es: "usando la capa Vulkan-a-Metal estándar",
                              plistOverrides: ["MOLTENVKCX": 0]))

            // Generic: move between translation layers. Fast paths first.
            // Skipped entirely for a game that speaks OpenGL or Vulkan itself:
            // swapping DirectX translators cannot change a single pixel it
            // draws, and four pointless relaunches is four minutes wasted.
            for alternative in renderer.translatesDirectX ? renderer.fasterAlternativesFirst : [] {
                list.append(.init(en: "switching graphics to \(alternative.rawValue)",
                                  es: "cambiando los gráficos a \(alternative.rawValue)",
                                  plistOverrides: alternative.plistKeys.mapValues { $0 ? 1 : 0 }))
            }

        case .blank, .tooDark:
            // Nothing drawn usually means the renderer never came up. Windowed
            // mode sidesteps a fullscreen surface the layer cannot present.
            list.append(.init(en: "running in a window instead of fullscreen",
                              es: "ejecutando en ventana en vez de pantalla completa",
                              arguments: ["+vid_fullscreen", "0"]))
            for alternative in renderer.fasterAlternativesFirst {
                list.append(.init(en: "switching graphics to \(alternative.rawValue)",
                                  es: "cambiando los gráficos a \(alternative.rawValue)",
                                  plistOverrides: alternative.plistKeys.mapValues { $0 ? 1 : 0 }))
            }

        case .healthy, .unreadable:
            break
        }
        return list
    }

    // MARK: - Running the loop

    /// - Parameters:
    ///   - baseArguments: what the game is already being launched with.
    ///   - maxAttempts: a cap, because every attempt costs a launch.
    public func repair(exeWindowsPath: String,
                       executableName: String,
                       baseArguments: [String],
                       engineName: String?,
                       renderer: Prescription.Renderer,
                       maxAttempts: Int = 4,
                       progress: (String, String) -> Void = { _, _ in }) -> Outcome {
        var attempts: [(String, FrameHealth.Verdict)] = []

        // First, see what the game looks like as configured.
        let (baseline, baselineMeasurements) = observe(exeWindowsPath: exeWindowsPath,
                                                       executableName: executableName,
                                                       arguments: baseArguments,
                                                       label: "baseline")
        attempts.append(("as configured", baseline))
        if baseline.isHealthy || baseline == .unreadable {
            // Nothing to fix, or nothing we can see well enough to judge. Do
            // not start changing a working configuration on a bad screenshot.
            return Outcome(finalVerdict: baseline, appliedEN: nil, appliedES: nil,
                           attempts: attempts, extraArguments: [], plistOverrides: [:])
        }
        _ = baselineMeasurements

        let list = Self.candidates(for: baseline, engineName: engineName, renderer: renderer)
        for candidate in list.prefix(maxAttempts) {
            progress("Trying: \(candidate.en)", "Probando: \(candidate.es)")
            applyOverrides(candidate.plistOverrides)
            let (verdict, _) = observe(exeWindowsPath: exeWindowsPath,
                                       executableName: executableName,
                                       arguments: baseArguments + candidate.arguments,
                                       label: candidate.en,
                                       answerPrompt: candidate.answersPrompt,
                                       promptRegion: candidate.promptRegion)
            attempts.append((candidate.en, verdict))
            if verdict.isHealthy {
                return Outcome(finalVerdict: verdict, appliedEN: candidate.en,
                               appliedES: candidate.es, attempts: attempts,
                               extraArguments: candidate.arguments,
                               plistOverrides: candidate.plistOverrides)
            }
            // Undo a renderer change that did not help before trying the next.
            revertOverrides(candidate.plistOverrides)
        }

        return Outcome(finalVerdict: baseline, appliedEN: nil, appliedES: nil,
                       attempts: attempts, extraArguments: [], plistOverrides: [:])
    }

    /// Launches the game, waits for it to draw, grabs one frame and judges it.
    func observe(exeWindowsPath: String, executableName: String,
                 arguments: [String], label: String,
                 answerPrompt: Bool = false,
                 promptRegion: FrameHealth.DialogRegion? = nil) -> (FrameHealth.Verdict, FrameHealth.Measurements?) {
        let process = Process()
        process.executableURL = wrapper.wineBinary
        process.arguments = [exeWindowsPath] + arguments
        process.environment = engine.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (.unreadable, nil) }

        defer {
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.8)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            engine.killServer()
        }

        let check = InputCheck()
        let deadline = Date().addingTimeInterval(45)
        var window = check.findWindow(executableName: executableName)
        while window == nil, Date() < deadline {
            if !process.isRunning { return (.unreadable, nil) }
            Thread.sleep(forTimeInterval: 0.75)
            window = check.findWindow(executableName: executableName)
        }
        guard let window else { return (.unreadable, nil) }

        // Let the first frames settle: a title screen fading in from black
        // would read as "too dark" if caught early enough.
        Thread.sleep(forTimeInterval: 6)

        if answerPrompt {
            check.focus(window)
            Thread.sleep(forTimeInterval: 1.5)
            if let region = promptRegion {
                // The region came from the frame, so it is in frame fractions;
                // scale it onto the window's place on screen.
                let point = region.firstButtonPoint
                check.click(at: CGPoint(x: window.bounds.minX + window.bounds.width * point.x,
                                        y: window.bounds.minY + window.bounds.height * point.y))
            } else {
                check.post(keyCode: 36)   // Return
            }
            // Allow time for whatever it agreed to: a data download takes a
            // while, and judging the frame mid-download would call it broken.
            Thread.sleep(forTimeInterval: 90)
        }

        let shot = workDir.appendingPathComponent("frame-\(UUID().uuidString.prefix(6)).png")
        guard check.screenshot(window, to: shot) else { return (.unreadable, nil) }
        defer { try? FileManager.default.removeItem(at: shot) }
        return FrameHealth.analyse(shot)
    }

    func applyOverrides(_ overrides: [String: Int]) {
        guard !overrides.isEmpty else { return }
        try? wrapper.setPlistValues(overrides)
    }

    func revertOverrides(_ overrides: [String: Int]) {
        guard !overrides.isEmpty else { return }
        try? wrapper.setPlistValues(overrides.mapValues { _ in 0 })
    }
}

extension Prescription.Renderer {
    /// Other translation layers worth trying, fastest first.
    ///
    /// Order matters more than it looks: a heavy game pushed onto wined3d is
    /// technically "fixed" and practically unplayable, so the Metal-native
    /// paths are always tried before the OpenGL one.
    var fasterAlternativesFirst: [Prescription.Renderer] {
        let ranked: [Prescription.Renderer] = [.dxmt, .d3dmetal, .dxvk, .wined3d]
        return ranked.filter { $0 != self }
    }
}
