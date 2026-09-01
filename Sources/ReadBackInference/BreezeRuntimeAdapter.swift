import Foundation
import ReadBackCore

public actor BreezeRuntimeAdapter: SpeechRuntimeAdapter {
    public let kind = SpeechRuntimeKind.breeze

    private let loader: any MLXSpeechModelLoading
    private let fileManager: FileManager
    private let clearCache: @Sendable () -> Void
    private var model: (any MLXSpeechGenerating)?

    public init(
        loader: any MLXSpeechModelLoading,
        fileManager: FileManager,
        clearCache: @escaping @Sendable () -> Void
    ) {
        self.loader = loader
        self.fileManager = fileManager
        self.clearCache = clearCache
    }

    public var sampleRate: Int {
        get async { await model?.sampleRate ?? 24_000 }
    }

    public func validateModel(at directory: URL) async throws {
        let config = try loadRuntimeConfiguration(at: directory, fileManager: fileManager)
        let modelType = config.modelType?.lowercased()
        guard modelType == "breeze" || modelType == "breeze_tts" else {
            throw SpeechRuntimeAdapterError.unsupportedModelConfiguration(.breeze)
        }
    }

    public func loadModel(at directory: URL) async throws {
        await unloadModel()
        try await validateModel(at: directory)
        model = try await loader.loadModel(from: directory)
    }

    public func synthesize(
        _ request: ResolvedSpeechRequest
    ) async throws -> AsyncThrowingStream<[Float], Error> {
        guard let model else {
            throw SpeechRuntimeAdapterError.modelNotLoaded(.breeze)
        }
        return await model.generateSamples(
            text: request.input,
            voice: optionalRuntimeValue(request.voiceRuntimeValue),
            language: optionalRuntimeValue(request.languageRuntimeValue)
        )
    }

    public func unloadModel() async {
        await model?.release()
        model = nil
        clearCache()
    }
}
