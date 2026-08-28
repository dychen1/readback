import Foundation
import ReadBackCore

func modelCatalogTests() -> [TestCase] {
    [
        TestCase(name: "catalog rejects duplicate model IDs") {
            do {
                _ = try CuratedModelCatalog(models: [.kokoro, .kokoro])
                throw TestFailure(description: "duplicate IDs should fail")
            } catch let error as ModelCatalogError {
                try expectEqual(error, .duplicateModelID(.kokoro), "catalog error")
            }
        },
        TestCase(name: "catalog rejects an unsafe model ID") {
            let unsafe = CuratedModelDefinition(
                id: ModelID(rawValue: "../escape"),
                displayName: "Unsafe",
                repository: "example/unsafe",
                revision: "revision",
                distribution: .downloadable,
                runtimeProfile: .kokoro,
                downloadSize: 1,
                requiredAssets: [],
                languages: [],
                defaultVoiceID: nil,
                defaultLanguageCode: nil,
                defaultSynthesisSpeed: 1
            )

            do {
                _ = try CuratedModelCatalog(models: [unsafe])
                throw TestFailure(description: "unsafe ID should fail")
            } catch let error as ModelCatalogError {
                try expectEqual(error, .unsafeModelID(unsafe.id), "catalog error")
            }
        },
        TestCase(name: "Kokoro catalog bundles English and French") {
            let catalog = CuratedModelCatalog.bundled
            let kokoro = try catalog.model(id: .kokoro)

            try expectEqual(kokoro.distribution, .bundled, "distribution")
            try expectEqual(kokoro.runtimeProfile, .kokoro, "runtime profile")
            try expectEqual(kokoro.defaultVoiceID, "af_heart", "default voice")
            try expectEqual(kokoro.defaultLanguageCode, "en", "default language")
            try expectEqual(kokoro.requiredAssets.count, 9, "bundled model assets")
            try expectEqual(
                kokoro.languages.filter { $0.distribution == .bundled }.map(\.code),
                ["en", "fr"],
                "bundled languages"
            )
            try expect(
                kokoro.languages.filter { $0.distribution == .downloadable }.count == 6,
                "six optional languages"
            )
        },
        TestCase(name: "Kokoro catalog pins every optional language asset") {
            let model = try CuratedModelCatalog.bundled.model(id: .kokoro)
            let optional = model.languages.filter { $0.distribution == .downloadable }
            try expectEqual(optional.count, 6, "optional language count")
            for language in optional {
                try expect(
                    language.requiredAssets.count >= language.voices.count,
                    "\(language.displayName) must pin every voice"
                )
                for asset in language.requiredAssets {
                    try expect(asset.byteCount > 0, "asset size")
                    try expectEqual(asset.sha256.count, 64, "SHA-256 length")
                }
            }
        },
        TestCase(name: "catalog supports one voice across several languages") {
            let model = CuratedModelDefinition(
                id: ModelID(rawValue: "shared-voice"),
                displayName: "Shared Voice",
                repository: "example/shared-voice",
                revision: "revision-1",
                distribution: .downloadable,
                runtimeKind: .qwen3CustomVoice,
                downloadSize: 1,
                requiredAssets: [
                    ModelAssetDefinition(
                        relativePath: "config.json",
                        byteCount: 1,
                        sha256: String(repeating: "a", count: 64)
                    )
                ],
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
                    )
                ],
                defaultSelection: VoiceSelection(languageCode: "en", voiceID: "ryan"),
                defaultVoiceByLanguage: ["en": "ryan", "fr": "ryan"],
                defaultSynthesisSpeed: 1
            )

            let catalog = try CuratedModelCatalog(models: [model])
            let saved = try catalog.model(id: model.id)

            try expectEqual(saved.voices[0].supportedLanguageCodes, ["en", "fr"], "languages")
            try expectEqual(saved.defaultVoiceByLanguage["fr"], "ryan", "French default")
        },
        TestCase(name: "catalog rejects a voice that names an unknown language") {
            let model = CuratedModelDefinition(
                id: ModelID(rawValue: "bad-voice-language"),
                displayName: "Bad Voice Language",
                repository: "example/bad-voice-language",
                revision: "revision-1",
                distribution: .downloadable,
                runtimeKind: .qwen3CustomVoice,
                downloadSize: 1,
                requiredAssets: [
                    ModelAssetDefinition(
                        relativePath: "config.json",
                        byteCount: 1,
                        sha256: String(repeating: "a", count: 64)
                    )
                ],
                languages: [
                    ModelLanguageDefinition(
                        code: "en",
                        displayName: "English",
                        runtimeValue: "English",
                        distribution: .includedWithModel,
                        requiredAssets: []
                    )
                ],
                voices: [
                    ModelVoiceDefinition(
                        id: "ryan",
                        displayName: "Ryan",
                        runtimeValue: "Ryan",
                        supportedLanguageCodes: ["de"]
                    )
                ],
                defaultSelection: VoiceSelection(languageCode: "en", voiceID: "ryan"),
                defaultVoiceByLanguage: ["en": "ryan"],
                defaultSynthesisSpeed: 1
            )

            do {
                _ = try CuratedModelCatalog(models: [model])
                throw TestFailure(description: "unknown voice language should fail")
            } catch let error as ModelCatalogError {
                try expectEqual(
                    error,
                    .unknownVoiceLanguage(modelID: model.id, voiceID: "ryan", code: "de"),
                    "catalog error"
                )
            }
        },
        TestCase(name: "catalog pins curated Qwen CustomVoice") {
            let qwen = try CuratedModelCatalog.bundled.model(id: .qwen3CustomVoice06B8Bit)

            try expectEqual(qwen.distribution, .downloadable, "distribution")
            try expectEqual(qwen.runtimeKind, .qwen3CustomVoice, "runtime kind")
            try expectEqual(
                qwen.repository,
                "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
                "repository"
            )
            try expectEqual(
                qwen.revision,
                "4addb03177a4f581502fc279585b190f47728e3f",
                "revision"
            )
            try expectEqual(qwen.downloadSize, 1_649_421_615, "download size")
            try expectEqual(qwen.requiredAssets.count, 12, "asset count")
            try expectEqual(qwen.languages.map(\.code), ["en", "fr"], "languages")
            try expectEqual(
                qwen.voices.map(\.displayName),
                ["Ryan", "Aiden", "Serena", "Vivian"],
                "voices"
            )
            try expectEqual(
                qwen.defaultSelection,
                VoiceSelection(languageCode: "en", voiceID: "ryan"),
                "model default"
            )
            try expectEqual(qwen.defaultVoiceByLanguage["fr"], "serena", "French default")
        },
    ]
}
