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
        ),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0")
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
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit")
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
