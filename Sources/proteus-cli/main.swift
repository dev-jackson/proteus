import Foundation
import ProteusCore

// A thin driver over ProteusCore. The GUI is the product; this exists so the
// engine can be exercised and debugged without one.

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    proteus — Windows games on macOS, without the ceremony

    usage:
      proteus inspect <file|folder>       show what the game needs, change nothing
      proteus install <file|folder> [options]
      proteus check-input <app>            start a game and test keyboard + mouse
      proteus check-picture <app>          judge how the game looks, and repair it
      proteus finish <app>                 complete an install that was interrupted
      proteus logs <app>                   what the game printed last time it ran
                                          (--previous for the run before, --all for everything)
      proteus update-layers <app>          install the newest Direct3D layer (--revert undoes)
      proteus fix <app>                   re-run its installer with the UI visible
      proteus uninstall <app name>

    options:
      --name <name>      override the app name
      --to <directory>   install somewhere other than /Applications
      --shots <directory> save before/after screenshots (check-input only)
      --json             machine-readable output (inspect only)
    """)
    exit(2)
}

func value(for flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let command = args.first else { usage() }

let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
let flagValues = ["--name", "--to", "--shots"].compactMap { value(for: $0) }
let target = positional.first { !flagValues.contains($0) }

let installRoot = URL(fileURLWithPath: value(for: "--to") ?? "/Applications")

final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLine = ""

    func report(_ stage: InstallPipeline.Stage) {
        let percent = stage.fraction.map { String(format: "%3.0f%%", $0 * 100) } ?? "   ·"
        var line = "  \(percent)  \(stage.en)"
        if let detail = stage.detail { line += "  (\(detail))" }
        lock.lock()
        defer { lock.unlock() }
        guard line != lastLine else { return }
        lastLine = line
        print(line)
        fflush(stdout)
    }
}

func describe(_ analysis: InstallPipeline.Analysis) {
    print("")
    print("  \(analysis.name)")
    print("  \(String(repeating: "─", count: max(analysis.name.count, 20)))")
    if let framework = analysis.installerFramework {
        print("  source        \(analysis.kind) · \(framework)")
    } else {
        print("  source        \(analysis.kind)")
    }
    print("  program       \(analysis.mainExecutable.lastPathComponent) · \(analysis.architecture)")
    if analysis.candidateCount > 1 {
        print("  found         \(analysis.candidateCount) programs, picked the one above")
    }
    if let engine = analysis.prescription.engineName {
        print("  engine        \(engine)")
    }
    print("  graphics      \(analysis.prescription.renderer.rawValue)")
    var devices = ["keyboard"]
    if analysis.prescription.usesMouse { devices.append("mouse") }
    if analysis.prescription.usesGamepad { devices.append("gamepad") }
    print("  controls      \(devices.joined(separator: ", "))")
    if analysis.downloadBytes > 0 {
        print("  to download   \(analysis.downloadBytes / 1_048_576) MB of runtime (one time)")
    } else {
        print("  to download   nothing, runtime already cached")
    }
    if analysis.prescription.reasons.isEmpty {
        print("  needs         nothing beyond Wine itself")
    } else {
        print("  needs")
        for reason in analysis.prescription.reasons {
            print("                • \(reason.requirement)  ← \(reason.evidence)")
        }
    }
    if !analysis.prescription.winetricks.isEmpty {
        print("  will install  \(analysis.prescription.winetricks.joined(separator: ", "))")
    }
    if analysis.prescription.needsRosetta {
        print("  note          needs Rosetta 2 (DirectX 12 translation)")
    }
    print("")
}

switch command {
case "inspect":
    guard let target else { usage() }
    let url = URL(fileURLWithPath: target).standardizedFileURL
    let pipeline = InstallPipeline(installRoot: installRoot)
    do {
        let (analysis, source) = try await pipeline.analyze(url)
        if args.contains("--json") {
            let dict: [String: Any] = [
                "name": analysis.name,
                "kind": analysis.kind,
                "architecture": analysis.architecture,
                "executable": analysis.mainExecutable.path,
                "renderer": analysis.prescription.renderer.rawValue,
                "winetricks": analysis.prescription.winetricks,
                "downloadBytes": analysis.downloadBytes,
                "needs": analysis.prescription.reasons.map { ["what": $0.requirement, "why": $0.evidence] },
            ]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } else {
            describe(analysis)
        }
        if let volume = source.mountedVolume { DiscMounter.unmount(volume) }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

case "install":
    guard let target else { usage() }
    let url = URL(fileURLWithPath: target).standardizedFileURL
    let pipeline = InstallPipeline(installRoot: installRoot)
    do {
        let (analysis, source) = try await pipeline.analyze(url)
        describe(analysis)

        // Progress arrives from the pipeline's actor, so the de-duplication
        // state needs its own lock rather than a captured local.
        let printer = ProgressPrinter()
        let outcome = try await pipeline.install(source: source, analysis: analysis,
                                                 name: value(for: "--name")) { stage in
            printer.report(stage)
        }
        print("")
        let verified = outcome.verdict?.passed ?? false
        print("  \(verified ? "✓" : "▲") \(outcome.name) is in \(outcome.appPath.deletingLastPathComponent().path)")
        if verified {
            print("    started and kept running — verified")
        } else if let verdict = outcome.verdict {
            print("    \(verdict.result.rawValue): \(verdict.diagnosisEN ?? "no diagnosis")")
        }
        if let display = outcome.display {
            let mark = display.finalVerdict.isHealthy ? "✓" : "▲"
            print("    \(mark) picture: \(display.finalVerdict.summaryEN)")
            if let applied = display.appliedEN {
                print("      fixed by \(applied)")
            }
            if display.attempts.count > 1 {
                for attempt in display.attempts {
                    print("      · \(attempt.candidate) → \(attempt.verdict.summaryEN)")
                }
            }
        }
        if let input = outcome.input {
            let mark = (input.keyboard == .delivered || input.mouse == .delivered) ? "✓" : "▲"
            print("    \(mark) input: \(input.summaryEN)")
            print("      \(input.keysDelivered)/\(input.keysSent) key presses and \(input.mouseMovesDelivered)/\(input.mouseMovesSent) mouse moves reached the game")
        }
        for warning in outcome.warnings {
            print("  ! \(warning)")
        }
        if let installer = outcome.installerForManualRun {
            print("  → run the installer by hand:")
            print("      proteus fix \"\(outcome.appPath.path)\"")
            _ = installer
        }
        print("")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

case "check-input":
    // Launch an installed game and prove keyboard and mouse reach it.
    guard let target else { usage() }
    let app = target.hasSuffix(".app") ? URL(fileURLWithPath: target)
                                       : installRoot.appendingPathComponent("\(target).app")
    let wrapper = Wrapper(bundle: app)
    guard let program = (try? wrapper.plist())?["Program Name and Path"] as? String else {
        FileHandle.standardError.write(Data("error: \(app.lastPathComponent) is not a Proteus game\n".utf8))
        exit(1)
    }
    let exeName = program.split(separator: "\\").last.map(String.init) ?? ""
    print("  starting \(exeName) and sending input…")
    let smoke = SmokeTest(engine: WineEngine(wrapper: wrapper), wrapper: wrapper)
    let shotDir = value(for: "--shots").map { URL(fileURLWithPath: $0) }
    if let report = smoke.runWithInputCheck(exeWindowsPath: program, executableName: exeName,
                                            screenshotDir: shotDir) {
        print("  window     \(report.windowTitle ?? "(untitled)")\(report.targetWindowHandle.map { " · hwnd \($0)" } ?? "")")
        print("  keyboard   \(report.keyboard.rawValue)  \(report.keysDelivered)/\(report.keysSent) key presses arrived")
        print("  mouse      \(report.mouse.rawValue)  \(report.mouseMovesDelivered)/\(report.mouseMovesSent) moves arrived")
        print("  verdict    \(report.summaryEN)")
    } else {
        print("  the game did not open a window to test")
    }

case "update-layers":
    // Install the newest graphics translation layer into an existing game.
    guard let target else { usage() }
    let app = target.hasSuffix(".app") ? URL(fileURLWithPath: target)
                                       : installRoot.appendingPathComponent("\(target).app")
    let wrapper = Wrapper(bundle: app)
    let layers = TranslationLayers()
    if args.contains("--revert") {
        layers.revert(in: wrapper)
        print("  ✓ restored the engine's own graphics libraries")
    } else {
        print("  fetching \(TranslationLayers.dxmt.summaryEN)…")
        let root = try await layers.ensure(TranslationLayers.dxmt)
        try layers.install(root, into: wrapper)
        let d3d11 = wrapper.wineRoot.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")
        let size = ((try? FileManager.default.attributesOfItem(atPath: d3d11.path)[.size]) as? Int) ?? 0
        print("  ✓ installed — d3d11.dll is now \(size / 1024) KB")
    }

case "finish":
    // Pick up a wrapper whose files are in place but was never configured.
    guard let target else { usage() }
    let app = target.hasSuffix(".app") ? URL(fileURLWithPath: target)
                                       : installRoot.appendingPathComponent("\(target).app")
    let pipeline = InstallPipeline(installRoot: installRoot)
    let printer = ProgressPrinter()
    do {
        let outcome = try await pipeline.finishInterrupted(app: app) { printer.report($0) }
        print("")
        print("  \(outcome.verdict?.passed == true ? "✓" : "▲") \(outcome.name) finished")
        for warning in outcome.warnings { print("  ! \(warning)") }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

case "logs":
    // Show what the game printed on its last run, minus the noise.
    guard let target else { usage() }
    let app = target.hasSuffix(".app") ? URL(fileURLWithPath: target)
                                       : installRoot.appendingPathComponent("\(target).app")
    let logs = app.appendingPathComponent("Contents/Logs")
    let which = args.contains("--previous") ? "previous-run.log" : "last-run.log"
    let file = logs.appendingPathComponent(which)
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        FileHandle.standardError.write(Data("error: no log yet — play the game once and try again\n".utf8))
        exit(1)
    }
    // MoltenVK announces its whole feature set on every launch; left in, it
    // buries the one line that matters.
    let noise = ["mvk-info", "vk_khr", "vk_ext", "vk_mvk", "gpu family", "gpu memory",
                 "metal shading", "read-write texture", "vulkan extensions",
                 "pipelinecacheuuid", "vendorid", "deviceid", "supports the following",
                 // Wine reports every HID device it decides is not a gamepad,
                 // once per device per launch. Dozens of identical lines bury
                 // the one that says why the game stopped.
                 "handle_devicematchingcallback", "not a joystick or gamepad",
                 "winediag:", "wine_init"]
    var kept: [String] = []
    var lastPattern = ""
    var repeats = 0

    /// Two lines that differ only in a pointer or handle are the same message.
    func pattern(of line: String) -> String {
        var out = ""
        var inHex = false
        for character in line {
            if character.isHexDigit && out.hasSuffix("0x") { inHex = true; continue }
            if inHex { if character.isHexDigit { continue }; inHex = false }
            out.append(character)
        }
        return out
    }

    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        // Every line beginning "VK_" is one entry of MoltenVK's extension
        // inventory — a hundred and fifty of them on every launch.
        guard !line.isEmpty, !noise.contains(where: { lower.contains($0) }),
              !line.hasPrefix("VK_"), !lower.hasPrefix("model:"),
              !lower.hasPrefix("type:") else { continue }

        let shape = pattern(of: line)
        if shape == lastPattern {
            repeats += 1
            continue
        }
        if repeats > 0 {
            kept.append("   … and \(repeats) more like the line above")
            repeats = 0
        }
        lastPattern = shape
        kept.append(line)
    }
    if repeats > 0 { kept.append("   … and \(repeats) more like the line above") }
    let tail = args.contains("--all") ? kept : Array(kept.suffix(40))
    print("  \(which) — \(kept.count) lines, showing \(tail.count)")
    print("")
    for line in tail { print("  \(line)") }

case "check-picture":
    // Judge the frame the game draws, and work through fixes if it is wrong.
    guard let target else { usage() }
    let app = target.hasSuffix(".app") ? URL(fileURLWithPath: target)
                                       : installRoot.appendingPathComponent("\(target).app")
    let wrapper = Wrapper(bundle: app)
    let info = (try? wrapper.plist()) ?? [:]
    guard let program = info["Program Name and Path"] as? String else {
        FileHandle.standardError.write(Data("error: \(app.lastPathComponent) is not a Proteus game\n".utf8))
        exit(1)
    }
    let exeName = program.split(separator: "\\").last.map(String.init) ?? ""
    let flags = (info["Program Flags"] as? String ?? "").split(separator: " ").map(String.init)
    let renderer = Prescription.Renderer(rawValue: info["ProteusRenderer"] as? String ?? "wined3d") ?? .wined3d
    let repairer = AutoRepair(engine: WineEngine(wrapper: wrapper), wrapper: wrapper,
                              workDir: FileManager.default.temporaryDirectory)
    print("  looking at what \(exeName) draws…")
    let result = repairer.repair(exeWindowsPath: program, executableName: exeName,
                                 baseArguments: flags,
                                 engineName: info["ProteusEngine"] as? String,
                                 renderer: renderer) { en, _ in print("  \(en)") }
    print("")
    for attempt in result.attempts {
        print("  · \(attempt.candidate) → \(attempt.verdict.summaryEN)")
    }
    print("")
    if result.repaired {
        print("  ✓ fixed by \(result.appliedEN!)")
        print("    add to Program Flags: \(result.extraArguments.joined(separator: " "))")
    } else if result.finalVerdict.isHealthy {
        print("  ✓ \(result.finalVerdict.summaryEN) — nothing to change")
    } else {
        print("  ▲ still wrong: \(result.finalVerdict.summaryEN)")
    }

case "fix":
    // Re-run the stashed installer with its own UI visible.
    guard let target else { usage() }
    let app = URL(fileURLWithPath: target)
    let stash = app.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/Proteus")
    let installers = ((try? FileManager.default.contentsOfDirectory(at: stash, includingPropertiesForKeys: nil)) ?? [])
        .filter { ["exe", "msi"].contains($0.pathExtension.lowercased()) }
    guard let installer = installers.first else {
        FileHandle.standardError.write(Data("error: no installer is stored inside \(app.lastPathComponent)\n".utf8))
        exit(1)
    }
    print("  opening \(installer.lastPathComponent) — finish it in the window that appears")
    let pipeline = InstallPipeline(installRoot: installRoot)
    try await pipeline.runInstallerInteractively(app: app, installer: installer)
    print("  ✓ done")

case "uninstall":
    guard let target else { usage() }
    let app = target.hasSuffix(".app")
        ? URL(fileURLWithPath: target)
        : installRoot.appendingPathComponent("\(target).app")
    guard FileManager.default.fileExists(atPath: app.path) else {
        FileHandle.standardError.write(Data("error: \(app.lastPathComponent) is not installed\n".utf8))
        exit(1)
    }
    // Everything a game touched lives inside its bundle, so this really is all.
    try FileManager.default.removeItem(at: app)
    print("  ✓ removed \(app.lastPathComponent)")

default:
    usage()
}
