// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "CodexGlance",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexGlance", targets: ["CodexGlance"]),
        .library(name: "CodexGlanceCore", targets: ["CodexGlanceCore"])
    ],
    targets: [
        .target(name: "CodexGlanceCore"),
        .executableTarget(
            name: "CodexGlance",
            dependencies: ["CodexGlanceCore"]
        ),
        .testTarget(
            name: "CodexGlanceCoreTests",
            dependencies: ["CodexGlanceCore"]
        )
    ]
)
