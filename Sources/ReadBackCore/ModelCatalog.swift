import Foundation

public struct ModelID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let kokoro = ModelID(rawValue: "kokoro")
    public static let qwen3CustomVoice06B8Bit = ModelID(
        rawValue: "qwen3-custom-voice-0.6b-8bit"
    )
    public static let qwen3CustomVoice06BBF16 = ModelID(
        rawValue: "qwen3-custom-voice-0.6b-bf16"
    )
    public static let chatterboxTurbo8Bit = ModelID(rawValue: "chatterbox-turbo-8bit")
    public static let chatterboxTurboFP16 = ModelID(rawValue: "chatterbox-turbo-fp16")
    public static let breezeTTS2FourBit = ModelID(rawValue: "breeze-tts-2-4bit")
    public static let breezeTTS2EightBit = ModelID(rawValue: "breeze-tts-2-8bit")
    public static let breezeTTS2BF16 = ModelID(rawValue: "breeze-tts-2-bf16")
    public static let local = ModelID(rawValue: "local")
}

public enum ModelDistribution: String, Codable, Equatable, Sendable {
    case bundled
    case downloadable
}

public enum ModelLanguageDistribution: String, Codable, Equatable, Sendable {
    case bundled
    case includedWithModel
    case downloadable
}

public enum SpeechRuntimeKind: String, Codable, Equatable, Sendable {
    case kokoro
    case qwen3CustomVoice
    case chatterboxTurbo
    case breeze
}

public typealias MLXRuntimeProfile = SpeechRuntimeKind

public struct VoiceSelection: Codable, Equatable, Sendable {
    public let languageCode: String
    public let voiceID: String

    public init(languageCode: String, voiceID: String) {
        self.languageCode = languageCode
        self.voiceID = voiceID
    }
}

public struct ResolvedSpeechRequest: Equatable, Sendable {
    public let input: String
    public let selection: VoiceSelection
    public let voiceRuntimeValue: String
    public let languageRuntimeValue: String
    public let format: AudioFormat

    public init(
        input: String,
        selection: VoiceSelection,
        voiceRuntimeValue: String,
        languageRuntimeValue: String,
        format: AudioFormat
    ) {
        self.input = input
        self.selection = selection
        self.voiceRuntimeValue = voiceRuntimeValue
        self.languageRuntimeValue = languageRuntimeValue
        self.format = format
    }
}

public struct ModelAssetDefinition: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
    public let downloadURL: URL?

    public init(
        relativePath: String,
        byteCount: Int64,
        sha256: String,
        downloadURL: URL? = nil
    ) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.downloadURL = downloadURL
    }
}

public struct ModelLicenseNotice: Codable, Equatable, Sendable {
    public let title: String
    public let summary: String
    public let url: URL

    public init(title: String, summary: String, url: URL) {
        self.title = title
        self.summary = summary
        self.url = url
    }
}

public struct ModelVoiceDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let runtimeValue: String
    public let supportedLanguageCodes: [String]

    public init(
        id: String,
        displayName: String,
        runtimeValue: String,
        supportedLanguageCodes: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.runtimeValue = runtimeValue
        self.supportedLanguageCodes = supportedLanguageCodes
    }

    public init(id: String, displayName: String, languageCode: String) {
        self.init(
            id: id,
            displayName: displayName,
            runtimeValue: id,
            supportedLanguageCodes: [languageCode]
        )
    }

    public var languageCode: String {
        supportedLanguageCodes.first ?? ""
    }

    public func supports(languageCode: String) -> Bool {
        supportedLanguageCodes.contains(languageCode)
    }
}

public struct ModelLanguageDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String { code }

    public let code: String
    public let displayName: String
    public let runtimeValue: String
    public let distribution: ModelLanguageDistribution
    public let requiredAssets: [ModelAssetDefinition]
    public let voices: [ModelVoiceDefinition]

    public init(
        code: String,
        displayName: String,
        runtimeValue: String,
        distribution: ModelLanguageDistribution,
        requiredAssets: [ModelAssetDefinition]
    ) {
        self.code = code
        self.displayName = displayName
        self.runtimeValue = runtimeValue
        self.distribution = distribution
        self.requiredAssets = requiredAssets
        voices = []
    }

    public init(
        code: String,
        displayName: String,
        distribution: ModelLanguageDistribution,
        requiredAssets: [ModelAssetDefinition],
        voices: [ModelVoiceDefinition]
    ) {
        self.code = code
        self.displayName = displayName
        runtimeValue = voices.first?.languageCode ?? code
        self.distribution = distribution
        self.requiredAssets = requiredAssets
        self.voices = voices
    }
}

public struct CuratedModelDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: ModelID
    public let displayName: String
    public let repository: String
    public let revision: String
    public let distribution: ModelDistribution
    public let runtimeKind: SpeechRuntimeKind
    public let downloadSize: Int64
    public let requiredAssets: [ModelAssetDefinition]
    public let languages: [ModelLanguageDefinition]
    public let voices: [ModelVoiceDefinition]
    public let defaultSelection: VoiceSelection?
    public let defaultVoiceByLanguage: [String: String]
    public let defaultSynthesisSpeed: Double
    public let licenseNotice: ModelLicenseNotice?

    public init(
        id: ModelID,
        displayName: String,
        repository: String,
        revision: String,
        distribution: ModelDistribution,
        runtimeKind: SpeechRuntimeKind,
        downloadSize: Int64,
        requiredAssets: [ModelAssetDefinition],
        languages: [ModelLanguageDefinition],
        voices: [ModelVoiceDefinition],
        defaultSelection: VoiceSelection?,
        defaultVoiceByLanguage: [String: String],
        defaultSynthesisSpeed: Double,
        licenseNotice: ModelLicenseNotice? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.revision = revision
        self.distribution = distribution
        self.runtimeKind = runtimeKind
        self.downloadSize = downloadSize
        self.requiredAssets = requiredAssets
        self.languages = languages
        self.voices = voices
        self.defaultSelection = defaultSelection
        self.defaultVoiceByLanguage = defaultVoiceByLanguage
        self.defaultSynthesisSpeed = defaultSynthesisSpeed
        self.licenseNotice = licenseNotice
    }

    public init(
        id: ModelID,
        displayName: String,
        repository: String,
        revision: String,
        distribution: ModelDistribution,
        runtimeProfile: MLXRuntimeProfile,
        downloadSize: Int64,
        requiredAssets: [ModelAssetDefinition],
        languages: [ModelLanguageDefinition],
        defaultVoiceID: String?,
        defaultLanguageCode: String?,
        defaultSynthesisSpeed: Double,
        licenseNotice: ModelLicenseNotice? = nil
    ) {
        let normalizedVoices = languages.flatMap { language in
            language.voices.map { voice in
                ModelVoiceDefinition(
                    id: voice.id,
                    displayName: voice.displayName,
                    runtimeValue: voice.runtimeValue,
                    supportedLanguageCodes: [language.code]
                )
            }
        }
        let defaults = Dictionary(
            uniqueKeysWithValues: languages.compactMap { language in
                language.voices.first.map { (language.code, $0.id) }
            }
        )
        let selection: VoiceSelection? = if let defaultLanguageCode, let defaultVoiceID {
            VoiceSelection(languageCode: defaultLanguageCode, voiceID: defaultVoiceID)
        } else {
            nil
        }
        self.init(
            id: id,
            displayName: displayName,
            repository: repository,
            revision: revision,
            distribution: distribution,
            runtimeKind: runtimeProfile,
            downloadSize: downloadSize,
            requiredAssets: requiredAssets,
            languages: languages,
            voices: normalizedVoices,
            defaultSelection: selection,
            defaultVoiceByLanguage: defaults,
            defaultSynthesisSpeed: defaultSynthesisSpeed,
            licenseNotice: licenseNotice
        )
    }

    public var runtimeProfile: MLXRuntimeProfile { runtimeKind }
    public var defaultVoiceID: String? { defaultSelection?.voiceID }
    public var defaultLanguageCode: String? { defaultSelection?.languageCode }
}

public enum ModelCatalogError: Error, Equatable, Sendable {
    case duplicateModelID(ModelID)
    case unsafeModelID(ModelID)
    case unknownModel(ModelID)
    case missingRepository(ModelID)
    case missingRevision(ModelID)
    case duplicateLanguage(modelID: ModelID, code: String)
    case duplicateVoice(modelID: ModelID, voiceID: String)
    case unknownVoiceLanguage(modelID: ModelID, voiceID: String, code: String)
    case invalidDefaultLanguage(ModelID)
    case invalidDefaultVoice(ModelID)
    case invalidDefaultVoiceForLanguage(modelID: ModelID, code: String)
    case unsafeAssetPath(modelID: ModelID, path: String)
}

public struct CuratedModelCatalog: Sendable {
    public let models: [CuratedModelDefinition]
    private let modelsByID: [ModelID: CuratedModelDefinition]

    public init(models: [CuratedModelDefinition]) throws {
        var indexed: [ModelID: CuratedModelDefinition] = [:]
        for model in models {
            guard Self.isSafePathComponent(model.id.rawValue) else {
                throw ModelCatalogError.unsafeModelID(model.id)
            }
            guard indexed[model.id] == nil else {
                throw ModelCatalogError.duplicateModelID(model.id)
            }
            guard !model.repository.isEmpty else {
                throw ModelCatalogError.missingRepository(model.id)
            }
            guard !model.revision.isEmpty else {
                throw ModelCatalogError.missingRevision(model.id)
            }
            try Self.validate(model)
            indexed[model.id] = model
        }
        self.models = models
        modelsByID = indexed
    }

    public func model(id: ModelID) throws -> CuratedModelDefinition {
        guard let model = modelsByID[id] else {
            throw ModelCatalogError.unknownModel(id)
        }
        return model
    }

    public static let bundled: CuratedModelCatalog = {
        do {
            return try CuratedModelCatalog(
                models: [
                    .kokoro,
                    .qwen3CustomVoice06B8Bit,
                    .qwen3CustomVoice06BBF16,
                    .chatterboxTurbo8Bit,
                    .chatterboxTurboFP16,
                    .breezeTTS2FourBit,
                    .breezeTTS2EightBit,
                    .breezeTTS2BF16,
                ]
            )
        } catch {
            preconditionFailure("Invalid bundled model catalog: \(error)")
        }
    }()

    private static func validate(_ model: CuratedModelDefinition) throws {
        var languageCodes = Set<String>()
        var voiceIDs = Set<String>()
        for asset in model.requiredAssets {
            guard isSafeRelativePath(asset.relativePath) else {
                throw ModelCatalogError.unsafeAssetPath(modelID: model.id, path: asset.relativePath)
            }
            try validateAsset(asset, modelID: model.id)
        }
        for language in model.languages {
            guard languageCodes.insert(language.code).inserted else {
                throw ModelCatalogError.duplicateLanguage(modelID: model.id, code: language.code)
            }
            for asset in language.requiredAssets where !isSafeRelativePath(asset.relativePath) {
                throw ModelCatalogError.unsafeAssetPath(modelID: model.id, path: asset.relativePath)
            }
            for asset in language.requiredAssets {
                try validateAsset(asset, modelID: model.id)
            }
        }
        for voice in model.voices {
            guard voiceIDs.insert(voice.id).inserted else {
                throw ModelCatalogError.duplicateVoice(modelID: model.id, voiceID: voice.id)
            }
            for code in voice.supportedLanguageCodes where !languageCodes.contains(code) {
                throw ModelCatalogError.unknownVoiceLanguage(
                    modelID: model.id,
                    voiceID: voice.id,
                    code: code
                )
            }
        }
        if let language = model.defaultLanguageCode, !languageCodes.contains(language) {
            throw ModelCatalogError.invalidDefaultLanguage(model.id)
        }
        if let voice = model.defaultVoiceID, !voiceIDs.contains(voice) {
            throw ModelCatalogError.invalidDefaultVoice(model.id)
        }
        if let selection = model.defaultSelection,
           !model.voices.contains(where: {
               $0.id == selection.voiceID && $0.supports(languageCode: selection.languageCode)
           })
        {
            throw ModelCatalogError.invalidDefaultVoiceForLanguage(
                modelID: model.id,
                code: selection.languageCode
            )
        }
        for language in model.languages where !model.voices.isEmpty {
            guard let defaultVoiceID = model.defaultVoiceByLanguage[language.code],
                  model.voices.contains(where: {
                      $0.id == defaultVoiceID && $0.supports(languageCode: language.code)
                  })
            else {
                throw ModelCatalogError.invalidDefaultVoiceForLanguage(
                    modelID: model.id,
                    code: language.code
                )
            }
        }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            isSafePathComponent(String($0))
        }
    }

    private static func validateAsset(
        _ asset: ModelAssetDefinition,
        modelID: ModelID
    ) throws {
        let isSHA256 = asset.sha256.count == 64
            && asset.sha256.allSatisfy { $0.isHexDigit }
        guard asset.byteCount > 0, isSHA256 else {
            throw ModelCatalogError.unsafeAssetPath(modelID: modelID, path: asset.relativePath)
        }
    }
}

public extension CuratedModelDefinition {
    static let kokoro: CuratedModelDefinition = {
        let packs = KokoroLanguagePackCatalog.all
        let languages = packs.map { pack in
            ModelLanguageDefinition(
                code: pack.id,
                displayName: pack.name,
                runtimeValue: pack.voices.first?.languageCode ?? pack.id,
                distribution: pack.isBundled ? .bundled : .downloadable,
                requiredAssets: KokoroDownloadAssets.assets(for: pack)
            )
        }
        let voices = packs.flatMap { pack in
            pack.voices.map { voice in
                ModelVoiceDefinition(
                    id: voice.id,
                    displayName: voice.name,
                    runtimeValue: voice.id,
                    supportedLanguageCodes: [pack.id]
                )
            }
        }
        let defaults = Dictionary(
            uniqueKeysWithValues: packs.compactMap { pack in
                pack.voices.first.map { (pack.id, $0.id) }
            }
        )
        return CuratedModelDefinition(
            id: .kokoro,
            displayName: "Kokoro",
            repository: "mlx-community/Kokoro-82M-bf16",
            revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
            distribution: .bundled,
            runtimeKind: .kokoro,
            downloadSize: 0,
            requiredAssets: KokoroDownloadAssets.bundledModelAssets,
            languages: languages,
            voices: voices,
            defaultSelection: VoiceSelection(languageCode: "en", voiceID: "af_heart"),
            defaultVoiceByLanguage: defaults,
            defaultSynthesisSpeed: 1
        )
    }()

    static let qwen3CustomVoice06B8Bit = qwen3CustomVoice(
        id: .qwen3CustomVoice06B8Bit,
        displayName: "Qwen3 CustomVoice 0.6B 8-bit",
        repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
        revision: "4addb03177a4f581502fc279585b190f47728e3f",
        assets: Qwen3CustomVoiceDownloadAssets.eightBit
    )

    static let qwen3CustomVoice06BBF16 = qwen3CustomVoice(
        id: .qwen3CustomVoice06BBF16,
        displayName: "Qwen3 CustomVoice 0.6B BF16",
        repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
        revision: "6415d95f88be018ff9e46813119dc3bc12261328",
        assets: Qwen3CustomVoiceDownloadAssets.bf16
    )

    static let chatterboxTurbo8Bit = chatterboxTurbo(
        id: .chatterboxTurbo8Bit,
        displayName: "Chatterbox Turbo 8-bit",
        repository: "mlx-community/chatterbox-turbo-8bit",
        revision: "2f2e21a03863f86a1274d1060dcc188e7cde77e1",
        assets: ChatterboxTurboDownloadAssets.eightBit
    )

    static let chatterboxTurboFP16 = chatterboxTurbo(
        id: .chatterboxTurboFP16,
        displayName: "Chatterbox Turbo FP16",
        repository: "mlx-community/chatterbox-turbo-fp16",
        revision: "b2d0a13aa7cfff0a06d9acb247ae91c8f19a6d75",
        assets: ChatterboxTurboDownloadAssets.fp16
    )

    static let breezeTTS2FourBit = breezeTTS2(
        id: .breezeTTS2FourBit,
        displayName: "Breeze TTS 2 4-bit",
        repository: "mlx-community/Breeze-TTS-2-mlx-4bit",
        revision: "3a06d26b172ea4ae1da2f42d708383e9c79d5526",
        assets: BreezeTTS2DownloadAssets.fourBit
    )

    static let breezeTTS2EightBit = breezeTTS2(
        id: .breezeTTS2EightBit,
        displayName: "Breeze TTS 2 8-bit",
        repository: "mlx-community/Breeze-TTS-2-mlx-8bit",
        revision: "c6e4a2ff6ab9afba68b7853de802273ffe23fb49",
        assets: BreezeTTS2DownloadAssets.eightBit
    )

    static let breezeTTS2BF16 = breezeTTS2(
        id: .breezeTTS2BF16,
        displayName: "Breeze TTS 2 BF16",
        repository: "mlx-community/Breeze-TTS-2-mlx",
        revision: "3c8829fb7fd335818f085cd2ef49b4100c0e46c8",
        assets: BreezeTTS2DownloadAssets.bf16
    )

    private static func qwen3CustomVoice(
        id: ModelID,
        displayName: String,
        repository: String,
        revision: String,
        assets: [ModelAssetDefinition]
    ) -> CuratedModelDefinition {
        CuratedModelDefinition(
            id: id,
            displayName: displayName,
            repository: repository,
            revision: revision,
            distribution: .downloadable,
            runtimeKind: .qwen3CustomVoice,
            downloadSize: assets.reduce(Int64(0)) { $0 + $1.byteCount },
            requiredAssets: assets,
            languages: [
                ModelLanguageDefinition(
                    code: "en",
                    displayName: "English",
                    runtimeValue: "English",
                    distribution: .includedWithModel,
                    requiredAssets: []
                ),
                ModelLanguageDefinition(
                    code: "fr",
                    displayName: "French",
                    runtimeValue: "French",
                    distribution: .includedWithModel,
                    requiredAssets: []
                ),
            ],
            voices: [
                ModelVoiceDefinition(
                    id: "ryan",
                    displayName: "Ryan",
                    runtimeValue: "Ryan",
                    supportedLanguageCodes: ["en", "fr"]
                ),
                ModelVoiceDefinition(
                    id: "aiden",
                    displayName: "Aiden",
                    runtimeValue: "Aiden",
                    supportedLanguageCodes: ["en", "fr"]
                ),
                ModelVoiceDefinition(
                    id: "serena",
                    displayName: "Serena",
                    runtimeValue: "Serena",
                    supportedLanguageCodes: ["en", "fr"]
                ),
                ModelVoiceDefinition(
                    id: "vivian",
                    displayName: "Vivian",
                    runtimeValue: "Vivian",
                    supportedLanguageCodes: ["en", "fr"]
                ),
            ],
            defaultSelection: VoiceSelection(languageCode: "en", voiceID: "ryan"),
            defaultVoiceByLanguage: ["en": "ryan", "fr": "serena"],
            defaultSynthesisSpeed: 1
        )
    }

    private static func chatterboxTurbo(
        id: ModelID,
        displayName: String,
        repository: String,
        revision: String,
        assets: [ModelAssetDefinition]
    ) -> CuratedModelDefinition {
        CuratedModelDefinition(
            id: id,
            displayName: displayName,
            repository: repository,
            revision: revision,
            distribution: .downloadable,
            runtimeKind: .chatterboxTurbo,
            downloadSize: assets.reduce(Int64(0)) { $0 + $1.byteCount },
            requiredAssets: assets,
            languages: [
                ModelLanguageDefinition(
                    code: "en",
                    displayName: "English",
                    runtimeValue: "",
                    distribution: .includedWithModel,
                    requiredAssets: []
                )
            ],
            voices: [
                ModelVoiceDefinition(
                    id: "default",
                    displayName: "Chatterbox",
                    runtimeValue: "",
                    supportedLanguageCodes: ["en"]
                )
            ],
            defaultSelection: VoiceSelection(languageCode: "en", voiceID: "default"),
            defaultVoiceByLanguage: ["en": "default"],
            defaultSynthesisSpeed: 1
        )
    }

    private static func breezeTTS2(
        id: ModelID,
        displayName: String,
        repository: String,
        revision: String,
        assets: [ModelAssetDefinition]
    ) -> CuratedModelDefinition {
        let voices = [
            ModelVoiceDefinition(
                id: "clear-narrator",
                displayName: "Clear Narrator",
                runtimeValue: "A clear, natural English narrator with steady pacing",
                supportedLanguageCodes: ["en"]
            ),
            ModelVoiceDefinition(
                id: "warm-guide",
                displayName: "Warm Guide",
                runtimeValue: "A warm, friendly English voice with relaxed pacing",
                supportedLanguageCodes: ["en"]
            ),
            ModelVoiceDefinition(
                id: "calm-reader",
                displayName: "Calm Reader",
                runtimeValue: "A calm English reading voice with soft tone and even pacing",
                supportedLanguageCodes: ["en"]
            ),
            ModelVoiceDefinition(
                id: "bright-speaker",
                displayName: "Bright Speaker",
                runtimeValue: "A bright, lively English voice with clear diction",
                supportedLanguageCodes: ["en"]
            ),
            ModelVoiceDefinition(
                id: "qing-xi-pang-bai",
                displayName: "清晰旁白",
                runtimeValue: "清晰自然的普通话旁白，语速平稳",
                supportedLanguageCodes: ["zh"]
            ),
            ModelVoiceDefinition(
                id: "wen-nuan-dao-du",
                displayName: "温暖导读",
                runtimeValue: "温暖亲切的普通话声音，语速舒缓",
                supportedLanguageCodes: ["zh"]
            ),
            ModelVoiceDefinition(
                id: "chen-jing-yue-du",
                displayName: "沉静阅读",
                runtimeValue: "沉静自然的普通话阅读声音，语调柔和",
                supportedLanguageCodes: ["zh"]
            ),
            ModelVoiceDefinition(
                id: "ming-liang-bo-bao",
                displayName: "明亮播报",
                runtimeValue: "明亮有活力的普通话播报声音，吐字清楚",
                supportedLanguageCodes: ["zh"]
            ),
        ]
        return CuratedModelDefinition(
            id: id,
            displayName: displayName,
            repository: repository,
            revision: revision,
            distribution: .downloadable,
            runtimeKind: .breeze,
            downloadSize: assets.reduce(Int64(0)) { $0 + $1.byteCount },
            requiredAssets: assets,
            languages: [
                ModelLanguageDefinition(
                    code: "en",
                    displayName: "English",
                    runtimeValue: "English",
                    distribution: .includedWithModel,
                    requiredAssets: []
                ),
                ModelLanguageDefinition(
                    code: "zh",
                    displayName: "Mandarin Chinese",
                    runtimeValue: "Chinese",
                    distribution: .includedWithModel,
                    requiredAssets: []
                ),
            ],
            voices: voices,
            defaultSelection: VoiceSelection(languageCode: "en", voiceID: "clear-narrator"),
            defaultVoiceByLanguage: ["en": "clear-narrator", "zh": "qing-xi-pang-bai"],
            defaultSynthesisSpeed: 1,
            licenseNotice: ModelLicenseNotice(
                title: "Breeze TTS 2 model license",
                summary: "Breeze model weights and self-hosted output are for research and non-commercial use. By installing, you agree to review and follow the model license.",
                url: URL(string: "https://huggingface.co/BreezeBlue/Breeze-TTS-2")!
            )
        )
    }
}

private enum BreezeTTS2DownloadAssets {
    static let fourBit = common(
        configSize: 12_379,
        configHash: "f6871e70a5e937cf23f8ca6eb252ea377c9e489f87f3f7c70b76066ff5768bdf",
        indexSize: 98_863,
        indexHash: "fe6889d333789126501d6f3c5aa9fe198b00477403c7c1507d86f8cf3b32e381",
        weights: [
            asset("model.safetensors", 2_325_487_160, "e8499e75e043b16d0734897869a124198aca2fa88436eb83c855d58a39fdac0a")
        ]
    )

    static let eightBit = common(
        configSize: 12_379,
        configHash: "91cf471c3a9bd00e61046a5e08dce22967f161e75488d21b128026154111be65",
        indexSize: 98_863,
        indexHash: "113da60084ed077d67dd99706e5619f4c40056d777225923302cb957b3677026",
        weights: [
            asset("model.safetensors", 3_885_721_536, "d7a82315bcc59c3057f13bb85100743c7cd40692e38145fb255d6c1f0bf447bc")
        ]
    )

    static let bf16 = common(
        configSize: 12_176,
        configHash: "11f40bae4cb68c87638d3998c78926f7b5143c4ca7aa782e50c02209dbb072c0",
        indexSize: 73_409,
        indexHash: "b2b8ad998777f80440a51b8504d22c44575623e8bae3a76a925bccc59725ad02",
        weights: [
            asset("model-00001-of-00002.safetensors", 4_904_052_381, "06c0acb9057e13659aa297a889001dcf86f181d1355ef84c1134ba8b72313572"),
            asset("model-00002-of-00002.safetensors", 2_004_566_801, "83e7d3a903b70a0be2a1f3dc1b37c4605678536efe9e1a45b86fd70599f5bf77"),
        ]
    )

    private static func common(
        configSize: Int64,
        configHash: String,
        indexSize: Int64,
        indexHash: String,
        weights: [ModelAssetDefinition]
    ) -> [ModelAssetDefinition] {
        [
            asset("config.json", configSize, configHash),
            asset("generation_config.json", 251, "2ef3f2c0ab8d9ad241059138a795433c5410fd9954efb9625674ecd2a9529434"),
            asset("model.safetensors.index.json", indexSize, indexHash),
            asset("special_tokens_map.json", 886, "194f265bb588d142a16f27d9576104eb3dab3d7ba9961541d2d6e3d5e77e6470"),
            asset("tokenizer.json", 33_386_945, "d3ec9ac3eb2392389b9f5112e85d8b43316494addb587ba7b7a9d61eac23af96"),
            asset("tokenizer_config.json", 1_157_960, "2c084fd6725c2284e8aa6da095a8d036d48fe79665595bfcd50371821b620e44"),
            asset("audio_tokenizer/config.json", 2_336, "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
            asset("audio_tokenizer/configuration.json", 76, "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
            asset("audio_tokenizer/model.safetensors", 682_293_092, "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
            asset("audio_tokenizer/preprocessor_config.json", 234, "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        ] + weights
    }

    private static func asset(
        _ path: String,
        _ size: Int64,
        _ sha256: String
    ) -> ModelAssetDefinition {
        ModelAssetDefinition(relativePath: path, byteCount: size, sha256: sha256)
    }
}

private enum ChatterboxTurboDownloadAssets {
    static let eightBit: [ModelAssetDefinition] = [
        asset("added_tokens.json", 418, "72e4ab6acb0d9309ac3df4b526ae5fd80a2da5bc5ab7bb02d85096a374f69193"),
        asset("conds.safetensors", 164_884, "df9ad2c54848027d94cf01f9fc0ed22bc5d3165df6e6a85c903c1124b8a78a4a"),
        asset("config.json", 2_565, "cb2d9e9bcc2db2c3204220b7443b7132df7678a48238551c159715a51c68fa4f"),
        asset("merges.txt", 456_318, "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5"),
        asset("model.safetensors", 706_233_417, "cbfe447b04d11bb2d877f1305c37945ca109ffcf74a982a533e4baa40f273ba2"),
        asset("model.safetensors.index.json", 252_012, "12aa0e85bc93c0ab8aa2d9e2a4d8ddd7e9dcf9b7cfcd1a94eb35bb96ccdb1549"),
        asset("special_tokens_map.json", 470, "92ba8063bf40aa163eadebbfe0de07c2aebe44cf0d4a9e8726580b0781fd2640"),
        asset("tokenizer_config.json", 3_878, "bca16a2ac1ddbd78b8d6228f0031884cc74b6ea54b967d6f6d2ebae9ccde23e6"),
        asset("vocab.json", 999_186, "f6bd25a65e4e63ca31360e9fb11c7e4f9a391a78385d640acd814092dd6eee4f"),
    ]

    static let fp16: [ModelAssetDefinition] = [
        asset("added_tokens.json", 418, "72e4ab6acb0d9309ac3df4b526ae5fd80a2da5bc5ab7bb02d85096a374f69193"),
        asset("conds.safetensors", 164_884, "df9ad2c54848027d94cf01f9fc0ed22bc5d3165df6e6a85c903c1124b8a78a4a"),
        asset("config.json", 2_059, "aacce8af47c9c930636e47da981339fe0d30e08623d19226aa9a43bd3425b736"),
        asset("merges.txt", 456_318, "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5"),
        asset("model.safetensors", 2_985_990_960, "9f70328a3f6c5257257aea76e9b14c34d8225745d133e4c1e83aa31f3f72a80b"),
        asset("special_tokens_map.json", 470, "92ba8063bf40aa163eadebbfe0de07c2aebe44cf0d4a9e8726580b0781fd2640"),
        asset("tokenizer_config.json", 3_878, "bca16a2ac1ddbd78b8d6228f0031884cc74b6ea54b967d6f6d2ebae9ccde23e6"),
        asset("vocab.json", 999_186, "f6bd25a65e4e63ca31360e9fb11c7e4f9a391a78385d640acd814092dd6eee4f"),
    ]

    private static func asset(
        _ path: String,
        _ size: Int64,
        _ sha256: String
    ) -> ModelAssetDefinition {
        ModelAssetDefinition(relativePath: path, byteCount: size, sha256: sha256)
    }
}

private enum Qwen3CustomVoiceDownloadAssets {
    static let eightBit: [ModelAssetDefinition] = [
        asset("config.json", 6_058, "2eea3665564268139c3beb8d497fd3c2e4524e9eed5452836cdf1de96ed3cdbd"),
        asset("generation_config.json", 245, "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
        asset("merges.txt", 1_671_839, "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
        asset("model.safetensors", 962_589_155, "a11e2dff4a8f82b20c0e2f9e124b33c7a8f4a6ffcbb9607685cddd6c7e819e6a"),
        asset("model.safetensors.index.json", 74_276, "c2371ff6a5a50255d1e11dcb709da5aa039b223fc5e26170b368933aca1073bd"),
        asset("preprocessor_config.json", 127, "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
        asset("speech_tokenizer/config.json", 2_336, "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
        asset("speech_tokenizer/configuration.json", 76, "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
        asset("speech_tokenizer/model.safetensors", 682_293_092, "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
        asset("speech_tokenizer/preprocessor_config.json", 234, "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        asset("tokenizer_config.json", 7_344, "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
        asset("vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ]

    static let bf16: [ModelAssetDefinition] = [
        asset("config.json", 5_853, "69c1b78421a5e408b5e91a74a9995213546613ffe2a1d87a00c7743900ead6ee"),
        asset("generation_config.json", 245, "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
        asset("merges.txt", 1_671_839, "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
        asset("model.safetensors", 1_811_626_550, "e6eb20e645c5a28ee66bf8434edb5b67a5f151530dab63afe22787d71bcf5382"),
        asset("model.safetensors.index.json", 32_289, "1b1e10fb201a65a1b24991cf8f6800d785441ad9ca0ad83828d6bf00f6d5e8ec"),
        asset("preprocessor_config.json", 127, "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
        asset("speech_tokenizer/config.json", 2_336, "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
        asset("speech_tokenizer/configuration.json", 76, "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
        asset("speech_tokenizer/model.safetensors", 682_293_092, "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
        asset("speech_tokenizer/preprocessor_config.json", 234, "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        asset("tokenizer_config.json", 7_344, "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
        asset("vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ]

    private static func asset(
        _ path: String,
        _ size: Int64,
        _ sha256: String
    ) -> ModelAssetDefinition {
        ModelAssetDefinition(relativePath: path, byteCount: size, sha256: sha256)
    }
}

private enum KokoroDownloadAssets {
    private static let voiceHashes: [String: String] = [
        "af_bella": "112d310468cbb3cf23404d3d0b50ad3adf017b87bf38bf9edd15f4ad572df6a3",
        "af_heart": "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094",
        "af_nicole": "574656386022c81a029e9a72558191925f44c3de2dad2fa2e45751938557d062",
        "am_fenrir": "9abed964b906c4cae6f404d9849e76260689aea862bc6ca85fc3f5207ba96538",
        "am_michael": "3940147ded35deba0bb52e8132f89b719298e0520258c34584358aa5a24da2ea",
        "bf_emma": "8878a75a6661305849eeb1d6293a7177250193616e161b4c3100636434dfe69f",
        "ef_dora": "13f6dfe8a498ce97a384186af045b586db6292869acbfde123a0fa2798229351",
        "em_alex": "e3bc4bf56ab47f0d52074cd3f84cd4f1713187285fdd85a545c6e167dfa3ab77",
        "em_santa": "37c44211b77b3f29512f420bd5a2e146c7769a5ad3d904b3455cccd55055db62",
        "hf_alpha": "e93355a43e6f57e8cfde96874008c858f1fb7fd8b65dd043114d451882cad3f6",
        "hf_beta": "976ea52ba7edce5da049c41ef06a663f3807fd470d2ea5c359245dfc2fb00d66",
        "hm_omega": "227f0c710d1169686bf617fac486e8496982e96cc01617a3acd3579db75dd126",
        "hm_psi": "03efb26b99e78c8d40ade3217f9c9905f8f84bbad7f21f921e270c036b01144e",
        "if_sara": "2f3d092c8ba16f2007e8b234c9a55bdebec614a1e50143e41b39dd7f89fdb45b",
        "im_nicola": "96b62f7d25c3e7efce4f2506beeaa9f63bcc73524c7b2862738c65433fe9ba16",
        "jf_alpha": "455f78a6ebe633929cf314ce7c4a6b595ad1fb0ec7de6de7bc1d62d37e5264d2",
        "jf_gongitsune": "30d744337db7a7a91185b129dfd24ca86c19f7d46acadf2daf077ba78edaba81",
        "jf_tebukuro": "0cc28d928ce14b2ba4586b4c552edba36828a0961a37649530f80b3ad809bdec",
        "jm_kumo": "9f6b9d85ae099c409193924add0f1c478d7c9b6904ef181f2297154bfe05cc2c",
        "pf_dora": "9a8d587d60d0e041f593f7e7488943e7a6821f0136961bf0e554572e12c91c77",
        "pm_alex": "bec864eaeb05cc1a6fa12777ad31faaae1b2ed6d5eb2a6f7370fb9cdc48e3e2f",
        "pm_santa": "5009747fd93841c0865830be0f577ed50800b41b2122c469dedf51bb8311f78d",
        "zf_xiaoxiao": "cf507ad2319c50121aca4755cd3b9793bde10eea9aa9caca6cb3b5914d5f258f",
        "zf_xiaoyi": "1f2b7ce315a84870170ca83b2e4c0a072242bacbbd869f8a3b22377cc7d59e0b",
        "zm_yunxi": "78d8bb5ba4a2ea75a7f22c6148214a7434b436db85dc791a2ddf2aa7f6cc6fab",
        "zm_yunyang": "8ad45c1077ab0d973ebb85ebb84f797caf6c6b188255c1178511a6feba3a0611",
        "ff_siwis": "5c659c9b9e12be28b98a4aa0cd6b1e66f359b6381ba5680264e9072945ac32b8",
    ]

    static let bundledModelAssets: [ModelAssetDefinition] = [
        ModelAssetDefinition(
            relativePath: "config.json",
            byteCount: 2_351,
            sha256: "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"
        ),
        ModelAssetDefinition(
            relativePath: "kokoro-v1_0.safetensors",
            byteCount: 327_115_152,
            sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
        ),
    ] + ["af_heart", "af_bella", "af_nicole", "bf_emma", "am_fenrir", "am_michael", "ff_siwis"].compactMap { voiceID in
        guard let hash = voiceHashes[voiceID] else { return nil }
        return ModelAssetDefinition(
            relativePath: "voices/\(voiceID).safetensors",
            byteCount: 522_320,
            sha256: hash
        )
    }

    private static let lexicons: [String: (size: Int64, sha256: String)] = [
        "es": (22_908_669, "73b27dffa4b429fa41fb35ee132151ef70fde7869c23f6dd1d5440e66651368d"),
        "it": (919_494, "0f190d1b9e054d02cc9fb870f54342f842591329ed9e95c889f5397040aeee88"),
        "pt": (2_115_398, "ca212ceb562ddea7ceeb2d4998b90fad3d81c8c8ff6e2d1401a041cfcde8fa1f"),
    ]

    static func assets(for pack: KokoroLanguagePack) -> [ModelAssetDefinition] {
        guard !pack.isBundled else { return [] }
        var assets = pack.voices.compactMap { voice -> ModelAssetDefinition? in
            guard let hash = voiceHashes[voice.id] else { return nil }
            return ModelAssetDefinition(
                relativePath: "voices/\(voice.id).safetensors",
                byteCount: 522_320,
                sha256: hash
            )
        }
        if let filename = pack.lexiconFilename,
           let lexicon = lexicons[pack.id]
        {
            assets.append(
                ModelAssetDefinition(
                    relativePath: "resources/\(filename)",
                    byteCount: lexicon.size,
                    sha256: lexicon.sha256,
                    downloadURL: URL(
                        string: "https://huggingface.co/beshkenadze/kokoro-ipa-lexicons/resolve/\(LanguagePackRevisions.lexicon)/\(filename)"
                    )
                )
            )
        }
        return assets
    }
}
