// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kurarin",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "KurarinApp", targets: ["KurarinApp"]),
        .library(name: "KurarinDSP", targets: ["KurarinDSP"]),
    ],
    targets: [
        .target(name: "KurarinAtomics"),
        // Test-only: proves the audio path allocates nothing.
        .target(name: "KurarinAllocProbe"),
        .target(name: "KurarinDSP", dependencies: ["KurarinAtomics"]),
        .target(name: "KurarinPresets", dependencies: ["KurarinDSP"]),
        .target(name: "KurarinRecording", dependencies: ["KurarinAtomics", "KurarinDSP"]),
        .target(name: "KurarinSoundboard", dependencies: ["KurarinDSP", "KurarinAtomics"]),
        .target(name: "KurarinEngine", dependencies: ["KurarinDSP", "KurarinPresets", "KurarinSoundboard", "KurarinRecording"]),
        .executableTarget(name: "KurarinApp", dependencies: ["KurarinEngine", "KurarinPresets", "KurarinSoundboard", "KurarinRecording"]),

        .testTarget(name: "KurarinDSPTests", dependencies: ["KurarinDSP", "KurarinAllocProbe"]),
        .testTarget(name: "KurarinPresetsTests", dependencies: ["KurarinPresets"]),
        .testTarget(name: "KurarinRecordingTests", dependencies: ["KurarinRecording", "KurarinAllocProbe"]),
        .testTarget(name: "KurarinSoundboardTests", dependencies: ["KurarinSoundboard", "KurarinAllocProbe"]),
        .testTarget(name: "KurarinEngineTests", dependencies: ["KurarinEngine", "KurarinAllocProbe"]),
    ]
)
