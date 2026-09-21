import Foundation
import MLX
import MLXAudioTTS
import ReadBackCore

public enum KokoroSpeechSynthesizerError: Error, Equatable, Sendable {
    case modelDirectoryMissing(URL)
    case noAudioGenerated
}

public actor KokoroSpeechSynthesizer: SpeechModelRuntime {
    private let modelDirectoryURL: URL
    private let languageResourceRoots: [URL]
    private var model: SpeechGenerationModel?

    public init(modelDirectoryURL: URL, languageResourceRoots: [URL] = []) {
        self.modelDirectoryURL = modelDirectoryURL.standardizedFileURL
        self.languageResourceRoots = languageResourceRoots
    }

    public func prepare() async throws {
        guard model == nil else { return }
        SpeechMemoryPolicy.configure()
        defer { Memory.clearCache() }
        guard FileManager.default.fileExists(atPath: modelDirectoryURL.path) else {
            throw KokoroSpeechSynthesizerError.modelDirectoryMissing(modelDirectoryURL)
        }
        try LanguageResourceStager(roots: languageResourceRoots).stage()
        model = try await TTS.loadModel(modelRepo: modelDirectoryURL.path)
    }

    public func isPrepared() async -> Bool {
        model != nil
    }

    public func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        defer { Memory.clearCache() }
        try Task.checkCancellation()
        try await prepare()
        try LanguageResourceStager(roots: languageResourceRoots).stage()
        guard let model else {
            throw KokoroSpeechSynthesizerError.noAudioGenerated
        }

        if let kokoro = model as? KokoroModel {
            kokoro.speed = Float(request.speed)
        }

        let stream = model.generateSamplesStream(
            text: SpeechTextNormalizer.normalize(request.input),
            voice: request.voice,
            refAudio: nil,
            refText: nil,
            language: request.languageCode.map(Self.languageIdentifier(for:))
        )
        var samples: [Float] = []
        for try await chunk in stream {
            try Task.checkCancellation()
            samples.append(contentsOf: chunk)
        }
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw KokoroSpeechSynthesizerError.noAudioGenerated
        }

        let data = switch request.format {
        case .wav:
            WAVEncoder.encodeFloat32Mono(samples: samples, sampleRate: model.sampleRate)
        case .pcm:
            WAVEncoder.encodeFloat32PCM(samples: samples)
        }
        return AudioClip(data: data, format: request.format)
    }

    private static func languageIdentifier(for languageCode: String) -> String {
        switch languageCode.lowercased() {
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
