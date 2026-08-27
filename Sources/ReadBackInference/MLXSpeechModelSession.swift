import Foundation
import MLX
import ReadBackCore

public enum MLXSpeechModelSessionError: Error, Equatable, Sendable {
    case modelDirectoryMissing(URL)
    case modelNotLoaded
    case noAudioGenerated
}

public actor MLXSpeechModelSession: MLXModelSession, ModelDirectoryValidating {
    private let registry: any SpeechRuntimeRegistry
    private let fileManager: FileManager
    private var adapter: (any SpeechRuntimeAdapter)?

    public init(
        loader: any MLXSpeechModelLoading = DefaultMLXSpeechModelLoader(),
        languageResourceRoots: [URL] = [],
        fileManager: FileManager = .default,
        clearCache: @escaping @Sendable () -> Void = { Memory.clearCache() }
    ) {
        registry = DefaultSpeechRuntimeRegistry(
            loader: loader,
            languageResourceRoots: languageResourceRoots,
            fileManager: fileManager,
            clearCache: clearCache
        )
        self.fileManager = fileManager
    }

    public init(
        registry: any SpeechRuntimeRegistry,
        fileManager: FileManager = .default
    ) {
        self.registry = registry
        self.fileManager = fileManager
    }

    public func load(from directory: URL, profile: MLXRuntimeProfile) async throws {
        await unload()
        guard fileManager.fileExists(atPath: directory.path) else {
            throw MLXSpeechModelSessionError.modelDirectoryMissing(directory)
        }
        let next = try registry.makeAdapter(for: profile)
        try await next.loadModel(at: directory)
        adapter = next
    }

    public func validateModel(
        at directory: URL,
        runtimeKind: SpeechRuntimeKind
    ) async throws {
        let candidate = try registry.makeAdapter(for: runtimeKind)
        try await candidate.validateModel(at: directory)
    }

    public func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        guard let adapter else {
            throw MLXSpeechModelSessionError.modelNotLoaded
        }
        let voice = request.voice ?? ""
        let language = request.languageCode ?? ""
        let stream = try await adapter.synthesize(
            ResolvedSpeechRequest(
                input: SpeechTextNormalizer.normalize(request.input),
                selection: VoiceSelection(languageCode: language, voiceID: voice),
                voiceRuntimeValue: voice,
                languageRuntimeValue: language,
                format: request.format
            )
        )
        var samples: [Float] = []
        for try await chunk in stream {
            samples.append(contentsOf: chunk)
        }
        guard !samples.isEmpty else {
            throw MLXSpeechModelSessionError.noAudioGenerated
        }
        let sampleRate = await adapter.sampleRate
        let data = switch request.format {
        case .wav:
            WAVEncoder.encodeFloat32Mono(samples: samples, sampleRate: sampleRate)
        case .pcm:
            WAVEncoder.encodeFloat32PCM(samples: samples)
        }
        return AudioClip(data: data, format: request.format)
    }

    public func unload() async {
        await adapter?.unloadModel()
        adapter = nil
    }
}
