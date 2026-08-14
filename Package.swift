// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kurarin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KurarinApp", targets: ["KurarinApp"]),
        .library(name: "KurarinDSP", targets: ["KurarinDSP"]),
    ],
    targets: [
        .target(name: "KurarinDSP"),
        .target(name: "KurarinPresets", dependencies: ["KurarinDSP"]),
        .target(name: "KurarinSoundboard", dependencies: ["KurarinDSP"]),
        .target(name: "KurarinEngine", dependencies: ["KurarinDSP", "KurarinPresets", "KurarinSoundboard"]),
        .executableTarget(name: "KurarinApp", dependencies: ["KurarinEngine", "KurarinPresets", "KurarinSoundboard"]),

        .testTarget(name: "KurarinDSPTests", dependencies: ["KurarinDSP"]),
        .testTarget(name: "KurarinPresetsTests", dependencies: ["KurarinPresets"]),
    ]
)
