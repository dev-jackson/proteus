import Foundation
import CoreGraphics
import AppKit

/// Proves that keyboard and mouse actually reach the game.
///
/// Under Wine this is not a given: a game can open a perfectly good window and
/// then receive nothing, which looks like a frozen game and is impossible to
/// diagnose from outside.
///
/// The first version of this compared screenshots before and after sending
/// input. That does not work. Cave Story's menu arrow moves about 2.5% of the
/// picture while its animated title screen moves 3.3% on its own — the real
/// reaction scores *lower* than the noise, and no threshold separates them.
///
/// So this measures delivery instead of appearance. Wine's Mac driver logs
/// every input event it hands to a window; with `WINEDEBUG=+key,+cursor` the
/// game's own log says, unambiguously, how many of our events arrived and
/// which window handle got them. Sending eight mouse moves and finding eight
/// `macdrv_mouse_moved` lines is proof, not inference.
public struct InputCheck {

    public struct Report: Sendable {
        public enum Outcome: String, Sendable {
            case delivered      // Wine handed our events to the game
            case notDelivered   // events were sent but never arrived
            case noWindow       // never got a window to send input to
        }
        public let keyboard: Outcome
        public let mouse: Outcome
        public let keysSent: Int
        public let keysDelivered: Int
        public let mouseMovesSent: Int
        public let mouseMovesDelivered: Int
        public let windowTitle: String?
        /// The Windows window handle Wine routed key events to, when it said.
        public let targetWindowHandle: String?

        public var passed: Bool { keyboard == .delivered }

        public var summaryEN: String {
            switch (keyboard, mouse) {
            case (.noWindow, _): return "no window to test"
            case (.delivered, .delivered):
                return "keyboard and mouse both reach the game (\(keysDelivered)/\(keysSent) keys, \(mouseMovesDelivered)/\(mouseMovesSent) mouse moves)"
            case (.delivered, _):
                return "keyboard reaches the game (\(keysDelivered)/\(keysSent) keys); mouse did not arrive"
            case (_, .delivered):
                return "mouse reaches the game; keyboard did not arrive"
            default: return "neither keyboard nor mouse reached the game"
            }
        }

        public var summaryES: String {
            switch (keyboard, mouse) {
            case (.noWindow, _): return "no hay ventana que probar"
            case (.delivered, .delivered):
                return "teclado y ratón llegan al juego (\(keysDelivered)/\(keysSent) teclas, \(mouseMovesDelivered)/\(mouseMovesSent) movimientos)"
            case (.delivered, _):
                return "el teclado llega al juego (\(keysDelivered)/\(keysSent) teclas); el ratón no llegó"
            case (_, .delivered):
                return "el ratón llega al juego; el teclado no llegó"
            default: return "ni el teclado ni el ratón llegaron al juego"
            }
        }
    }

    /// Wine's Mac driver traces. `macdrv_send_keyboard_input` is the moment a
    /// key is handed to a specific window; `macdrv_mouse_moved` is the pointer
    /// arriving. Both only appear with the right WINEDEBUG channels.
    public static let debugChannels = "-all,+key,+cursor"

    static let keyDeliveryMarker = "macdrv_send_keyboard_input"
    static let mouseDeliveryMarker = "macdrv_mouse_moved"

    /// Arrow keys: present in every game's menu, destructive in none.
    static let keySequence: [CGKeyCode] = [125, 126, 125]   // down, up, down
    static let mouseMoveCount = 8

    public init() {}

    // MARK: - Evidence for humans

    /// Captures one window to a PNG.
    ///
    /// `screencapture -l` grabs the window by id, so it works even when the
    /// game is behind something else — no need to fight the window server for
    /// focus just to take a picture. (`CGWindowListCreateImage` would have been
    /// the in-process way, but it was obsoleted in macOS 15 and now silently
    /// returns nil.)
    @discardableResult
    public func screenshot(_ window: GameWindow, to file: URL) -> Bool {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let result = Shell.run("/usr/sbin/screencapture",
                               ["-x", "-o", "-l\(window.id)", file.path], timeout: 25)
        return result.exitCode == 0 && FileManager.default.fileExists(atPath: file.path)
    }

    // MARK: - Sending

    /// Sends the test input. Returns how many events were posted.
    public func send(to window: GameWindow) -> (keys: Int, mouseMoves: Int) {
        focus(window)
        Thread.sleep(forTimeInterval: 1.2)

        for code in Self.keySequence {
            post(keyCode: code)
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 0.6)

        // Movement only. A click could start a level, or quit to desktop,
        // depending entirely on which game this is.
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return (Self.keySequence.count, 0)
        }
        for i in 0..<Self.mouseMoveCount {
            let point = CGPoint(x: window.bounds.minX + window.bounds.width * (0.25 + Double(i) * 0.06),
                                y: window.bounds.minY + window.bounds.height * (0.30 + Double(i) * 0.05))
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.25)
        }
        return (Self.keySequence.count, Self.mouseMoveCount)
    }

    /// A real click at a screen point, for answering a dialog the game drew
    /// itself — Wine paints those, so there is no button for macOS to press.
    public func click(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.4)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.12)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    public func post(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Reading the verdict out of Wine's own log

    public func verdict(fromLog log: String, sent: (keys: Int, mouseMoves: Int),
                        window: GameWindow?) -> Report {
        guard let window else {
            return Report(keyboard: .noWindow, mouse: .noWindow, keysSent: 0, keysDelivered: 0,
                          mouseMovesSent: 0, mouseMovesDelivered: 0,
                          windowTitle: nil, targetWindowHandle: nil)
        }
        var keyHits = 0
        var mouseHits = 0
        var handle: String?

        for line in log.split(whereSeparator: \.isNewline) {
            if line.contains(Self.keyDeliveryMarker) {
                keyHits += 1
                if handle == nil, let range = line.range(of: "hwnd 0x") {
                    let rest = line[range.upperBound...].prefix { $0.isHexDigit }
                    if !rest.isEmpty { handle = "0x" + rest }
                }
            } else if line.contains(Self.mouseDeliveryMarker) {
                mouseHits += 1
            }
        }

        // Wine emits a trace for key-down and key-up, so a press shows twice.
        let keysDelivered = min(sent.keys, keyHits / 2)
        let mouseDelivered = min(sent.mouseMoves, mouseHits)

        return Report(keyboard: keysDelivered > 0 ? .delivered : .notDelivered,
                      mouse: mouseDelivered > 0 ? .delivered : .notDelivered,
                      keysSent: sent.keys, keysDelivered: keysDelivered,
                      mouseMovesSent: sent.mouseMoves, mouseMovesDelivered: mouseDelivered,
                      windowTitle: window.title, targetWindowHandle: handle)
    }

    // MARK: - Window

    /// Titles that mean "this is a browser, not the game". Installers routinely
    /// open the project's web page on finish, and that window is Wine's too.
    static let browserWindowHints = ["mozilla", "internet explorer", "chrome", "safari",
                                     "http://", "https://", "- wine internet"]

    public struct GameWindow: Sendable {
        public let id: CGWindowID
        public let pid: pid_t
        public let title: String?
        public let bounds: CGRect
    }

    public func findWindow(executableName: String) -> GameWindow? {
        let pids = pidsRunning(executableName)
        guard !pids.isEmpty else { return nil }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: GameWindow?
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? Double, let y = boundsDict["Y"] as? Double,
                  let w = boundsDict["Width"] as? Double, let h = boundsDict["Height"] as? Double,
                  w >= 200, h >= 150 else { continue }
            let title = window[kCGWindowName as String] as? String
            if let title, Self.browserWindowHints.contains(where: { title.lowercased().contains($0) }) {
                continue
            }
            let candidate = GameWindow(id: number, pid: pid, title: title,
                                       bounds: CGRect(x: x, y: y, width: w, height: h))
            // Largest window wins: Wine keeps small helper windows around.
            if best == nil || candidate.bounds.width * candidate.bounds.height
                > best!.bounds.width * best!.bounds.height {
                best = candidate
            }
        }
        return best
    }

    func pidsRunning(_ exeName: String) -> Set<pid_t> {
        let result = Shell.run("/bin/ps", ["-axo", "pid=,command="], timeout: 15)
        var pids = Set<pid_t>()
        for line in result.stdout.split(whereSeparator: \.isNewline)
        where line.lowercased().contains(exeName.lowercased()) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let field = trimmed.split(separator: " ").first, let pid = pid_t(field) {
                pids.insert(pid)
            }
        }
        return pids
    }

    public func focus(_ window: GameWindow) {
        // Wine's windows belong to a process AppKit does not know by name, so
        // activate by pid rather than by application name.
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateAllWindows])
    }
}
