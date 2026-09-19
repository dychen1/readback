import Foundation

public enum AudioFormat: String, Codable, Equatable, Sendable {
    case wav
    case pcm
}

public struct SpeechRequest: Codable, Equatable, Sendable {
    public let input: String
    public let voice: String?
    public let languageCode: String?
    public let speed: Double
    public let format: AudioFormat

    public init(
        input: String,
        voice: String?,
        languageCode: String?,
        speed: Double,
        format: AudioFormat
    ) {
        self.input = input
        self.voice = voice
        self.languageCode = languageCode
        self.speed = speed
        self.format = format
    }
}

public struct SpeechSettings: Equatable, Sendable {
    public let voice: String?
    public let languageCode: String?
    public let synthesisSpeed: Double
    public let paragraphPause: Double

    public init(
        voice: String?,
        languageCode: String?,
        synthesisSpeed: Double,
        paragraphPause: Double
    ) {
        self.voice = voice
        self.languageCode = languageCode
        self.synthesisSpeed = synthesisSpeed
        self.paragraphPause = ParagraphPause.clamped(paragraphPause)
    }

    public init(configuration: AppConfiguration) {
        let preference = configuration.preferences(for: configuration.activeModelID)
        self.init(
            voice: preference?.voiceID,
            languageCode: preference?.languageCode,
            synthesisSpeed: preference?.synthesisSpeed ?? 1,
            paragraphPause: configuration.paragraphPause
        )
    }
}

public actor SpeechSettingsStore {
    private var settings: SpeechSettings

    public init(_ settings: SpeechSettings) {
        self.settings = settings
    }

    public init(configuration: AppConfiguration) {
        self.init(SpeechSettings(configuration: configuration))
    }

    public func current() -> SpeechSettings {
        settings
    }

    public func update(_ settings: SpeechSettings) {
        self.settings = settings
    }
}

public struct AudioClip: Equatable, Sendable {
    public let data: Data
    public let format: AudioFormat

    public init(data: Data, format: AudioFormat) {
        self.data = data
        self.format = format
    }
}

public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ request: SpeechRequest) async throws -> AudioClip
}

public protocol SpeechModelRuntime: SpeechSynthesizing {
    func prepare() async throws
    func isPrepared() async -> Bool
}
