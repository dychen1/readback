import Foundation
import ReadBackCore

private actor ManagerTestLibrary: ModelLibraryProtocol {
    let locations: [ModelID: ModelLocation]
    let profiles: [ModelID: MLXRuntimeProfile]

    init(
        locations: [ModelID: ModelLocation],
        profiles: [ModelID: MLXRuntimeProfile]? = nil
    ) {
        self.locations = locations
        self.profiles = profiles
            ?? Dictionary(uniqueKeysWithValues: locations.keys.map { ($0, .kokoro) })
    }

    func storageState(for id: ModelID) async -> ModelStorageState {
        guard let location = locations[id] else { return .notInstalled }
        return switch location {
        case .bundled: .bundled
        case .managed: .installed
        case .local: .localAvailable
        }
    }

    func location(for id: ModelID) async throws -> ModelLocation {
        guard let location = locations[id] else { throw ModelLibraryError.notInstalled(id) }
        return location
    }

    func runtimeProfile(for id: ModelID) async throws -> MLXRuntimeProfile {
        guard let profile = profiles[id] else { throw ModelLibraryError.notInstalled(id) }
        return profile
    }

    func isLanguageInstalled(_ code: String, for id: ModelID) async -> Bool { true }
    func install(_ id: ModelID) async throws {}
    func installLanguage(_ code: String, for id: ModelID) async throws {}
    func registerLocalModel(at directory: URL) async throws {}
    func remove(_ id: ModelID) async throws {}
}

private actor ManagerTestSession: MLXModelSession {
    private let failingDirectoryNames: Set<String>
    private var loadedDirectory: URL?
    private var synthesisStarted = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var requests: [SpeechRequest] = []

    init(failingDirectoryNames: Set<String> = []) {
        self.failingDirectoryNames = failingDirectoryNames
    }

    func load(from directory: URL, profile: MLXRuntimeProfile) async throws {
        if failingDirectoryNames.contains(directory.lastPathComponent) {
            throw TestFailure(description: "fixture load failed")
        }
        loadedDirectory = directory
    }

    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        requests.append(request)
        if request.input == "hold" {
            synthesisStarted = true
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        return AudioClip(data: Data([0x01]), format: request.format)
    }

    func unload() async { loadedDirectory = nil }

    func waitUntilSynthesisStarts() async {
        while !synthesisStarted {
            await Task.yield()
        }
    }

    func unblock() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func loadedName() -> String? { loadedDirectory?.lastPathComponent }
    func lastRequest() -> SpeechRequest? { requests.last }
}

func modelManagerTests() -> [TestCase] {
    [
        TestCase(name: "model manager warms the saved active model") {
            let fixture = try ModelManagerFixture()
            defer { fixture.remove() }

            await fixture.manager.warmConfiguredModel()

            let snapshot = await fixture.manager.snapshot()
            let loadedName = await fixture.session.loadedName()
            try expectEqual(snapshot.activeModelID, .kokoro, "active model")
            try expectEqual(snapshot.runtimeState, .ready(.kokoro), "runtime state")
            try expectEqual(loadedName, "Kokoro", "loaded directory")
        },
        TestCase(name: "model manager restores the prior model after failed activation") {
            let fixture = try ModelManagerFixture(failingDirectoryNames: ["Fixture"])
            defer { fixture.remove() }
            await fixture.manager.warmConfiguredModel()

            do {
                try await fixture.manager.activate(.fixture)
                throw TestFailure(description: "activation should fail")
            } catch is ModelManagerError {}

            let snapshot = await fixture.manager.snapshot()
            let loadedName = await fixture.session.loadedName()
            try expectEqual(snapshot.activeModelID, .kokoro, "restored active model")
            try expectEqual(snapshot.runtimeState, .ready(.kokoro), "restored runtime")
            try expectEqual(loadedName, "Kokoro", "restored session")
        },
        TestCase(name: "model manager rejects activation during direct synthesis") {
            let fixture = try ModelManagerFixture()
            defer { fixture.remove() }
            await fixture.manager.warmConfiguredModel()
            let manager = fixture.manager
            let speech = Task {
                try await manager.synthesize(
                    SpeechRequest(
                        input: "hold",
                        voice: nil,
                        languageCode: nil,
                        speed: 1,
                        format: .wav
                    )
                )
            }
            await fixture.session.waitUntilSynthesisStarts()

            do {
                try await fixture.manager.activate(.fixture)
                throw TestFailure(description: "activation should be blocked")
            } catch let error as ModelManagerError {
                try expectEqual(error, .speechActive, "manager error")
            }

            await fixture.session.unblock()
            _ = try await speech.value
        },
        TestCase(name: "model manager restores per-model preferences") {
            let fixture = try ModelManagerFixture()
            defer { fixture.remove() }
            await fixture.manager.warmConfiguredModel()
            let preference = ModelPreference(
                modelID: .fixture,
                voiceID: nil,
                languageCode: nil,
                synthesisSpeed: 1.25
            )

            try await fixture.manager.updatePreferences(preference)
            try await fixture.manager.activate(.fixture)

            let snapshot = await fixture.manager.snapshot()
            try expectEqual(snapshot.activePreferences, preference, "active preferences")
        },
        TestCase(name: "model manager repairs a removed saved voice") {
            let fixture = try ModelManagerFixture(savedVoiceID: "removed_voice")
            defer { fixture.remove() }

            await fixture.manager.warmConfiguredModel()

            let snapshot = await fixture.manager.snapshot()
            let request = await fixture.session.lastRequest()
            try expectEqual(
                snapshot.activePreferences?.voiceID,
                CuratedModelDefinition.kokoro.defaultVoiceID,
                "repaired preference"
            )
            try expectEqual(
                request?.voice,
                CuratedModelDefinition.kokoro.defaultVoiceID,
                "warm-up voice"
            )
        },
        TestCase(name: "model manager gives local Qwen the standard curated controls") {
            let fixture = try ModelManagerFixture(localRuntime: .qwen3CustomVoice)
            defer { fixture.remove() }

            await fixture.manager.warmConfiguredModel()

            let snapshot = await fixture.manager.snapshot()
            let request = await fixture.session.lastRequest()
            let local = snapshot.models.first { $0.id == .local }
            try expectEqual(snapshot.activeModelID, .local, "active local model")
            try expectEqual(request?.voice, "Ryan", "local Qwen voice")
            try expectEqual(request?.languageCode, "English", "local Qwen language")
            try expectEqual(local?.languages.map(\.code), ["en", "fr"], "local languages")
        },
    ]
}

private final class ModelManagerFixture {
    let rootURL: URL
    let session: ManagerTestSession
    let manager: ModelManager

    init(
        failingDirectoryNames: Set<String> = [],
        savedVoiceID: String? = nil,
        localRuntime: MLXRuntimeProfile? = nil
    ) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let kokoroURL = rootURL.appendingPathComponent("Kokoro", isDirectory: true)
        let fixtureURL = rootURL.appendingPathComponent("Fixture", isDirectory: true)
        let localURL = rootURL.appendingPathComponent("Local", isDirectory: true)
        try FileManager.default.createDirectory(at: kokoroURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        let fixtureModel = CuratedModelDefinition(
            id: .fixture,
            displayName: "Fixture",
            repository: "example/fixture",
            revision: "revision-1",
            distribution: .downloadable,
            runtimeProfile: .kokoro,
            downloadSize: 1,
            requiredAssets: [],
            languages: [],
            defaultVoiceID: nil,
            defaultLanguageCode: nil,
            defaultSynthesisSpeed: 1
        )
        let catalog = try CuratedModelCatalog(models: [.kokoro, fixtureModel])
        var locations: [ModelID: ModelLocation] = [
                .kokoro: .bundled(kokoroURL),
                .fixture: .managed(fixtureURL),
        ]
        var profiles: [ModelID: MLXRuntimeProfile] = [
            .kokoro: .kokoro,
            .fixture: .kokoro,
        ]
        if let localRuntime {
            locations[.local] = .local(localURL)
            profiles[.local] = localRuntime
        }
        let library = ManagerTestLibrary(locations: locations, profiles: profiles)
        let modelSession = ManagerTestSession(failingDirectoryNames: failingDirectoryNames)
        session = modelSession
        let configurationURL = rootURL.appendingPathComponent("config.json")
        var configuration = AppConfiguration.default(modelDirectory: rootURL)
        if localRuntime != nil {
            configuration.activeModelID = .local
        }
        if let savedVoiceID {
            configuration.setPreferences(
                ModelPreference(
                    modelID: .kokoro,
                    voiceID: savedVoiceID,
                    languageCode: "en",
                    synthesisSpeed: 1
                )
            )
        }
        try AppConfigurationStore().save(configuration, at: configurationURL)
        manager = ModelManager(
            catalog: catalog,
            library: library,
            session: modelSession,
            activityGate: ReadBackActivityGate(),
            configuration: configuration,
            configurationURL: configurationURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private extension ModelID {
    static let fixture = ModelID(rawValue: "fixture")
}
