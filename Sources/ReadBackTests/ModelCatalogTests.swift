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
        TestCase(name: "catalog exposes both curated Qwen CustomVoice installs") {
            let catalog = CuratedModelCatalog.bundled
            let eightBit = try catalog.model(id: .qwen3CustomVoice06B8Bit)
            let bf16 = try catalog.model(id: .qwen3CustomVoice06BBF16)

            try expectEqual(eightBit.displayName, "Qwen3 CustomVoice 0.6B 8-bit", "8-bit name")
            try expectEqual(
                eightBit.repository,
                "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
                "8-bit repository"
            )
            try expectEqual(
                eightBit.revision,
                "4addb03177a4f581502fc279585b190f47728e3f",
                "8-bit revision"
            )
            try expectEqual(eightBit.downloadSize, 1_649_421_615, "8-bit download size")
            try expectEqual(eightBit.requiredAssets.count, 12, "8-bit asset count")

            try expectEqual(bf16.displayName, "Qwen3 CustomVoice 0.6B BF16", "BF16 name")
            try expectEqual(
                bf16.repository,
                "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
                "BF16 repository"
            )
            try expectEqual(
                bf16.revision,
                "6415d95f88be018ff9e46813119dc3bc12261328",
                "BF16 revision"
            )
            try expectEqual(bf16.downloadSize, 2_498_416_818, "BF16 download size")
            try expectEqual(bf16.requiredAssets.count, 12, "BF16 asset count")

            for model in [eightBit, bf16] {
                try expectEqual(model.distribution, .downloadable, "distribution")
                try expectEqual(model.runtimeKind, .qwen3CustomVoice, "runtime kind")
                try expectEqual(model.languages.map(\.code), ["en", "fr"], "languages")
                try expectEqual(
                    model.voices.map(\.displayName),
                    ["Ryan", "Aiden", "Serena", "Vivian"],
                    "voices"
                )
                try expectEqual(
                    model.defaultSelection,
                    VoiceSelection(languageCode: "en", voiceID: "ryan"),
                    "model default"
                )
                try expectEqual(
                    model.defaultVoiceByLanguage["fr"],
                    "serena",
                    "French default"
                )
            }
        },
        TestCase(name: "catalog exposes both curated Chatterbox Turbo installs") {
            let catalog = CuratedModelCatalog.bundled
            let eightBit = try catalog.model(id: .chatterboxTurbo8Bit)
            let fp16 = try catalog.model(id: .chatterboxTurboFP16)

            try expectEqual(eightBit.displayName, "Chatterbox Turbo 8-bit", "8-bit name")
            try expectEqual(
                eightBit.repository,
                "mlx-community/chatterbox-turbo-8bit",
                "8-bit repository"
            )
            try expectEqual(
                eightBit.revision,
                "2f2e21a03863f86a1274d1060dcc188e7cde77e1",
                "8-bit revision"
            )
            try expectEqual(eightBit.downloadSize, 708_113_148, "8-bit download size")
            try expectEqual(eightBit.requiredAssets.count, 9, "8-bit asset count")

            try expectEqual(fp16.displayName, "Chatterbox Turbo FP16", "FP16 name")
            try expectEqual(
                fp16.repository,
                "mlx-community/chatterbox-turbo-fp16",
                "FP16 repository"
            )
            try expectEqual(
                fp16.revision,
                "b2d0a13aa7cfff0a06d9acb247ae91c8f19a6d75",
                "FP16 revision"
            )
            try expectEqual(fp16.downloadSize, 2_987_618_173, "FP16 download size")
            try expectEqual(fp16.requiredAssets.count, 8, "FP16 asset count")

            for model in [eightBit, fp16] {
                try expectEqual(model.distribution, .downloadable, "distribution")
                try expectEqual(model.runtimeKind, .chatterboxTurbo, "runtime kind")
                try expectEqual(model.languages.map(\.code), ["en"], "languages")
                try expectEqual(model.voices.map(\.displayName), ["Chatterbox"], "voices")
                try expectEqual(
                    model.defaultSelection,
                    VoiceSelection(languageCode: "en", voiceID: "default"),
                    "default selection"
                )
            }
        },
    ]
}
