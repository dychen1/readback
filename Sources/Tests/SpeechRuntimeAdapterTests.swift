import Foundation
import ReadBackCore
import ReadBackInference

private actor RuntimeFixtureGenerator: MLXSpeechGenerating {
    let sampleRate = 24_000
    private var voice: String?
    private var language: String?
    private var speed: Double?
    private var released = false

    func setSynthesisSpeed(_ speed: Double) async {
        self.speed = speed
    }

    func generateSamples(
        text: String,
        voice: String?,
        language: String?
    ) async -> AsyncThrowingStream<[Float], Error> {
        self.voice = voice
        self.language = language
        return AsyncThrowingStream { continuation in
            continuation.yield([0.1, -0.1])
            continuation.finish()
        }
    }

    func release() async {
        released = true
    }

    func request() -> (voice: String?, language: String?, speed: Double?) {
        (voice, language, speed)
    }

    func wasReleased() -> Bool { released }
}

private actor RuntimeFixtureLoader: MLXSpeechModelLoading {
    private let generator: RuntimeFixtureGenerator

    init(generator: RuntimeFixtureGenerator) {
        self.generator = generator
    }

    func loadModel(from directory: URL) async throws -> any MLXSpeechGenerating {
        generator
    }
}

func speechRuntimeAdapterTests() -> [TestCase] {
    [
        TestCase(name: "runtime adapter registry maps Qwen curated values") {
            let generator = RuntimeFixtureGenerator()
            let registry = DefaultSpeechRuntimeRegistry(
                loader: RuntimeFixtureLoader(generator: generator),
                languageResourceRoots: [],
                clearCache: {}
            )
            let adapter = try registry.makeAdapter(for: .qwen3CustomVoice)
            let directory = try runtimeFixtureDirectory(
                config: #"{"model_type":"qwen3_tts","tts_model_type":"custom_voice"}"#
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            try await adapter.validateModel(at: directory)
            try await adapter.loadModel(at: directory)
            let stream = try await adapter.synthesize(
                ResolvedSpeechRequest(
                    input: "Hello",
                    selection: VoiceSelection(languageCode: "en", voiceID: "ryan"),
                    voiceRuntimeValue: "Ryan",
                    languageRuntimeValue: "English",
                    format: .wav
                )
            )
            var samples: [Float] = []
            for try await chunk in stream { samples.append(contentsOf: chunk) }

            let request = await generator.request()
            let runtimeKind = await adapter.kind
            try expectEqual(runtimeKind, .qwen3CustomVoice, "runtime kind")
            try expectEqual(request.voice, "Ryan", "Qwen voice")
            try expectEqual(request.language, "English", "Qwen language")
            try expectEqual(request.speed, nil, "Qwen synthesis speed")
            try expect(!samples.isEmpty, "Qwen should return samples")
        },
        TestCase(name: "runtime adapter registry keeps Kokoro mapping local") {
            let generator = RuntimeFixtureGenerator()
            let registry = DefaultSpeechRuntimeRegistry(
                loader: RuntimeFixtureLoader(generator: generator),
                languageResourceRoots: [],
                clearCache: {}
            )
            let adapter = try registry.makeAdapter(for: .kokoro)
            let directory = try runtimeFixtureDirectory(config: #"{"model_type":"kokoro"}"#)
            defer { try? FileManager.default.removeItem(at: directory) }

            try await adapter.loadModel(at: directory)
            _ = try await adapter.synthesize(
                ResolvedSpeechRequest(
                    input: "Hello",
                    selection: VoiceSelection(languageCode: "en", voiceID: "af_heart"),
                    voiceRuntimeValue: "af_heart",
                    languageRuntimeValue: "a",
                    format: .wav
                )
            )

            let request = await generator.request()
            try expectEqual(request.voice, "af_heart", "Kokoro voice")
            try expectEqual(request.language, "en-us", "Kokoro language")
            try expectEqual(request.speed, 1, "Kokoro synthesis speed")

            await adapter.unloadModel()
            let released = await generator.wasReleased()
            try expect(released, "Kokoro generator should release")
        },
        TestCase(name: "Qwen runtime adapter rejects Base configuration") {
            let generator = RuntimeFixtureGenerator()
            let registry = DefaultSpeechRuntimeRegistry(
                loader: RuntimeFixtureLoader(generator: generator),
                languageResourceRoots: [],
                clearCache: {}
            )
            let adapter = try registry.makeAdapter(for: .qwen3CustomVoice)
            let directory = try runtimeFixtureDirectory(
                config: #"{"model_type":"qwen3_tts","tts_model_type":"base"}"#
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            do {
                try await adapter.validateModel(at: directory)
                throw TestFailure(description: "Qwen Base should be rejected")
            } catch let error as SpeechRuntimeAdapterError {
                try expectEqual(
                    error,
                    .unsupportedModelConfiguration(.qwen3CustomVoice),
                    "adapter error"
                )
            }
        },
        TestCase(name: "runtime adapter registry maps Chatterbox to its default voice") {
            let generator = RuntimeFixtureGenerator()
            let registry = DefaultSpeechRuntimeRegistry(
                loader: RuntimeFixtureLoader(generator: generator),
                languageResourceRoots: [],
                clearCache: {}
            )
            let adapter = try registry.makeAdapter(for: .chatterboxTurbo)
            let directory = try runtimeFixtureDirectory(
                config: #"{"model_type":"chatterbox_turbo"}"#
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            try await adapter.validateModel(at: directory)
            try await adapter.loadModel(at: directory)
            let stream = try await adapter.synthesize(
                ResolvedSpeechRequest(
                    input: "Hello",
                    selection: VoiceSelection(languageCode: "en", voiceID: "default"),
                    voiceRuntimeValue: "",
                    languageRuntimeValue: "",
                    format: .wav
                )
            )
            var samples: [Float] = []
            for try await chunk in stream { samples.append(contentsOf: chunk) }

            let request = await generator.request()
            let runtimeKind = await adapter.kind
            try expectEqual(runtimeKind, .chatterboxTurbo, "runtime kind")
            try expectEqual(request.voice, nil, "Chatterbox voice")
            try expectEqual(request.language, nil, "Chatterbox language")
            try expectEqual(request.speed, nil, "Chatterbox synthesis speed")
            try expect(!samples.isEmpty, "Chatterbox should return samples")
        },
        TestCase(name: "Chatterbox Turbo adapter rejects regular Chatterbox") {
            let generator = RuntimeFixtureGenerator()
            let registry = DefaultSpeechRuntimeRegistry(
                loader: RuntimeFixtureLoader(generator: generator),
                languageResourceRoots: [],
                clearCache: {}
            )
            let adapter = try registry.makeAdapter(for: .chatterboxTurbo)
            let directory = try runtimeFixtureDirectory(config: #"{"model_type":"chatterbox"}"#)
            defer { try? FileManager.default.removeItem(at: directory) }

            do {
                try await adapter.validateModel(at: directory)
                throw TestFailure(description: "regular Chatterbox should be rejected")
            } catch let error as SpeechRuntimeAdapterError {
                try expectEqual(
                    error,
                    .unsupportedModelConfiguration(.chatterboxTurbo),
                    "adapter error"
                )
            }
        },
    ]
}

private func runtimeFixtureDirectory(config: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
    return directory
}
