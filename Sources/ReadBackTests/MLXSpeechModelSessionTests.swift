import Foundation
import ReadBackCore
import ReadBackInference

private actor FixtureMLXGenerator: MLXSpeechGenerating {
    let sampleRate = 24_000
    private let samples: [Float]
    private var lastVoice: String?
    private var lastLanguage: String?
    private var lastSpeed: Double?
    private var releaseHandler: (@Sendable () async -> Void)?

    init(samples: [Float], releaseHandler: (@Sendable () async -> Void)? = nil) {
        self.samples = samples
        self.releaseHandler = releaseHandler
    }

    func setSynthesisSpeed(_ speed: Double) async {
        lastSpeed = speed
    }

    func generateSamples(
        text: String,
        voice: String?,
        language: String?
    ) async -> AsyncThrowingStream<[Float], Error> {
        lastVoice = voice
        lastLanguage = language
        let samples = self.samples
        return AsyncThrowingStream { continuation in
            continuation.yield(samples)
            continuation.finish()
        }
    }

    func release() async {
        await releaseHandler?()
        releaseHandler = nil
    }

    func recordedRequest() -> (String?, String?, Double?) {
        (lastVoice, lastLanguage, lastSpeed)
    }
}

private actor FixtureMLXLoader: MLXSpeechModelLoading {
    private let samples: [Float]
    private var loadedCount = 0
    private var maximumLoadedCount = 0
    private var lastGenerator: FixtureMLXGenerator?

    init(samples: [Float] = [0.1, -0.1]) {
        self.samples = samples
    }

    func loadModel(from directory: URL) async throws -> any MLXSpeechGenerating {
        loadedCount += 1
        maximumLoadedCount = max(maximumLoadedCount, loadedCount)
        let generator = FixtureMLXGenerator(samples: samples) { [weak self] in
            await self?.didRelease()
        }
        lastGenerator = generator
        return generator
    }

    func didRelease() { loadedCount -= 1 }
    func maximumCount() -> Int { maximumLoadedCount }
    func generator() -> FixtureMLXGenerator? { lastGenerator }
}

func mlxSpeechModelSessionTests() -> [TestCase] {
    [
        TestCase(name: "MLX session unloads before another model loads") {
            let loader = FixtureMLXLoader()
            let session = MLXSpeechModelSession(loader: loader, clearCache: {})
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let first = root.appendingPathComponent("first", isDirectory: true)
            let second = root.appendingPathComponent("second", isDirectory: true)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try Data(#"{"model_type":"kokoro"}"#.utf8)
                .write(to: first.appendingPathComponent("config.json"))
            try Data(#"{"model_type":"kokoro"}"#.utf8)
                .write(to: second.appendingPathComponent("config.json"))

            try await session.load(from: first, profile: .kokoro)
            await session.unload()
            try await session.load(from: second, profile: .kokoro)

            let maximumCount = await loader.maximumCount()
            try expectEqual(maximumCount, 1, "maximum loaded models")
        },
        TestCase(name: "MLX session maps Kokoro language and speed") {
            let loader = FixtureMLXLoader()
            let session = MLXSpeechModelSession(loader: loader, clearCache: {})
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"model_type":"kokoro"}"#.utf8)
                .write(to: directory.appendingPathComponent("config.json"))
            try await session.load(from: directory, profile: .kokoro)

            _ = try await session.synthesize(
                SpeechRequest(
                    input: "Hello",
                    voice: "bf_emma",
                    languageCode: "b",
                    speed: 1.25,
                    format: .wav
                )
            )

            let loadedGenerator = await loader.generator()
            let generator = try required(loadedGenerator, "generator")
            let recorded = await generator.recordedRequest()
            try expectEqual(recorded.0, "bf_emma", "voice")
            try expectEqual(recorded.1, "en-gb", "language")
            try expectEqual(recorded.2, 1, "speed")
        },
        TestCase(name: "MLX session rejects empty generated audio") {
            let loader = FixtureMLXLoader(samples: [])
            let session = MLXSpeechModelSession(loader: loader, clearCache: {})
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"model_type":"kokoro"}"#.utf8)
                .write(to: directory.appendingPathComponent("config.json"))
            try await session.load(from: directory, profile: .kokoro)

            do {
                _ = try await session.synthesize(
                    SpeechRequest(
                        input: "Hello",
                        voice: nil,
                        languageCode: nil,
                        speed: 1,
                        format: .wav
                    )
                )
                throw TestFailure(description: "empty audio should fail")
            } catch let error as MLXSpeechModelSessionError {
                try expectEqual(error, .noAudioGenerated, "session error")
            }
        },
    ]
}

private func required<Value>(_ value: Value?, _ name: String) throws -> Value {
    guard let value else { throw TestFailure(description: "missing \(name)") }
    return value
}
