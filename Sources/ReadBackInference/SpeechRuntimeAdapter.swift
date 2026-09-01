import Foundation
import MLXAudioTTS
import ReadBackCore

public enum SpeechRuntimeAdapterError: Error, Equatable, Sendable {
    case unsupportedRuntimeKind(SpeechRuntimeKind)
    case modelNotLoaded(SpeechRuntimeKind)
    case missingConfiguration
    case invalidConfiguration
    case unsupportedModelConfiguration(SpeechRuntimeKind)
}

public protocol MLXSpeechGenerating: Sendable {
    var sampleRate: Int { get async }
    func setSynthesisSpeed(_ speed: Double) async
    func generateSamples(
        text: String,
        voice: String?,
        language: String?
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

    public func setSynthesisSpeed(_ speed: Double) async {
        if let kokoro = model as? KokoroModel {
            kokoro.speed = Float(speed)
        }
    }

    public func generateSamples(
        text: String,
        voice: String?,
        language: String?
    ) async -> AsyncThrowingStream<[Float], Error> {
        guard let model else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: SpeechRuntimeAdapterError.modelNotLoaded(.kokoro)
                )
            }
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

public protocol SpeechRuntimeAdapter: Actor {
    var kind: SpeechRuntimeKind { get }
    var sampleRate: Int { get async }
    func validateModel(at directory: URL) async throws
    func loadModel(at directory: URL) async throws
    func synthesize(
        _ request: ResolvedSpeechRequest
    ) async throws -> AsyncThrowingStream<[Float], Error>
    func unloadModel() async
}

public protocol SpeechRuntimeRegistry: Sendable {
    func makeAdapter(for kind: SpeechRuntimeKind) throws -> any SpeechRuntimeAdapter
}

public struct DefaultSpeechRuntimeRegistry: SpeechRuntimeRegistry, @unchecked Sendable {
    private let loader: any MLXSpeechModelLoading
    private let languageResourceRoots: [URL]
    private let fileManager: FileManager
    private let clearCache: @Sendable () -> Void

    public init(
        loader: any MLXSpeechModelLoading = DefaultMLXSpeechModelLoader(),
        languageResourceRoots: [URL] = [],
        fileManager: FileManager = .default,
        clearCache: @escaping @Sendable () -> Void
    ) {
        self.loader = loader
        self.languageResourceRoots = languageResourceRoots
        self.fileManager = fileManager
        self.clearCache = clearCache
    }

    public func makeAdapter(for kind: SpeechRuntimeKind) throws -> any SpeechRuntimeAdapter {
        switch kind {
        case .kokoro:
            KokoroRuntimeAdapter(
                loader: loader,
                languageResourceRoots: languageResourceRoots,
                fileManager: fileManager,
                clearCache: clearCache
            )
        case .qwen3CustomVoice:
            Qwen3CustomVoiceRuntimeAdapter(
                loader: loader,
                fileManager: fileManager,
                clearCache: clearCache
            )
        case .chatterboxTurbo:
            ChatterboxTurboRuntimeAdapter(
                loader: loader,
                fileManager: fileManager,
                clearCache: clearCache
            )
        case .breeze:
            BreezeRuntimeAdapter(
                loader: loader,
                fileManager: fileManager,
                clearCache: clearCache
            )
        }
    }
}

struct RuntimeModelConfiguration: Decodable {
    let modelType: String?
    let ttsModelType: String?
    let istftnet: [String: JSONValue]?
    let plbert: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case ttsModelType = "tts_model_type"
        case istftnet
        case plbert
    }
}

enum JSONValue: Decodable {
    case value

    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
        self = .value
    }
}

func loadRuntimeConfiguration(
    at directory: URL,
    fileManager: FileManager
) throws -> RuntimeModelConfiguration {
    let configURL = directory.appendingPathComponent("config.json")
    guard fileManager.fileExists(atPath: configURL.path) else {
        throw SpeechRuntimeAdapterError.missingConfiguration
    }
    do {
        return try JSONDecoder().decode(
            RuntimeModelConfiguration.self,
            from: Data(contentsOf: configURL)
        )
    } catch {
        throw SpeechRuntimeAdapterError.invalidConfiguration
    }
}

func optionalRuntimeValue(_ value: String) -> String? {
    value.isEmpty ? nil : value
}
