import Foundation
import ReadBackCore

public actor KokoroRuntimeAdapter: SpeechRuntimeAdapter {
    public let kind = SpeechRuntimeKind.kokoro

    private let loader: any MLXSpeechModelLoading
    private let languageResourceRoots: [URL]
    private let fileManager: FileManager
    private let clearCache: @Sendable () -> Void
    private var model: (any MLXSpeechGenerating)?

    public init(
        loader: any MLXSpeechModelLoading,
        languageResourceRoots: [URL],
        fileManager: FileManager,
        clearCache: @escaping @Sendable () -> Void
    ) {
        self.loader = loader
        self.languageResourceRoots = languageResourceRoots
        self.fileManager = fileManager
        self.clearCache = clearCache
    }

    public var sampleRate: Int {
        get async { await model?.sampleRate ?? 24_000 }
    }

    public func validateModel(at directory: URL) async throws {
        let config = try loadRuntimeConfiguration(at: directory, fileManager: fileManager)
        let modelType = config.modelType?.lowercased()
        guard modelType == "kokoro" || (config.istftnet != nil && config.plbert != nil) else {
            throw SpeechRuntimeAdapterError.unsupportedModelConfiguration(.kokoro)
        }
    }

    public func loadModel(at directory: URL) async throws {
        await unloadModel()
        try await validateModel(at: directory)
        try LanguageResourceStager(roots: languageResourceRoots).stage()
        model = try await loader.loadModel(from: directory)
    }

    public func synthesize(
        _ request: ResolvedSpeechRequest
    ) async throws -> AsyncThrowingStream<[Float], Error> {
        guard let model else {
            throw SpeechRuntimeAdapterError.modelNotLoaded(.kokoro)
        }
        try LanguageResourceStager(roots: languageResourceRoots).stage()
        await model.setSynthesisSpeed(1)
        return await model.generateSamples(
            text: request.input,
            voice: optionalRuntimeValue(request.voiceRuntimeValue),
            language: Self.languageIdentifier(request.languageRuntimeValue)
        )
    }

    public func unloadModel() async {
        await model?.release()
        model = nil
        clearCache()
    }

    private static func languageIdentifier(_ value: String) -> String? {
        switch value.lowercased() {
        case "a", "en", "en-us": "en-us"
        case "b", "en-gb": "en-gb"
        case "e", "es": "es"
        case "f", "fr": "fr"
        case "h", "hi": "hi"
        case "i", "it": "it"
        case "j", "ja": "ja"
        case "p", "pt", "pt-br": "pt"
        case "z", "zh", "cmn": "cmn"
        case "": nil
        default: value.lowercased()
        }
    }
}
