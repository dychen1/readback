import Foundation

public struct ModelID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let kokoro = ModelID(rawValue: "kokoro")
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

public enum MLXRuntimeProfile: String, Codable, Equatable, Sendable {
    case kokoro
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

public struct ModelVoiceDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let languageCode: String

    public init(id: String, displayName: String, languageCode: String) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
    }
}

public struct ModelLanguageDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String { code }

    public let code: String
    public let displayName: String
    public let distribution: ModelLanguageDistribution
    public let requiredAssets: [ModelAssetDefinition]
    public let voices: [ModelVoiceDefinition]

    public init(
        code: String,
        displayName: String,
        distribution: ModelLanguageDistribution,
        requiredAssets: [ModelAssetDefinition],
        voices: [ModelVoiceDefinition]
    ) {
        self.code = code
        self.displayName = displayName
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
    public let runtimeProfile: MLXRuntimeProfile
    public let downloadSize: Int64
    public let requiredAssets: [ModelAssetDefinition]
    public let languages: [ModelLanguageDefinition]
    public let defaultVoiceID: String?
    public let defaultLanguageCode: String?
    public let defaultSynthesisSpeed: Double

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
        defaultSynthesisSpeed: Double
    ) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.revision = revision
        self.distribution = distribution
        self.runtimeProfile = runtimeProfile
        self.downloadSize = downloadSize
        self.requiredAssets = requiredAssets
        self.languages = languages
        self.defaultVoiceID = defaultVoiceID
        self.defaultLanguageCode = defaultLanguageCode
        self.defaultSynthesisSpeed = defaultSynthesisSpeed
    }
}

public enum ModelCatalogError: Error, Equatable, Sendable {
    case duplicateModelID(ModelID)
    case unsafeModelID(ModelID)
    case unknownModel(ModelID)
    case missingRepository(ModelID)
    case missingRevision(ModelID)
    case duplicateLanguage(modelID: ModelID, code: String)
    case duplicateVoice(modelID: ModelID, voiceID: String)
    case invalidDefaultLanguage(ModelID)
    case invalidDefaultVoice(ModelID)
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
            return try CuratedModelCatalog(models: [.kokoro])
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
            for voice in language.voices {
                guard voiceIDs.insert(voice.id).inserted else {
                    throw ModelCatalogError.duplicateVoice(modelID: model.id, voiceID: voice.id)
                }
            }
        }
        if let language = model.defaultLanguageCode, !languageCodes.contains(language) {
            throw ModelCatalogError.invalidDefaultLanguage(model.id)
        }
        if let voice = model.defaultVoiceID, !voiceIDs.contains(voice) {
            throw ModelCatalogError.invalidDefaultVoice(model.id)
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
    static let kokoro = CuratedModelDefinition(
        id: .kokoro,
        displayName: "Kokoro",
        repository: "mlx-community/Kokoro-82M-bf16",
        revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
        distribution: .bundled,
        runtimeProfile: .kokoro,
        downloadSize: 0,
        requiredAssets: KokoroDownloadAssets.bundledModelAssets,
        languages: KokoroLanguagePackCatalog.all.map { pack in
            ModelLanguageDefinition(
                code: pack.id,
                displayName: pack.name,
                distribution: pack.isBundled ? .bundled : .downloadable,
                requiredAssets: KokoroDownloadAssets.assets(for: pack),
                voices: pack.voices.map { voice in
                    ModelVoiceDefinition(
                        id: voice.id,
                        displayName: voice.name,
                        languageCode: voice.languageCode
                    )
                }
            )
        },
        defaultVoiceID: "af_heart",
        defaultLanguageCode: "en",
        defaultSynthesisSpeed: 1
    )
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
                        string: "https://huggingface.co/beshkenadze/kokoro-ipa-lexicons/resolve/\(LanguagePackStore.lexiconRevision)/\(filename)"
                    )
                )
            )
        }
        return assets
    }
}
