import Foundation

// The program that runs when someone double-clicks a Proteus game.
//
// It exists for one reason: identity. Wine executed as a bare binary registers
// with macOS as an anonymous process called "wine" — no name, no bundle
// identifier. The game then shows up as "wine" in the Dock and in Force Quit,
// and no accessibility or automation tool can address it, because there is
// nothing to address.
//
// Running the same binary from inside a small .app bundle fixes all of that:
// macOS reads the bundle's Info.plist and the process becomes "Cave Story"
// with the wrapper's own identifier. The catch is that the bundle path has to
// be the path passed to exec — a symlink or a shell shim is resolved too late
// and the identity is lost. So this launcher lives in the wrapper, works out
// the environment, and execs the runtime bundle directly.

let bundle = Bundle.main
let contents = bundle.bundleURL.appendingPathComponent("Contents")
let sharedSupport = contents.appendingPathComponent("SharedSupport")
let wineRoot = sharedSupport.appendingPathComponent("wine")
let runtimeBinary = wineRoot.appendingPathComponent("Runtime.app/Contents/MacOS/wine")

func fail(_ message: String) -> Never {
    // No terminal is attached to a double-click, so say it where it will be
    // seen rather than into a void.
    let script = "display alert \"This game could not start\" message \"\(message)\" as critical"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
    process.waitUntilExit()
    exit(1)
}

let info = bundle.infoDictionary ?? [:]
guard let program = info["Program Name and Path"] as? String, !program.isEmpty,
      program != "/nothing.exe" else {
    fail("This wrapper has no game set.")
}
guard FileManager.default.isExecutableFile(atPath: runtimeBinary.path) else {
    fail("The Wine runtime is missing from this app.")
}

// MARK: - Environment

var env = ProcessInfo.processInfo.environment
env["WINEPREFIX"] = sharedSupport.appendingPathComponent("prefix").path
env["WINEDLLPATH"] = wineRoot.appendingPathComponent("lib/wine").path
env["DYLD_FALLBACK_LIBRARY_PATH"] = [
    wineRoot.appendingPathComponent("lib").path,
    contents.appendingPathComponent("Frameworks").path,
    "/usr/local/lib", "/usr/lib",
].joined(separator: ":")
env["PATH"] = wineRoot.appendingPathComponent("bin").path + ":"
    + (env["PATH"] ?? "/usr/bin:/bin")
env["WINEDEBUG"] = (info["Debug Mode"] as? Int == 1) ? "+all" : "-all"
env["WINEESYNC"] = "1"
env["WINEMSYNC"] = "1"
// Never stop to ask about Gecko or Mono: the prefix was prepared at install
// time and a modal dialog here would look like a hang.
env["WINEDLLOVERRIDES"] = "mscoree,mshtml="

/// The graphics translator is a set of DLL overrides. Proteus picked it from
/// what the game imports; here we just switch it on.
@MainActor
func renderer(_ key: String) -> Bool { (info[key] as? Int ?? 0) == 1 }
var overrides: [String] = ["mscoree=", "mshtml="]
if renderer("DXMT") {
    overrides += ["d3d10core,d3d11,dxgi=n,b"]
} else if renderer("D3DMETAL") {
    overrides += ["d3d10core,d3d11,d3d12,d3d12core,dxgi=n,b"]
} else if renderer("DXVK") {
    overrides += ["d3d10core,d3d11,d3d9,dxgi=n,b"]
}
env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")

if let extra = info["Metal HUD"] as? Int, extra == 1 {
    env["MTL_HUD_ENABLED"] = "1"
}

// The most-repeated workaround in Mac gaming forums is "unplug your controller
// and the game responds again": some games poll every HID device they can see
// and stall on the ones that are not controllers. Turning the subsystem off
// does the same thing without asking anyone to unplug hardware.
if (info["ProteusGamepad"] as? Int ?? info["TandemGamepad"] as? Int ?? 1) == 0 {
    env["SDL_JOYSTICK_DISABLE_UDEV"] = "1"
    env["WINE_DISABLE_HID"] = "1"
    env["SDL_GAMECONTROLLERCONFIG"] = ""
    var overridesWithoutInput = overrides
    // Keep Wine from loading the joystick stack at all.
    overridesWithoutInput.append("winebus,hidclass,dinput,dinput8,xinput1_3,xinput1_4=")
    env["WINEDLLOVERRIDES"] = overridesWithoutInput.joined(separator: ";")
}

// MoltenVK turns Metal argument buffers on by default from 1.2.11 onwards.
// That is the right choice for a native Vulkan application and the wrong one
// underneath a D3D translation layer, where it measurably costs frame rate.
// Games are the whole audience here, so it goes off.
env["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"] = "0"
// Let the driver batch work across frames instead of stalling on each one.
env["MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS"] = "1"
// Shader conversion is expensive and identical every launch; cache it so only
// the first run pays for it.
env["MVK_CONFIG_SHADER_CONVERSION_FLIP_VERTEX_Y"] = env["MVK_CONFIG_SHADER_CONVERSION_FLIP_VERTEX_Y"] ?? "1"

// MARK: - Keep a record

// A game that quits mid-play leaves the user with nothing to look at: no crash
// report, because it exited cleanly, and no console, because it was launched
// from the Finder. Whatever it printed on the way out is the only evidence
// there is, so it goes to a file inside the app.
let logsDirectory = contents.appendingPathComponent("Logs")
try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
let logFile = logsDirectory.appendingPathComponent("last-run.log")
// Keep the previous run: the interesting one is often the run before the one
// the user just reproduced.
let previous = logsDirectory.appendingPathComponent("previous-run.log")
try? FileManager.default.removeItem(at: previous)
try? FileManager.default.moveItem(at: logFile, to: previous)
FileManager.default.createFile(atPath: logFile.path, contents: nil)

if let handle = FileHandle(forWritingAtPath: logFile.path) {
    let header = "=== \(program) — \(Date()) ===\n"
    try? handle.write(contentsOf: Data(header.utf8))
    // Replace this process's own stdout and stderr, which the exec'd game
    // inherits. Nothing else needs to know.
    dup2(handle.fileDescriptor, STDOUT_FILENO)
    dup2(handle.fileDescriptor, STDERR_FILENO)
}
// Ask Wine for the failures it normally keeps quiet about, without the trace
// flood that would bury them.
env["WINEDEBUG"] = (info["Debug Mode"] as? Int == 1) ? "+all" : "fixme-all,err+all"

// MARK: - Launch

var arguments = [runtimeBinary.path, program]
if let flags = info["Program Flags"] as? String, !flags.isEmpty {
    // Flags are stored the way a Windows user would type them.
    arguments += flags.split(separator: " ").map(String.init)
}
// Anything passed to the app (a save file dropped on the icon) follows.
arguments += CommandLine.arguments.dropFirst()

// A fullscreen game that renders too small to read is the commonest display
// complaint on macOS, and Wine cannot switch the display to the low resolutions
// those games ask for. Windowed mode is the one reliable escape.
if (info["ProteusWindowed"] as? Int ?? info["TandemWindowed"] as? Int ?? 0) == 1 {
    env["WINE_FORCE_WINDOWED"] = "1"
}

// Start in the game's own folder: plenty of games look for their data with a
// relative path and find nothing if the working directory is "/".
let prefixC = sharedSupport.appendingPathComponent("prefix/drive_c")
if program.hasPrefix("C:\\") || program.hasPrefix("c:\\") {
    let relative = program.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
    let onDisk = prefixC.appendingPathComponent(relative).deletingLastPathComponent()
    FileManager.default.changeCurrentDirectoryPath(onDisk.path)
}

// exec, not spawn: the launcher must not stay around as a second process, and
// the game inherits the bundle identity we were started with.
let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
execve(runtimeBinary.path, argv, envp)

// execve only returns on failure.
fail("The Wine runtime could not be started (\(String(cString: strerror(errno)))).")
