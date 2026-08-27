import Foundation
import MLX
import MLXAudioTTS
import ReadBackCore

public enum MLXSpeechModelSessionError: Error, Equatable, Sendable {
    case modelDirectoryMissing(URL)
    case modelNotLoaded
    case noAudioGenerated
}

public protocol MLXSpeechGenerating: Sendable {
    var sampleRate: Int { get async }

    func generateSamples(
        text: String,
        voice: String?,
        language: String?,
        speed: Double,
        profile: MLXRuntimeProfile
    ) async -> AsyncThrowingStream<[Float], Error>

    func release() async
}

public protocol MLXSpeechModelLoading: Sendable {
    func loadModel(from directory: URL) async throws -> any MLXSpeechGenerating
}

public struct DefaultMLXSpeechModelLoader: MLXSpeechModelLoading {
    public init() {}

    public func loadModel(from directory: URL) async throws -> any MLXSpeechGenerating {
        let model = try await TTS.loadModel(modelRepo: directory.standardizedFileURL.path)
        return MLXSpeechGenerationAdapter(model: model)
    }
}

public actor MLXSpeechGenerationAdapter: MLXSpeechGenerating {
    private var model: SpeechGenerationModel?

    public init(model: SpeechGenerationModel) {
        self.model = model
    }

    public var sampleRate: Int { model?.sampleRate ?? 24_000 }

    public func generateSamples(
        text: String,
        voice: String?,
        language: String?,
        speed: Double,
        profile: MLXRuntimeProfile
    ) async -> AsyncThrowingStream<[Float], Error> {
        guard let model else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: MLXSpeechModelSessionError.modelNotLoaded)
            }
        }
        if profile == .kokoro, let kokoro = model as? KokoroModel {
            kokoro.speed = Float(speed)
        }
        return model.generateSamplesStream(
            text: text,
            voice: voice,
            refAudio: nil,
            refText: nil,
            language: language
        )
    }

    public func release() async {
        model = nil
    }
}

public actor MLXSpeechModelSession: MLXModelSession {
    private let loader: any MLXSpeechModelLoading
    private let fileManager: FileManager
    private let languageResourceRoots: [URL]
    private let clearCache: @Sendable () -> Void
    private var model: (any MLXSpeechGenerating)?
    private var profile: MLXRuntimeProfile?

    public init(
        loader: any MLXSpeechModelLoading = DefaultMLXSpeechModelLoader(),
        languageResourceRoots: [URL] = [],
        fileManager: FileManager = .default,
        clearCache: @escaping @Sendable () -> Void = { Memory.clearCache() }
    ) {
        self.loader = loader
        self.languageResourceRoots = languageResourceRoots
        self.fileManager = fileManager
        self.clearCache = clearCache
    }

    public func load(from directory: URL, profile: MLXRuntimeProfile) async throws {
        if model != nil {
            await unload()
        }
        guard fileManager.fileExists(atPath: directory.path) else {
            throw MLXSpeechModelSessionError.modelDirectoryMissing(directory)
        }
        if profile == .kokoro {
            try LanguageResourceStager(roots: languageResourceRoots).stage()
        }
        model = try await loader.loadModel(from: directory)
        self.profile = profile
    }

    public func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        guard let model, let profile else {
            throw MLXSpeechModelSessionError.modelNotLoaded
        }
        if profile == .kokoro {
            try LanguageResourceStager(roots: languageResourceRoots).stage()
        }
        let stream = await model.generateSamples(
            text: SpeechTextNormalizer.normalize(request.input),
            voice: request.voice,
            language: Self.languageIdentifier(for: request.languageCode, profile: profile),
            speed: request.speed,
            profile: profile
        )
        var samples: [Float] = []
        for try await chunk in stream {
            samples.append(contentsOf: chunk)
        }
        guard !samples.isEmpty else {
            throw MLXSpeechModelSessionError.noAudioGenerated
        }
        let sampleRate = await model.sampleRate
        let data = switch request.format {
        case .wav:
            WAVEncoder.encodeFloat32Mono(samples: samples, sampleRate: sampleRate)
        case .pcm:
            WAVEncoder.encodeFloat32PCM(samples: samples)
        }
        return AudioClip(data: data, format: request.format)
    }

    public func unload() async {
        await model?.release()
        model = nil
        profile = nil
        clearCache()
    }

    private static func languageIdentifier(
        for languageCode: String?,
        profile: MLXRuntimeProfile
    ) -> String? {
        guard profile == .kokoro, let languageCode else { return languageCode }
        return switch languageCode.lowercased() {
        case "a", "en", "en-us": "en-us"
        case "b", "en-gb": "en-gb"
        case "e", "es": "es"
        case "f", "fr": "fr"
        case "h", "hi": "hi"
        case "i", "it": "it"
        case "j", "ja": "ja"
        case "p", "pt", "pt-br": "pt"
        case "z", "zh", "cmn": "cmn"
        default: languageCode.lowercased()
        }
    }
}
