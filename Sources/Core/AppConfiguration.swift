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
        id: ModelID.kokoro.rawValue,
        repository: CuratedModelDefinition.kokoro.repository,
        revision: CuratedModelDefinition.kokoro.revision,
        directoryName: "Kokoro-82M-bf16"
    )
}

public struct ModelPreference: Codable, Equatable, Sendable {
    public let modelID: ModelID
    public var voiceID: String?
    public var languageCode: String?
    public var synthesisSpeed: Double

    public init(
        modelID: ModelID,
        voiceID: String?,
        languageCode: String?,
        synthesisSpeed: Double
    ) {
        self.modelID = modelID
        self.voiceID = voiceID
        self.languageCode = languageCode
        self.synthesisSpeed = synthesisSpeed
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var publicHost: String
    public var publicPort: Int
    public var activeModelID: ModelID
    public var modelPreferences: [ModelPreference]
    public private(set) var playbackRate: Double
    public private(set) var paragraphPause: Double

    // Temporary process-local compatibility path. Version 2 does not encode it.
    public var modelDirectory: URL

    public init(
        schemaVersion: Int = AppConfiguration.currentSchemaVersion,
        publicHost: String,
        publicPort: Int,
        activeModelID: ModelID,
        modelPreferences: [ModelPreference],
        playbackRate: Double = PlaybackRate.default,
        paragraphPause: Double = ParagraphPause.default,
        modelDirectory: URL = URL(fileURLWithPath: "/")
    ) {
        self.schemaVersion = schemaVersion
        self.publicHost = publicHost
        self.publicPort = publicPort
        self.activeModelID = activeModelID
        self.modelPreferences = Self.uniquePreferences(modelPreferences)
        self.playbackRate = PlaybackRate.clamped(playbackRate)
        self.paragraphPause = ParagraphPause.clamped(paragraphPause)
        self.modelDirectory = modelDirectory.standardizedFileURL
    }

    public static func `default`(modelDirectory: URL) -> AppConfiguration {
        AppConfiguration(
            publicHost: "127.0.0.1",
            publicPort: 51_280,
            activeModelID: .kokoro,
            modelPreferences: [
                ModelPreference(
                    modelID: .kokoro,
                    voiceID: CuratedModelDefinition.kokoro.defaultVoiceID,
                    languageCode: CuratedModelDefinition.kokoro.defaultLanguageCode,
                    synthesisSpeed: CuratedModelDefinition.kokoro.defaultSynthesisSpeed
                )
            ],
            playbackRate: PlaybackRate.default,
            paragraphPause: ParagraphPause.default,
            modelDirectory: modelDirectory
        )
    }

    public func preferences(for modelID: ModelID) -> ModelPreference? {
        modelPreferences.first { $0.modelID == modelID }
    }

    public mutating func setPreferences(_ preference: ModelPreference) {
        modelPreferences.removeAll { $0.modelID == preference.modelID }
        modelPreferences.append(preference)
    }

    public mutating func setPlaybackRate(_ rate: Double) {
        playbackRate = PlaybackRate.clamped(rate)
    }

    public mutating func setDefaultVoice(_ voice: String) {
        guard !voice.isEmpty else { return }
        var preference = preferences(for: activeModelID) ?? ModelPreference(
            modelID: activeModelID,
            voiceID: nil,
            languageCode: nil,
            synthesisSpeed: 1
        )
        preference.voiceID = voice
        setPreferences(preference)
    }

    public mutating func setParagraphPause(_ seconds: Double) {
        paragraphPause = ParagraphPause.clamped(seconds)
    }

    public var model: ModelDescriptor { .kokoro }
    public var defaultVoice: String { preferences(for: activeModelID)?.voiceID ?? "af_heart" }
    public var defaultSpeed: Double { preferences(for: activeModelID)?.synthesisSpeed ?? 1 }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case publicHost
        case publicPort
        case activeModelID
        case modelPreferences
        case playbackRate
        case paragraphPause
        case model
        case modelDirectory
        case defaultVoice
        case defaultSpeed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        publicHost = try container.decode(String.self, forKey: .publicHost)
        publicPort = try container.decode(Int.self, forKey: .publicPort)
        playbackRate = PlaybackRate.clamped(
            try container.decodeIfPresent(Double.self, forKey: .playbackRate)
                ?? PlaybackRate.default
        )
        paragraphPause = ParagraphPause.clamped(
            try container.decodeIfPresent(Double.self, forKey: .paragraphPause)
                ?? ParagraphPause.default
        )
        modelDirectory = (
            try container.decodeIfPresent(URL.self, forKey: .modelDirectory)
                ?? URL(fileURLWithPath: "/")
        ).standardizedFileURL

        if version >= Self.currentSchemaVersion {
            schemaVersion = Self.currentSchemaVersion
            activeModelID = try container.decode(ModelID.self, forKey: .activeModelID)
            modelPreferences = Self.uniquePreferences(
                try container.decode([ModelPreference].self, forKey: .modelPreferences)
            )
        } else {
            schemaVersion = Self.currentSchemaVersion
            let descriptor = try container.decodeIfPresent(ModelDescriptor.self, forKey: .model)
            activeModelID = ModelID(rawValue: descriptor?.id ?? ModelID.kokoro.rawValue)
            let voice = try container.decodeIfPresent(String.self, forKey: .defaultVoice)
                ?? "af_heart"
            let speed = try container.decodeIfPresent(Double.self, forKey: .defaultSpeed) ?? 1
            modelPreferences = [
                ModelPreference(
                    modelID: activeModelID,
                    voiceID: voice,
                    languageCode: Self.languageID(forVoiceID: voice),
                    synthesisSpeed: speed
                )
            ]
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(publicHost, forKey: .publicHost)
        try container.encode(publicPort, forKey: .publicPort)
        try container.encode(activeModelID, forKey: .activeModelID)
        try container.encode(modelPreferences, forKey: .modelPreferences)
        try container.encode(playbackRate, forKey: .playbackRate)
        try container.encode(paragraphPause, forKey: .paragraphPause)
    }

    private static func uniquePreferences(_ preferences: [ModelPreference]) -> [ModelPreference] {
        var seen = Set<ModelID>()
        return preferences.reversed().filter { seen.insert($0.modelID).inserted }.reversed()
    }

    private static func languageID(forVoiceID id: String) -> String {
        let code = KokoroVoiceCatalog.languageCode(forVoiceID: id)
        return switch code {
        case "a", "b": "en"
        case "j": "ja"
        case "z": "zh"
        case "e": "es"
        case "f": "fr"
        case "h": "hi"
        case "i": "it"
        case "p": "pt"
        default: CuratedModelDefinition.kokoro.defaultLanguageCode ?? "en"
        }
    }
}
