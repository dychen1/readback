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
        .library(name: "ReadBackSkill", targets: ["ReadBackSkill"]),
        .library(name: "VoicePipeKit", targets: ["VoicePipeKit"]),
        .executable(name: "readback", targets: ["ReadBackVoice"]),
        .executable(name: "readback-skill-client", targets: ["ReadBackSkillClientCommand"]),
        .executable(name: "voicepipe", targets: ["voicepipe"]),
        .executable(name: "readback-tests", targets: ["ReadBackTests"]),
    ],
    dependencies: [
        .package(path: "Vendor/hummingbird-websocket"),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.26.0"
        ),
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            exact: "0.1.3"
        ),
    ],
    targets: [
        .target(name: "ReadBackCore", path: "Sources/Core"),
        .target(
            name: "ReadBackInference",
            dependencies: [
                "ReadBackCore",
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ],
            path: "Sources/Inference"
        ),
        .target(
            name: "ReadBackService",
            dependencies: [
                "ReadBackCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            path: "Sources/Service"
        ),
        .target(name: "ReadBackSkill", path: "Sources/Skill"),
        .target(name: "VoicePipeKit", dependencies: ["ReadBackCore"]),
        .target(
            name: "ReadBackMac",
            dependencies: ["VoicePipeKit"],
            path: "Sources/Mac"
        ),
        .executableTarget(
            name: "ReadBackVoice",
            dependencies: [
                "ReadBackCore",
                "ReadBackInference",
                "ReadBackMac",
                "ReadBackService",
                "ReadBackSkill",
            ],
            path: "Sources/Voice",
            // SwiftPM does not define DEBUG for the debug configuration on its own
            // (unlike Xcode); this target's #if DEBUG dev-convenience fallback
            // relies on it being defined explicitly here.
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "ReadBackSkillClientCommand",
            dependencies: ["ReadBackSkill"],
            path: "Sources/readback-skill-client"
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
                "ReadBackSkill",
                "VoicePipeKit",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
            ],
            path: "Sources/Tests"
        ),
    ]
)
