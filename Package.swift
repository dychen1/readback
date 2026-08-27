// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReadBack",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ReadBackCore", targets: ["ReadBackCore"]),
        .library(name: "ReadBackService", targets: ["ReadBackService"]),
        .library(name: "ReadBackMac", targets: ["ReadBackMac"]),
        .library(name: "ReadBackInference", targets: ["ReadBackInference"]),
        .library(name: "VoicePipeKit", targets: ["VoicePipeKit"]),
        .executable(name: "readback", targets: ["ReadBackVoice"]),
        .executable(name: "voicepipe", targets: ["voicepipe"]),
        .executable(name: "readback-tests", targets: ["ReadBackTests"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.26.0"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird-websocket.git",
            exact: "2.7.0"
        ),
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            exact: "0.1.3"
        ),
    ],
    targets: [
        .target(name: "ReadBackCore"),
        .target(
            name: "ReadBackInference",
            dependencies: [
                "ReadBackCore",
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ]
        ),
        .target(
            name: "ReadBackService",
            dependencies: [
                "ReadBackCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .target(name: "VoicePipeKit", dependencies: ["ReadBackCore"]),
        .target(
            name: "ReadBackMac",
            dependencies: ["VoicePipeKit"]
        ),
        .executableTarget(
            name: "ReadBackVoice",
            dependencies: [
                "ReadBackCore",
                "ReadBackInference",
                "ReadBackMac",
                "ReadBackService",
            ]
        ),
        .executableTarget(
            name: "voicepipe",
            dependencies: ["ReadBackCore", "VoicePipeKit"]
        ),
        .executableTarget(
            name: "ReadBackTests",
            dependencies: [
                "ReadBackCore",
                "ReadBackInference",
                "ReadBackMac",
                "ReadBackService",
                "VoicePipeKit",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
            ]
        ),
    ]
)
