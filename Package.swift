// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tandem",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ProteusCore"),
        .executableTarget(name: "proteus-cli", dependencies: ["ProteusCore"]),
        .executableTarget(name: "ProteusApp", dependencies: ["ProteusCore"]),
        .executableTarget(name: "proteus-launcher"),
    ]
)
