import Foundation
import ReadBackCore

func runtimePathsTests() -> [TestCase] {
    [
        TestCase(name: "development app bundle finds the repository model directory") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dist/ReadBack.app"),
                withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent("Package.swift"))

            let paths = RuntimePaths.resolve(
                environment: [:],
                currentDirectory: URL(fileURLWithPath: "/"),
                bundleURL: root.appendingPathComponent("dist/ReadBack.app")
            )

            try expectEqual(
                paths.modelsDirectory,
                root.appendingPathComponent("models", isDirectory: true).standardizedFileURL,
                "development model directory"
            )
        },
        TestCase(name: "installed app uses Application Support for models") {
            let paths = RuntimePaths.resolve(
                environment: [:],
                currentDirectory: URL(fileURLWithPath: "/"),
                bundleURL: URL(fileURLWithPath: "/Applications/ReadBack.app")
            )
            try expect(
                paths.modelsDirectory.path.hasSuffix(
                    "/Library/Application Support/ReadBack/models"
                ),
                "installed model directory"
            )
        },
        TestCase(name: "configuration migrates from the old app support directory") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let oldSupport = root.appendingPathComponent("ReadBackVoice", isDirectory: true)
            let newSupport = root.appendingPathComponent("ReadBack", isDirectory: true)
            let models = root.appendingPathComponent("models", isDirectory: true)
            let oldConfigurationFile = oldSupport.appendingPathComponent("config.json")
            let newConfigurationFile = newSupport.appendingPathComponent("config.json")
            var saved = AppConfiguration.default(modelDirectory: models)
            saved.setPlaybackRate(1.75)
            try AppConfigurationStore().save(saved, at: oldConfigurationFile)

            let loaded = try AppConfigurationStore().loadOrCreate(
                at: newConfigurationFile,
                modelsDirectory: models
            )

            try expectEqual(loaded.playbackRate, 1.75, "migrated playback rate")
            try expect(
                FileManager.default.fileExists(atPath: newConfigurationFile.path),
                "new configuration file exists"
            )
        },
    ]
}
