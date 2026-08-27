import Foundation
import ReadBackCore

func modelAssetsTests() -> [TestCase] {
    [
        TestCase(name: "model assets resolve bundled and installed roots") {
            let resources = URL(fileURLWithPath: "/Applications/ReadBack.app/Contents/Resources")
            let support = URL(
                fileURLWithPath: "/Users/test/Library/Application Support/ReadBack",
                isDirectory: true
            )

            let locations = ModelAssetLocations.resolve(
                bundleResourcesURL: resources,
                supportDirectory: support,
                developmentModelsURL: nil
            )

            try expectEqual(
                locations.bundledModelURL,
                resources.appendingPathComponent("Models/Kokoro-82M-bf16", isDirectory: true),
                "bundled model URL"
            )
            try expectEqual(
                locations.bundledLanguagesURL,
                resources.appendingPathComponent("Languages", isDirectory: true),
                "bundled languages URL"
            )
            try expectEqual(
                locations.installedLanguagesURL,
                support.appendingPathComponent("Languages", isDirectory: true),
                "installed languages URL"
            )
        },
        TestCase(name: "development model overrides only the bundled model") {
            let resources = URL(fileURLWithPath: "/tmp/ReadBack.app/Contents/Resources")
            let support = URL(fileURLWithPath: "/tmp/support", isDirectory: true)
            let developmentModel = URL(
                fileURLWithPath: "/tmp/repo/models/Kokoro-82M-bf16",
                isDirectory: true
            )

            let locations = ModelAssetLocations.resolve(
                bundleResourcesURL: resources,
                supportDirectory: support,
                developmentModelsURL: developmentModel
            )

            try expectEqual(
                locations.bundledModelURL,
                developmentModel,
                "development model URL"
            )
            try expectEqual(
                locations.bundledLanguagesURL,
                developmentModel
                    .deletingLastPathComponent()
                    .appendingPathComponent("Languages", isDirectory: true),
                "development bundled languages URL"
            )
        },
    ]
}
