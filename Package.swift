// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Proteus",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ProteusCore"),
        .executableTarget(name: "proteus-cli", dependencies: ["ProteusCore"]),
        .executableTarget(name: "ProteusApp", dependencies: ["ProteusCore"]),
        .executableTarget(name: "proteus-launcher"),
        .testTarget(name: "ProteusCoreTests", dependencies: ["ProteusCore"]),
    ]
)
