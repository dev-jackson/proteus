// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Language choice lives here too so the core can label its own reasoning
/// without the app having to translate a data structure it did not build.
enum CoreLang {
    static let isSpanish: Bool = {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("es")
    }()
}

/// The handful of things a player may need to change after a game is installed.
///
/// Everything Proteus decides is decided from evidence and is right most of the
/// time. The rest of the time the player is stuck: today the only way to change
/// anything is to edit a plist inside an app bundle, which is not a thing to
/// ask of someone who wanted to play a game.
///
/// This is deliberately short. Every switch here exists because players report
/// needing it, not because it was possible to add:
///
/// - **Gamepad off** — the most-repeated workaround in Mac gaming forums is
///   "unplug your controller and it works". Some games poll every HID device
///   they can see and stall on the ones that are not controllers. Turning the
///   whole subsystem off does the same thing without unplugging anything.
/// - **Windowed** — a fullscreen game that renders too small to read is the
///   most common display complaint, and windowed mode is the one reliable
///   escape from it.
/// - **Graphics** — the automatic choice is usually right, and when it is not
///   the player should not have to reinstall to find out.
public struct GameSettings: Sendable, Equatable {

    public var gamepadEnabled: Bool
    public var forceWindowed: Bool
    public var renderer: Prescription.Renderer
    /// Extra command-line flags, kept because some games need one specific
    /// thing and no menu will ever anticipate it.
    public var launchFlags: String

    public init(gamepadEnabled: Bool = true,
                forceWindowed: Bool = false,
                renderer: Prescription.Renderer = .wined3d,
                launchFlags: String = "") {
        self.gamepadEnabled = gamepadEnabled
        self.forceWindowed = forceWindowed
        self.renderer = renderer
        self.launchFlags = launchFlags
    }

    // MARK: - Reading and writing

    public static func read(from wrapper: Wrapper) -> GameSettings {
        let info = (try? wrapper.plist()) ?? [:]
        return GameSettings(
            // Wrappers built before the rename carry the old key names.
            gamepadEnabled: (info["ProteusGamepad"] as? Int ?? info["TandemGamepad"] as? Int ?? 1) == 1,
            forceWindowed: (info["ProteusWindowed"] as? Int ?? info["TandemWindowed"] as? Int ?? 0) == 1,
            renderer: Prescription.Renderer(rawValue: info["ProteusRenderer"] as? String
                ?? info["TandemRenderer"] as? String ?? "wined3d") ?? .wined3d,
            launchFlags: info["Program Flags"] as? String ?? "")
    }

    public func write(to wrapper: Wrapper) throws {
        var values: [String: Any] = [
            "ProteusGamepad": gamepadEnabled ? 1 : 0,
            "ProteusWindowed": forceWindowed ? 1 : 0,
            "ProteusRenderer": renderer.rawValue,
            "Program Flags": launchFlags,
        ]
        // The renderer is a set of DLL overrides the launcher reads; write all
        // of them, including the zeroes, so switching away from one actually
        // turns it off.
        for (key, on) in renderer.plistKeys { values[key] = on ? 1 : 0 }
        try wrapper.setPlistValues(values)
    }

    /// The reasoning recorded at install time, so the panel can say why.
    public struct Reason: Sendable, Identifiable {
        public let id = UUID()
        public let what: String
        public let why: String
    }

    public static func reasons(from wrapper: Wrapper) -> [Reason] {
        let info = (try? wrapper.plist()) ?? [:]
        guard let raw = info["ProteusReasons"] as? [[String: String]] else { return [] }
        return raw.compactMap { entry in
            let what = (CoreLang.isSpanish ? entry["es"] : entry["en"]) ?? entry["en"]
            guard let what, let why = entry["why"] else { return nil }
            return Reason(what: what, why: why)
        }
    }

    /// Renderers worth offering for this game.
    ///
    /// A game that speaks OpenGL or Vulkan itself has nothing to gain from any
    /// DirectX translator, so offering four of them is just four ways to be
    /// wrong. Everything else gets the full list.
    public static func choices(for current: Prescription.Renderer) -> [Prescription.Renderer] {
        current == .native ? [.native] : [.wined3d, .dxmt, .d3dmetal, .dxvk]
    }
}
