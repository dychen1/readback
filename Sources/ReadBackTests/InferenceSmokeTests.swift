import Foundation
import ReadBackCore
import ReadBackInference

private actor SmokeProgressReporter {
    private let label: String
    private var lastReportedPercent = -5

    init(label: String = "Qwen") {
        self.label = label
    }

    func report(_ progress: Double) {
        let percent = Int(progress * 100)
        guard percent >= lastReportedPercent + 5 else { return }
        lastReportedPercent = percent
        print("\(label) install: \(percent)%")
    }
}

func inferenceSmokeTests() -> [TestCase] {
    [
        TestCase(name: "native Kokoro generates a local WAV") {
            guard ProcessInfo.processInfo.environment["READBACK_RUN_INFERENCE_SMOKE"] == "1" else {
                return
            }
            let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let model = project.appendingPathComponent("models/Kokoro-82M-bf16", isDirectory: true)
            let languages = project.appendingPathComponent("models/Languages", isDirectory: true)
            let runtime = KokoroSpeechSynthesizer(
                modelDirectoryURL: model,
                languageResourceRoots: [languages]
            )

            let clip = try await runtime.synthesize(
                SpeechRequest(
                    input: "Hello from ReadBack.",
                    voice: "af_heart",
                    languageCode: "a",
                    speed: 1,
                    format: .wav
                )
            )

            try expectEqual(clip.format, .wav, "smoke audio format")
            try expect(clip.data.count > 44, "smoke WAV should contain samples")
            try expectEqual(
                String(decoding: clip.data.prefix(4), as: UTF8.self),
                "RIFF",
                "smoke WAV header"
            )
        },
        TestCase(name: "curated Qwen 8-bit installs and generates a local WAV") {
            let environment = ProcessInfo.processInfo.environment
            guard environment["READBACK_RUN_QWEN_SMOKE"] == "1"
                    || environment["READBACK_RUN_QWEN_8BIT_SMOKE"] == "1"
            else { return }
            try await runQwenSmoke(modelID: .qwen3CustomVoice06B8Bit)
        },
        TestCase(name: "curated Qwen BF16 installs and generates a local WAV") {
            guard ProcessInfo.processInfo.environment["READBACK_RUN_QWEN_BF16_SMOKE"] == "1"
            else { return }
            try await runQwenSmoke(modelID: .qwen3CustomVoice06BBF16)
        },
        TestCase(name: "curated Chatterbox Turbo 8-bit installs and generates a local WAV") {
            guard ProcessInfo.processInfo.environment["READBACK_RUN_CHATTERBOX_8BIT_SMOKE"] == "1"
            else { return }
            try await runChatterboxSmoke(modelID: .chatterboxTurbo8Bit)
        },
        TestCase(name: "curated Chatterbox Turbo FP16 installs and generates a local WAV") {
            guard ProcessInfo.processInfo.environment["READBACK_RUN_CHATTERBOX_FP16_SMOKE"] == "1"
            else { return }
            try await runChatterboxSmoke(modelID: .chatterboxTurboFP16)
        },
    ]
}

private func runQwenSmoke(modelID: ModelID) async throws {
    let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("ReadBack", isDirectory: true)
    let session = MLXSpeechModelSession()
    let library = ModelLibrary(
        catalog: .bundled,
        paths: ModelLibraryPaths(
            managedModelsURL: support.appendingPathComponent("Models", isDirectory: true),
            downloadsURL: support.appendingPathComponent("Downloads", isDirectory: true),
            localRegistrationURL: support.appendingPathComponent("local-model.json")
        ),
        bundledModels: [:],
        validator: session
    )
    if await library.storageState(for: modelID) != .installed {
        let reporter = SmokeProgressReporter()
        try await library.install(modelID) { progress in
            await reporter.report(progress)
        }
    }

    let location = try await library.location(for: modelID)
    try await session.load(from: location.directoryURL, profile: .qwen3CustomVoice)
    let clip = try await session.synthesize(
        SpeechRequest(
            input: "test, hello world",
            voice: "Ryan",
            languageCode: "English",
            speed: 1,
            format: .wav
        )
    )
    await session.unload()

    try expectEqual(clip.format, .wav, "Qwen smoke audio format")
    try expect(clip.data.count > 44, "Qwen smoke WAV should contain samples")
    try expectEqual(
        String(decoding: clip.data.prefix(4), as: UTF8.self),
        "RIFF",
        "Qwen smoke WAV header"
    )
}

private func runChatterboxSmoke(modelID: ModelID) async throws {
    let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("ReadBack", isDirectory: true)
    let session = MLXSpeechModelSession()
    let library = ModelLibrary(
        catalog: .bundled,
        paths: ModelLibraryPaths(
            managedModelsURL: support.appendingPathComponent("Models", isDirectory: true),
            downloadsURL: support.appendingPathComponent("Downloads", isDirectory: true),
            localRegistrationURL: support.appendingPathComponent("local-model.json")
        ),
        bundledModels: [:],
        validator: session
    )
    if await library.storageState(for: modelID) != .installed {
        let reporter = SmokeProgressReporter(label: "Chatterbox")
        try await library.install(modelID) { progress in
            await reporter.report(progress)
        }
    }

    let location = try await library.location(for: modelID)
    try await session.load(from: location.directoryURL, profile: .chatterboxTurbo)
    let clip = try await session.synthesize(
        SpeechRequest(
            input: "test, hello world",
            voice: "",
            languageCode: "",
            speed: 1,
            format: .wav
        )
    )
    await session.unload()

    try expectEqual(clip.format, .wav, "Chatterbox smoke audio format")
    try expect(clip.data.count > 44, "Chatterbox smoke WAV should contain samples")
    try expectEqual(
        String(decoding: clip.data.prefix(4), as: UTF8.self),
        "RIFF",
        "Chatterbox smoke WAV header"
    )
}
