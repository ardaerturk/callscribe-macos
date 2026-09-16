// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CallScribe",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .library(name: "CallScribeCore", targets: ["CallScribeCore"]),
        .library(name: "CallScribeTranscription", targets: ["CallScribeTranscription"]),
        .executable(name: "CallScribe", targets: ["CallScribeApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.6"
        )
    ],
    targets: [
        .target(
            name: "CallScribeCore",
            path: "Sources/CallScribeCore"
        ),
        .target(
            name: "CallScribeTranscription",
            dependencies: [
                "CallScribeCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/CallScribeTranscription"
        ),
        .executableTarget(
            name: "CallScribeApp",
            dependencies: [
                "CallScribeCore",
                "CallScribeTranscription"
            ],
            path: "Sources/CallScribeApp"
        ),
        .testTarget(
            name: "CallScribeAppTests",
            dependencies: ["CallScribeApp"],
            path: "Tests/CallScribeAppTests"
        ),
        .testTarget(
            name: "CallScribeCoreTests",
            dependencies: ["CallScribeCore"],
            path: "Tests/CallScribeCoreTests"
        ),
        .testTarget(
            name: "CallScribeTranscriptionTests",
            dependencies: ["CallScribeTranscription", "CallScribeCore"],
            path: "Tests/CallScribeTranscriptionTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
