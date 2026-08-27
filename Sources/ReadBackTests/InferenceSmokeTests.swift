import Foundation
import ReadBackCore
import ReadBackInference

private actor SmokeProgressReporter {
    private var lastReportedPercent = -5

    func report(_ progress: Double) {
        let percent = Int(progress * 100)
        guard percent >= lastReportedPercent + 5 else { return }
        lastReportedPercent = percent
        print("Qwen install: \(percent)%")
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
        TestCase(name: "curated Qwen installs and generates a local WAV") {
            guard ProcessInfo.processInfo.environment["READBACK_RUN_QWEN_SMOKE"] == "1" else {
                return
            }
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
            let modelID = ModelID.qwen3CustomVoice06B8Bit
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
        },
    ]
}
