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
            try expectEqual(config.backendHost, "127.0.0.1", "backend host")
            try expectEqual(config.backendPort, 51_281, "backend port")
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
    ]
}
