import Foundation

public struct ModelDescriptor: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let repository: String
    public let revision: String
    public let directoryName: String

    public init(id: String, repository: String, revision: String, directoryName: String) {
        self.id = id
        self.repository = repository
        self.revision = revision
        self.directoryName = directoryName
    }

    public static let kokoro = ModelDescriptor(
        id: "kokoro",
        repository: "mlx-community/Kokoro-82M-bf16",
        revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
        directoryName: "Kokoro-82M-bf16"
    )
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var publicHost: String
    public var publicPort: Int
    public var model: ModelDescriptor
    public var modelDirectory: URL
    public var defaultVoice: String
    public var defaultSpeed: Double
    public private(set) var playbackRate: Double
    public private(set) var paragraphPause: Double

    public init(
        publicHost: String,
        publicPort: Int,
        model: ModelDescriptor,
        modelDirectory: URL,
        defaultVoice: String,
        defaultSpeed: Double,
        playbackRate: Double = PlaybackRate.default,
        paragraphPause: Double = ParagraphPause.default
    ) {
        self.publicHost = publicHost
        self.publicPort = publicPort
        self.model = model
        self.modelDirectory = modelDirectory
        self.defaultVoice = defaultVoice
        self.defaultSpeed = defaultSpeed
        self.playbackRate = PlaybackRate.clamped(playbackRate)
        self.paragraphPause = ParagraphPause.clamped(paragraphPause)
    }

    public static func `default`(modelDirectory: URL) -> AppConfiguration {
        AppConfiguration(
            publicHost: "127.0.0.1",
            publicPort: 51_280,
            model: .kokoro,
            modelDirectory: modelDirectory.standardizedFileURL,
            defaultVoice: "af_heart",
            defaultSpeed: 1.0,
            playbackRate: PlaybackRate.default,
            paragraphPause: ParagraphPause.default
        )
    }

    private enum CodingKeys: String, CodingKey {
        case publicHost
        case publicPort
        case model
        case modelDirectory
        case defaultVoice
        case defaultSpeed
        case playbackRate
        case paragraphPause
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publicHost = try container.decode(String.self, forKey: .publicHost)
        publicPort = try container.decode(Int.self, forKey: .publicPort)
        model = try container.decode(ModelDescriptor.self, forKey: .model)
        modelDirectory = try container.decode(URL.self, forKey: .modelDirectory)
        defaultVoice = try container.decode(String.self, forKey: .defaultVoice)
        defaultSpeed = try container.decode(Double.self, forKey: .defaultSpeed)
        playbackRate = PlaybackRate.clamped(
            try container.decodeIfPresent(Double.self, forKey: .playbackRate)
                ?? PlaybackRate.default
        )
        paragraphPause = ParagraphPause.clamped(
            try container.decodeIfPresent(Double.self, forKey: .paragraphPause)
                ?? ParagraphPause.default
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(publicHost, forKey: .publicHost)
        try container.encode(publicPort, forKey: .publicPort)
        try container.encode(model, forKey: .model)
        try container.encode(modelDirectory, forKey: .modelDirectory)
        try container.encode(defaultVoice, forKey: .defaultVoice)
        try container.encode(defaultSpeed, forKey: .defaultSpeed)
        try container.encode(playbackRate, forKey: .playbackRate)
        try container.encode(paragraphPause, forKey: .paragraphPause)
    }

    public mutating func setPlaybackRate(_ rate: Double) {
        playbackRate = PlaybackRate.clamped(rate)
    }

    public mutating func setDefaultVoice(_ voice: String) {
        guard !voice.isEmpty else { return }
        defaultVoice = voice
    }

    public mutating func setParagraphPause(_ seconds: Double) {
        paragraphPause = ParagraphPause.clamped(seconds)
    }
}
