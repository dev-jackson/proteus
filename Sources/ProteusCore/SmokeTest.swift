import Foundation
import CoreGraphics

/// Before telling anyone their game is ready, actually start it and watch.
/// Shipping an app that quits on double-click — or worse, one that runs
/// invisibly forever behind a dialog nobody can see — is the worst outcome,
/// and it is the one every existing tool leaves on the table.
///
/// "The process is alive" is not enough evidence: OpenTTD with no graphics set
/// sits there consuming CPU and never opens a window. So the test waits for a
/// real, on-screen window of a believable size.
public struct SmokeTest {

    public struct Verdict: Sendable {
        public enum Result: String, Sendable {
            case windowShown    // a window appeared: the game works
            case noWindow       // process alive but nothing to look at
            case exitedEarly    // quit on its own within the watch window
            case couldNotStart  // wine refused to launch it at all
        }
        public let result: Result
        /// Plain-language explanation, when we could work one out.
        public let diagnosisEN: String?
        public let diagnosisES: String?
        public let rawTail: String

        public var passed: Bool { result == .windowShown }
    }

    let engine: WineEngine
    let wrapper: Wrapper

    public init(engine: WineEngine, wrapper: Wrapper) {
        self.engine = engine
        self.wrapper = wrapper
    }

    /// Known startup failures, matched against whatever the game printed.
    /// Each entry turns an opaque exit into something the user can act on.
    static let diagnoses: [(needles: [String], en: String, es: String)] = [
        (["no suitable graphics set", "unable to find a graphics set", "graphics set", "basesets"],
         "The game is missing its graphics data, which the silent install skipped. Re-run the installer and let it download the extras.",
         "Al juego le faltan sus datos gráficos, que la instalación silenciosa omitió. Vuelve a ejecutar el instalador y deja que descargue los extras."),
        (["mscoree", ".net framework", "clr error"],
         "The game needs the .NET Framework.",
         "El juego necesita .NET Framework."),
        (["msvcp", "msvcr", "vcruntime", "side-by-side"],
         "A Visual C++ runtime is missing.",
         "Falta un runtime de Visual C++."),
        (["d3dx9", "d3dx11", "d3dcompiler"],
         "A DirectX helper library is missing.",
         "Falta una librería auxiliar de DirectX."),
        (["could not find the file", "file not found", "cannot find"],
         "The game is looking for a file that is not where it expects — it may still want its disc.",
         "El juego busca un archivo que no está donde espera: puede que aún quiera su disco."),
        (["failed creating the direct3d device", "failed to create d3d", "d3d11createdevice",
          "createdevice failed", "no compatible gpu"],
         "The graphics translation layer this game needs is not the one installed. Proteus can switch it.",
         "La capa de traducción gráfica que necesita este juego no es la instalada. Proteus puede cambiarla."),
        (["err:module", "importing dll", "unable to load"],
         "A required Windows library could not be loaded.",
         "No se pudo cargar una librería de Windows necesaria."),
    ]

    /// - Parameters:
    ///   - exeWindowsPath: the same path the finished app will launch.
    ///   - watchFor: how long to wait for a window. Long enough for a splash
    ///     screen and a slow first-run shader compile, short enough that a
    ///     failed install does not hold the user hostage.
    public func run(exeWindowsPath: String, arguments: [String] = [],
                    watchFor: TimeInterval = 45) -> Verdict {
        guard FileManager.default.isExecutableFile(atPath: wrapper.wineBinary.path) else {
            return Verdict(result: .couldNotStart,
                           diagnosisEN: "The Wine engine is missing from the app.",
                           diagnosisES: "Falta el motor de Wine en la app.", rawTail: "")
        }

        let process = Process()
        process.executableURL = wrapper.wineBinary
        process.arguments = [exeWindowsPath] + arguments
        // Turn the log back up: the whole point is capturing why it failed.
        var env = engine.environment(extra: ["WINEDEBUG": "fixme-all,err+module,err+ntdll"])
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin"
        process.environment = env

        let pipe = Pipe()
        let sink = Shell.OutputSink()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { sink.appendOut($0.availableData) }

        do { try process.run() } catch {
            return Verdict(result: .couldNotStart,
                           diagnosisEN: "The Wine engine could not start the game.",
                           diagnosisES: "El motor de Wine no pudo iniciar el juego.",
                           rawTail: "\(error)")
        }

        // Wine re-execs the game into its own process, so the window we are
        // waiting for is never owned by the process we just spawned. Match on
        // the executable name instead.
        let exeName = (exeWindowsPath.split(separator: "\\").last).map(String.init) ?? ""
        var sawWindow = false
        let deadline = Date().addingTimeInterval(watchFor)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.75)
            if hasVisibleWindow(forExecutableNamed: exeName) { sawWindow = true; break }
            if !process.isRunning { break }
        }

        let stillRunning = process.isRunning
        if stillRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.8)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { sink.appendOut(rest) }
        engine.killServer()

        let (output, _) = sink.strings()
        let tail = String(output.suffix(1500))

        if sawWindow {
            return Verdict(result: .windowShown, diagnosisEN: nil, diagnosisES: nil, rawTail: tail)
        }

        let haystack = output.lowercased()
        let matched = Self.diagnoses.first { entry in
            entry.needles.contains { haystack.contains($0) }
        }
        if stillRunning {
            // A specific, checkable case beats a guess: the wrapper is set to a
            // Direct3D translator whose libraries are not in the engine it was
            // built on. The game starts, cannot make a graphics device, and
            // shows a message box that never reaches this log because it is a
            // Windows dialog rather than console output. The configuration says
            // it plainly, so read that instead of the text.
            if let mismatch = rendererMismatch() {
                return Verdict(result: .noWindow, diagnosisEN: mismatch.en,
                               diagnosisES: mismatch.es, rawTail: tail)
            }
            return Verdict(result: .noWindow,
                           diagnosisEN: matched?.en
                               ?? "The game started but never opened a window. It is probably waiting on data files it did not get.",
                           diagnosisES: matched?.es
                               ?? "El juego arrancó pero nunca abrió una ventana. Probablemente espera archivos de datos que no recibió.",
                           rawTail: tail)
        }
        return Verdict(result: .exitedEarly,
                       diagnosisEN: matched?.en
                           ?? "The game started and then closed itself. It may need extra data files, or its disc.",
                       diagnosisES: matched?.es
                           ?? "El juego arrancó y se cerró solo. Puede que necesite archivos extra o su disco.",
                       rawTail: tail)
    }

    /// Launches the game again and drives keyboard and mouse at it. Separate
    /// from `run` because the startup check kills the game when it finishes,
    /// and the input check needs a live one it can keep for its own timing.
    /// - Parameter screenshotDir: when set, writes `<game>-before.png` and
    ///   `<game>-after.png` around the input, so a person can see for
    ///   themselves whether the game reacted.
    public func runWithInputCheck(exeWindowsPath: String,
                                  executableName: String,
                                  arguments: [String] = [],
                                  screenshotDir: URL? = nil) -> InputCheck.Report? {
        guard FileManager.default.isExecutableFile(atPath: wrapper.wineBinary.path) else { return nil }

        let process = Process()
        process.executableURL = wrapper.wineBinary
        process.arguments = [exeWindowsPath] + arguments
        // Turn on exactly the two trace channels that record input delivery.
        process.environment = engine.environment(
            extra: ["WINEDEBUG": InputCheck.debugChannels])

        let pipe = Pipe()
        let sink = Shell.OutputSink()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { sink.appendOut($0.availableData) }
        do { try process.run() } catch { return nil }

        defer {
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.8)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            engine.killServer()
        }

        // Give it the same grace period the startup check allows, then test.
        let check = InputCheck()
        let deadline = Date().addingTimeInterval(45)
        var window = check.findWindow(executableName: executableName)
        while window == nil, Date() < deadline {
            if !process.isRunning { return nil }
            Thread.sleep(forTimeInterval: 0.75)
            window = check.findWindow(executableName: executableName)
        }
        guard let window else {
            return check.verdict(fromLog: "", sent: (0, 0), window: nil)
        }

        // Let the game finish its first frames before judging it: a title
        // screen that is still loading has no window procedure to receive
        // anything yet.
        Thread.sleep(forTimeInterval: 3)
        let stem = (executableName as NSString).deletingPathExtension
        if let dir = screenshotDir {
            check.screenshot(window, to: dir.appendingPathComponent("\(stem)-before.png"))
        }
        let sent = check.send(to: window)
        Thread.sleep(forTimeInterval: 1.5)
        if let dir = screenshotDir {
            check.screenshot(window, to: dir.appendingPathComponent("\(stem)-after.png"))
        }

        // Stop the game *before* draining the pipe. `readToEnd` waits for EOF,
        // and the write end stays open for as long as the child lives — reading
        // first deadlocks forever against a game that is behaving perfectly.
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.8)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()

        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { sink.appendOut(rest) }
        let (log, _) = sink.strings()
        return check.verdict(fromLog: log, sent: sent, window: window)
    }

    /// The wrapper asking for a translator the engine cannot provide.
    ///
    /// D3DMetal ships only with the Game Porting Toolkit engine. A wrapper with
    /// `D3DMETAL` switched on but built on the general engine will always fail
    /// with "Failed creating the Direct3D device" — and that message arrives as
    /// a Windows dialog, so no amount of log-reading finds it.
    func rendererMismatch() -> (en: String, es: String)? {
        guard let info = try? wrapper.plist() else { return nil }
        let wantsD3DMetal = (info["D3DMETAL"] as? Int ?? 0) == 1
        guard wantsD3DMetal, !Runtime.hasGPTK(wrapper) else { return nil }
        return ("This game needs DirectX 12, which only the Game Porting Toolkit engine provides — and this app was built on the general one. Proteus can swap the engine without reinstalling the game.",
                "Este juego necesita DirectX 12, que solo trae el motor Game Porting Toolkit, y esta app se creó con el general. Proteus puede cambiar el motor sin reinstalar el juego.")
    }

    /// Looks for an on-screen window belonging to the game. Size matters: Wine
    /// keeps invisible 1×1 helper windows around that would otherwise count as
    /// success.
    func hasVisibleWindow(forExecutableNamed exeName: String) -> Bool {
        let pids = pidsRunning(exeName)
        guard !pids.isEmpty else { return false }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double else { continue }
            if width >= 200 && height >= 150 { return true }
        }
        return false
    }

    func pidsRunning(_ exeName: String) -> Set<pid_t> {
        guard !exeName.isEmpty else { return [] }
        let result = Shell.run("/bin/ps", ["-axo", "pid=,command="], timeout: 15)
        var pids = Set<pid_t>()
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            guard line.lowercased().contains(exeName.lowercased()) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let field = trimmed.split(separator: " ").first, let pid = pid_t(field) else { continue }
            pids.insert(pid)
        }
        return pids
    }
}
