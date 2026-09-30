// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxCode",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Used by the iOS app project in VoxCodeMobile/.
        .library(name: "VoxUI", targets: ["VoxUI", "VoxCodeCore"]),
    ],
    targets: [
        // Pure logic: agent adapters, output parsing, prompt building, local runner, bridge client.
        .target(name: "VoxCodeCore"),
        // Shared by the Mac and iPhone apps: audio, speech, TTS, app state and views.
        .target(name: "VoxUI", dependencies: ["VoxCodeCore"], resources: [.process("Resources")]),
        // macOS app.
        .executableTarget(name: "VoxCode", dependencies: ["VoxUI", "VoxCodeCore"]),
        .testTarget(name: "VoxCodeCoreTests", dependencies: ["VoxCodeCore"]),
        .testTarget(name: "VoxUITests", dependencies: ["VoxUI"]),
    ],
    swiftLanguageModes: [.v5]
)
