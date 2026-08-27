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
    ]
}
