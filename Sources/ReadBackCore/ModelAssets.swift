import Foundation

public struct ModelAssetLocations: Equatable, Sendable {
    public let bundledModelURL: URL
    public let bundledLanguagesURL: URL
    public let installedLanguagesURL: URL
    public let runtimeModelURL: URL

    public init(
        bundledModelURL: URL,
        bundledLanguagesURL: URL,
        installedLanguagesURL: URL,
        runtimeModelURL: URL
    ) {
        self.bundledModelURL = bundledModelURL.standardizedFileURL
        self.bundledLanguagesURL = bundledLanguagesURL.standardizedFileURL
        self.installedLanguagesURL = installedLanguagesURL.standardizedFileURL
        self.runtimeModelURL = runtimeModelURL.standardizedFileURL
    }

    public static func resolve(
        bundleResourcesURL: URL,
        supportDirectory: URL,
        developmentModelsURL: URL?
    ) -> ModelAssetLocations {
        let bundledModel = developmentModelsURL ?? bundleResourcesURL.appendingPathComponent(
            "Models/Kokoro-82M-bf16",
            isDirectory: true
        )
        let bundledLanguages = developmentModelsURL.map {
            $0.deletingLastPathComponent().appendingPathComponent("Languages", isDirectory: true)
        } ?? bundleResourcesURL.appendingPathComponent("Languages", isDirectory: true)
        return ModelAssetLocations(
            bundledModelURL: bundledModel,
            bundledLanguagesURL: bundledLanguages,
            installedLanguagesURL: supportDirectory.appendingPathComponent(
                "Languages",
                isDirectory: true
            ),
            runtimeModelURL: supportDirectory
                .appendingPathComponent("RuntimeModels", isDirectory: true)
                .appendingPathComponent("Kokoro-82M-bf16", isDirectory: true)
        )
    }
}
