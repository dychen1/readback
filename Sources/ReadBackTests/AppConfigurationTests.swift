import Foundation
import ReadBackCore

func configurationTests() -> [TestCase] {
    [
        TestCase(name: "configuration uses approved defaults") {
            let config = AppConfiguration.default(
                modelDirectory: URL(fileURLWithPath: "/tmp/readback-models")
            )

            try expectEqual(config.publicHost, "127.0.0.1", "public host")
            try expectEqual(config.publicPort, 51_280, "public port")
            try expectEqual(config.model.id, "kokoro", "model ID")
            try expectEqual(
                config.model.repository,
                "mlx-community/Kokoro-82M-bf16",
                "model repository"
            )
            try expectEqual(
                config.model.revision,
                "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
                "model revision"
            )
            try expectEqual(config.model.directoryName, "Kokoro-82M-bf16", "model directory")
            try expectEqual(config.defaultVoice, "af_heart", "default voice")
            try expectEqual(config.defaultSpeed, 1.0, "default speed")
            try expectEqual(config.playbackRate, 1.0, "default playback rate")
            try expectEqual(config.paragraphPause, 0.05, "default paragraph pause")
        },
        TestCase(name: "configuration survives JSON round trip") {
            let original = AppConfiguration.default(
                modelDirectory: URL(fileURLWithPath: "/tmp/models with spaces")
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

            try expectEqual(decoded, original, "decoded configuration")
        },
        TestCase(name: "configuration defaults playback rate when loading an older file") {
            let original = AppConfiguration.default(
                modelDirectory: URL(fileURLWithPath: "/tmp/legacy-models")
            )
            let data = try JSONEncoder().encode(original)
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object.removeValue(forKey: "playbackRate")
            let legacyData = try JSONSerialization.data(withJSONObject: object)

            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacyData)

            try expectEqual(decoded.playbackRate, 1.0, "legacy playback rate")
        },
        TestCase(name: "configuration defaults paragraph pause when loading an older file") {
            let original = AppConfiguration.default(
                modelDirectory: URL(fileURLWithPath: "/tmp/legacy-models")
            )
            let data = try JSONEncoder().encode(original)
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object.removeValue(forKey: "paragraphPause")
            let legacyData = try JSONSerialization.data(withJSONObject: object)

            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacyData)

            try expectEqual(decoded.paragraphPause, 0.05, "legacy paragraph pause")
        },
        TestCase(name: "configuration store persists a changed playback rate") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("config.json")
            var configuration = AppConfiguration.default(
                modelDirectory: directory.appendingPathComponent("models")
            )
            configuration.setPlaybackRate(1.75)
            let store = AppConfigurationStore()

            try store.save(configuration, at: file)
            let loaded = try store.loadOrCreate(
                at: file,
                modelsDirectory: directory.appendingPathComponent("unused")
            )

            try expectEqual(loaded.playbackRate, 1.75, "persisted playback rate")
        },
        TestCase(name: "playback rate snaps saved values to quarter-speed steps") {
            var configuration = AppConfiguration.default(
                modelDirectory: URL(fileURLWithPath: "/tmp/models")
            )

            configuration.setPlaybackRate(1.38)
            try expectEqual(configuration.playbackRate, 1.5, "rounded playback rate")

            configuration.setPlaybackRate(2.1)
            try expectEqual(configuration.playbackRate, 2.0, "maximum playback rate")
        },
        TestCase(name: "configuration store persists voice and paragraph pause changes") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("config.json")
            var configuration = AppConfiguration.default(
                modelDirectory: directory.appendingPathComponent("models")
            )
            configuration.setDefaultVoice("bf_emma")
            configuration.setParagraphPause(0.2)
            let store = AppConfigurationStore()

            try store.save(configuration, at: file)
            let loaded = try store.loadOrCreate(
                at: file,
                modelsDirectory: directory.appendingPathComponent("unused")
            )

            try expectEqual(loaded.defaultVoice, "bf_emma", "persisted voice")
            try expectEqual(loaded.paragraphPause, 0.2, "persisted paragraph pause")
        },
        TestCase(name: "speech settings use the selected voice language and pause") {
            var configuration = AppConfiguration.default(
                modelDirectory: URL(fileURLWithPath: "/tmp/models")
            )
            configuration.setDefaultVoice("bf_emma")
            configuration.setParagraphPause(0.225)

            let settings = SpeechSettings(configuration: configuration)

            try expectEqual(settings.voice, "bf_emma", "speech settings voice")
            try expectEqual(settings.languageCode, "b", "speech settings language")
            try expectEqual(settings.paragraphPause, 0.225, "speech settings paragraph pause")
        },
        TestCase(name: "paragraph pause snaps saved values to 25 milliseconds") {
            var configuration = AppConfiguration.default(
                modelDirectory: URL(fileURLWithPath: "/tmp/models")
            )

            configuration.setParagraphPause(0.137)
            try expectEqual(configuration.paragraphPause, 0.125, "rounded paragraph pause")
        },
        TestCase(name: "paragraph pause caps saved values at 250 milliseconds") {
            var configuration = AppConfiguration.default(
                modelDirectory: URL(fileURLWithPath: "/tmp/models")
            )

            configuration.setParagraphPause(2.1)
            try expectEqual(configuration.paragraphPause, 0.25, "maximum paragraph pause")
        },
        TestCase(name: "configuration store migrates a missing model root to the current default") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("support/config.json")
            let missingRoot = directory.appendingPathComponent("old-name/models")
            let currentRoot = directory.appendingPathComponent("new-name/models")
            var configuration = AppConfiguration.default(modelDirectory: missingRoot)
            configuration.setPlaybackRate(1.5)
            let store = AppConfigurationStore()
            try store.save(configuration, at: file)

            let loaded = try store.loadOrCreate(at: file, modelsDirectory: currentRoot)
            let persisted = try JSONDecoder().decode(
                AppConfiguration.self,
                from: Data(contentsOf: file)
            )

            try expectEqual(
                loaded.modelDirectory,
                currentRoot.standardizedFileURL,
                "migrated model root"
            )
            try expectEqual(
                persisted.modelDirectory,
                currentRoot.standardizedFileURL,
                "persisted migrated model root"
            )
            try expectEqual(loaded.playbackRate, 1.5, "other settings survive migration")
        },
    ]
}
