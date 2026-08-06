// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Things about specific games that no amount of binary reading can discover.
///
/// Proton's whole compatibility story rests on `protonfixes`: a table of
/// hand-written patches keyed by app ID, applied before the game starts. It
/// works, and it is the honest admission that evidence runs out somewhere.
///
/// This is the same idea kept deliberately small. An entry earns its place only
/// when the fact is genuinely underivable — not merely inconvenient to derive.
/// Everything the binary or the file layout can answer is answered there, where
/// it applies to every game rather than to one.
public struct KnownTitle: Sendable {
    /// How to recognise the game from its installed folder.
    public let matches: @Sendable (URL) -> Bool
    public let nameEN: String
    /// Why this entry exists, shown to the user rather than applied silently.
    public let reasonEN: String
    public let reasonES: String

    public var renderer: Prescription.Renderer?
    public var extraArguments: [String]
    public var extraVerbs: [String]
    /// Force the Game Porting Toolkit engine even if nothing imported d3d12.
    public var needsGPTK: Bool

    public init(nameEN: String, reasonEN: String, reasonES: String,
                renderer: Prescription.Renderer? = nil,
                extraArguments: [String] = [], extraVerbs: [String] = [],
                needsGPTK: Bool = false,
                matches: @escaping @Sendable (URL) -> Bool) {
        self.nameEN = nameEN
        self.reasonEN = reasonEN
        self.reasonES = reasonES
        self.renderer = renderer
        self.extraArguments = extraArguments
        self.extraVerbs = extraVerbs
        self.needsGPTK = needsGPTK
        self.matches = matches
    }

    // MARK: - The table

    static func has(_ file: String, in directory: URL) -> Bool {
        FileManager().fileExists(atPath: directory.appendingPathComponent(file).path)
    }

    /// GZDoom draws its whole interface through Vulkan or OpenGL and never
    /// touches Direct3D, so every DirectX translator is dead weight. Naming the
    /// renderer here is not a fix, it is a statement of fact the file layout
    /// already implies — kept as the worked example of what an entry looks like.
    public static let gzdoom = KnownTitle(
        nameEN: "GZDoom",
        reasonEN: "Draws through Vulkan or OpenGL directly; no DirectX translation applies.",
        reasonES: "Dibuja por Vulkan u OpenGL directamente; ninguna traducción DirectX le sirve.",
        renderer: .native,
        matches: { has("gzdoom.exe", in: $0) })

    /// Steam updates itself on first run and needs its own sandbox disabled to
    /// do it under Wine — a fact about Steam, discoverable only by watching it
    /// fail, and true of no other program.
    public static let steam = KnownTitle(
        nameEN: "Steam",
        reasonEN: "Its embedded browser sandbox cannot start under Wine; disabling it lets Steam update itself.",
        reasonES: "Su navegador interno no arranca bajo Wine; desactivarlo permite que Steam se actualice.",
        extraArguments: ["-no-cef-sandbox"],
        matches: { has("steam.exe", in: $0) })

    public static let all: [KnownTitle] = [gzdoom, steam]

    /// The entry for this installed game, if there is one.
    public static func match(_ gameDir: URL) -> KnownTitle? {
        all.first { $0.matches(gameDir) }
    }
}
