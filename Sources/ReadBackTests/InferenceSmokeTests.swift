import Foundation
import ReadBackCore
import ReadBackInference

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
    ]
}
