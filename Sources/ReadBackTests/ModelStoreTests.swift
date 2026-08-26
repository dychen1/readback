import Foundation
import ReadBackCore

func modelStoreTests() -> [TestCase] {
    [
        TestCase(name: "model store discovers a complete pinned model") {
            let fixture = try ModelStoreFixture()
            defer { fixture.remove() }
            try fixture.installPinnedModel()
            let store = ModelStore(rootURL: fixture.modelsURL, supportedModels: [.kokoro])

            let models = try await store.installedModels()

            try expectEqual(
                models,
                [InstalledModel(descriptor: .kokoro, directoryURL: fixture.modelURL)],
                "installed models"
            )
        },
        TestCase(name: "model store ignores a partial download") {
            let fixture = try ModelStoreFixture()
            defer { fixture.remove() }
            try FileManager.default.createDirectory(
                at: fixture.modelURL,
                withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: fixture.modelURL.appendingPathComponent("config.json"))
            let store = ModelStore(rootURL: fixture.modelsURL, supportedModels: [.kokoro])

            let models = try await store.installedModels()
            try expect(models.isEmpty, "partial model must not be installed")
        },
        TestCase(name: "model store rejects unknown and traversal-shaped IDs") {
            let fixture = try ModelStoreFixture()
            defer { fixture.remove() }
            let store = ModelStore(rootURL: fixture.modelsURL, supportedModels: [.kokoro])

            do {
                _ = try await store.directoryURL(for: "../outside")
                throw TestFailure(description: "unknown model should fail")
            } catch let error as ModelStoreError {
                try expectEqual(error, .unknownModel("../outside"), "unknown model error")
            }

            do {
                try await store.delete(modelID: "Kokoro-82M-bf16/../../outside")
                throw TestFailure(description: "traversal-shaped model should fail")
            } catch let error as ModelStoreError {
                try expectEqual(
                    error,
                    .unknownModel("Kokoro-82M-bf16/../../outside"),
                    "traversal error"
                )
            }
        },
        TestCase(name: "model delete removes only the exact model directory") {
            let fixture = try ModelStoreFixture()
            defer { fixture.remove() }
            try fixture.installPinnedModel()
            let sibling = fixture.rootURL.appendingPathComponent("do-not-delete.txt")
            try Data("safe".utf8).write(to: sibling)
            let store = ModelStore(rootURL: fixture.modelsURL, supportedModels: [.kokoro])

            try await store.delete(modelID: "kokoro")

            try expect(
                !FileManager.default.fileExists(atPath: fixture.modelURL.path),
                "model directory should be deleted"
            )
            try expect(
                FileManager.default.fileExists(atPath: sibling.path),
                "sibling must remain"
            )
        },
    ]
}

private final class ModelStoreFixture {
    let rootURL: URL
    let modelsURL: URL
    let modelURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        modelsURL = rootURL.appendingPathComponent("models", isDirectory: true)
        modelURL = modelsURL.appendingPathComponent("Kokoro-82M-bf16", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
    }

    func installPinnedModel() throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelURL.appendingPathComponent("config.json"))
        try Data([0x01]).write(to: modelURL.appendingPathComponent("kokoro-v1_0.safetensors"))
        let voices = modelURL.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        try Data([0x01]).write(to: voices.appendingPathComponent("af_heart.safetensors"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
