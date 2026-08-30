import CryptoKit
import Foundation
import ReadBackCore

private actor FixtureModelDownloader: ModelAssetDownloading {
    enum Behavior: Sendable {
        case success
        case cancel
        case failOnce
    }

    private let dataByFilename: [String: Data]
    private let behavior: Behavior
    private var hasFailed = false

    init(dataByFilename: [String: Data], behavior: Behavior = .success) {
        self.dataByFilename = dataByFilename
        self.behavior = behavior
    }

    func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        switch behavior {
        case .success:
            break
        case .cancel:
            throw CancellationError()
        case .failOnce where !hasFailed:
            hasFailed = true
            throw URLError(.networkConnectionLost)
        case .failOnce:
            break
        }
        guard let data = dataByFilename[source.lastPathComponent] else {
            throw TestFailure(description: "missing fixture for \(source.lastPathComponent)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
        await progress(
            ModelDownloadProgress(
                bytesReceived: Int64(data.count),
                totalBytes: Int64(data.count)
            )
        )
    }
}

private actor InstallProgressRecorder {
    private var values: [Double] = []

    func record(_ value: Double) { values.append(value) }
    func recordedValues() -> [Double] { values }
}

private struct FixtureDiskSpaceProvider: ModelDiskSpaceProviding {
    let availableBytes: Int64

    func availableBytes(at url: URL) throws -> Int64 { availableBytes }
}

private actor FixtureModelDirectoryValidator: ModelDirectoryValidating {
    private var runtimeKinds: [SpeechRuntimeKind] = []

    func validateModel(at directory: URL, runtimeKind: SpeechRuntimeKind) async throws {
        runtimeKinds.append(runtimeKind)
    }

    func validatedRuntimeKinds() -> [SpeechRuntimeKind] { runtimeKinds }
}

func modelLibraryTests() -> [TestCase] {
    [
        TestCase(name: "model library publishes a download only after hash validation") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }

            try await fixture.library.install(.fixture)

            let expected = fixture.managedModelsURL
                .appendingPathComponent("fixture/revision-1", isDirectory: true)
            let location = try await fixture.library.location(for: .fixture)
            let state = await fixture.library.storageState(for: .fixture)
            try expectEqual(
                location,
                .managed(expected),
                "installed location"
            )
            try expectEqual(
                state,
                .installed,
                "installed state"
            )
            let remainingDownloads = try FileManager.default.contentsOfDirectory(
                at: fixture.downloadsURL,
                includingPropertiesForKeys: nil
            )
            try expect(
                remainingDownloads.isEmpty,
                "successful install must clean the download directory"
            )
        },
        TestCase(name: "model library reports aggregate install progress") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }
            let recorder = InstallProgressRecorder()

            try await fixture.library.install(.fixture) { progress in
                await recorder.record(progress)
            }

            let values = await recorder.recordedValues()
            try expect(!values.isEmpty, "install should report progress")
            try expectEqual(values.last, 1, "install should finish at one")
        },
        TestCase(name: "model library keeps a retry journal after network interruption") {
            let fixture = try ModelLibraryFixture(
                validHash: true,
                downloadBehavior: .failOnce
            )
            defer { fixture.remove() }

            do {
                try await fixture.library.install(.fixture)
                throw TestFailure(description: "first install should be interrupted")
            } catch is URLError {}

            let interrupted = try FileManager.default.contentsOfDirectory(
                at: fixture.downloadsURL,
                includingPropertiesForKeys: nil
            )
            try expectEqual(interrupted.count, 1, "one retry operation")
            try expect(
                FileManager.default.fileExists(
                    atPath: interrupted[0].appendingPathComponent("operation.json").path
                ),
                "retry operation should contain a journal"
            )

            try await fixture.library.install(.fixture)
            let remaining = try FileManager.default.contentsOfDirectory(
                at: fixture.downloadsURL,
                includingPropertiesForKeys: nil
            )
            try expect(remaining.isEmpty, "successful retry should clean its operation")
        },
        TestCase(name: "model library removes a cancelled operation") {
            let fixture = try ModelLibraryFixture(
                validHash: true,
                downloadBehavior: .cancel
            )
            defer { fixture.remove() }

            do {
                try await fixture.library.install(.fixture)
                throw TestFailure(description: "install should be cancelled")
            } catch is CancellationError {}

            let remaining = try FileManager.default.contentsOfDirectory(
                at: fixture.downloadsURL,
                includingPropertiesForKeys: nil
            )
            try expect(remaining.isEmpty, "cancelled install should remove its operation")
        },
        TestCase(name: "model library removes stale download operations on launch") {
            let fixture = try ModelLibraryFixture(validHash: true, createStaleDownload: true)
            defer { fixture.remove() }

            let remaining = try FileManager.default.contentsOfDirectory(
                at: fixture.downloadsURL,
                includingPropertiesForKeys: nil
            )
            try expect(remaining.isEmpty, "stale download should be removed")
        },
        TestCase(name: "model library rejects install without enough disk space") {
            let fixture = try ModelLibraryFixture(validHash: true, availableBytes: 0)
            defer { fixture.remove() }

            do {
                try await fixture.library.install(.fixture)
                throw TestFailure(description: "install should reject low disk space")
            } catch let error as ModelLibraryError {
                try expectEqual(
                    error,
                    .insufficientDiskSpace(required: 500_000_023, available: 0),
                    "disk-space error"
                )
            }
            let remaining = try FileManager.default.contentsOfDirectory(
                at: fixture.downloadsURL,
                includingPropertiesForKeys: nil
            )
            try expect(remaining.isEmpty, "disk rejection should not leave an operation")
        },
        TestCase(name: "model library validates the staged runtime before publication") {
            let validator = FixtureModelDirectoryValidator()
            let fixture = try ModelLibraryFixture(validHash: true, validator: validator)
            defer { fixture.remove() }

            try await fixture.library.install(.fixture)

            let runtimeKinds = await validator.validatedRuntimeKinds()
            try expectEqual(runtimeKinds, [.kokoro], "validated runtime kinds")
        },
        TestCase(name: "model library rejects a bad asset hash") {
            let fixture = try ModelLibraryFixture(validHash: false)
            defer { fixture.remove() }

            do {
                try await fixture.library.install(.fixture)
                throw TestFailure(description: "invalid hash should fail")
            } catch let error as ModelLibraryError {
                try expectEqual(
                    error,
                    .integrityCheckFailed(.fixture, path: "config.json"),
                    "integrity error"
                )
            }

            let state = await fixture.library.storageState(for: .fixture)
            try expectEqual(
                state,
                .notInstalled,
                "failed install state"
            )
            let remaining = try FileManager.default.contentsOfDirectory(
                atPath: fixture.downloadsURL.path
            )
            try expect(remaining.isEmpty, "failed download should remove temporary files")
        },
        TestCase(name: "model library resolves bundled Kokoro") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }

            let location = try await fixture.library.location(for: .kokoro)
            let state = await fixture.library.storageState(for: .kokoro)
            try expectEqual(
                location,
                .bundled(fixture.bundledKokoroURL),
                "bundled location"
            )
            try expectEqual(
                state,
                .bundled,
                "bundled state"
            )
        },
        TestCase(name: "model library validates bundled assets through runtime links") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }
            let linkedConfig = fixture.bundledKokoroURL.appendingPathComponent("config.json")
            let sourceConfig = fixture.rootURL.appendingPathComponent("bundled-config.json")
            try FileManager.default.moveItem(at: linkedConfig, to: sourceConfig)
            try FileManager.default.createSymbolicLink(
                at: linkedConfig,
                withDestinationURL: sourceConfig
            )

            let state = await fixture.library.storageState(for: .kokoro)

            try expectEqual(state, .bundled, "linked bundled state")
        },
        TestCase(name: "language install requires its model to be installed") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }

            do {
                try await fixture.library.installLanguage("es", for: .fixture)
                throw TestFailure(description: "language install should require its model")
            } catch let error as ModelLibraryError {
                try expectEqual(error, .notInstalled(.fixture), "missing model error")
            }
        },
        TestCase(name: "language install publishes its complete asset set") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }

            try await fixture.library.install(.fixture)
            try await fixture.library.installLanguage("es", for: .fixture)

            let languageVoice = fixture.managedModelsURL
                .appendingPathComponent(
                    "fixture/revision-1/Languages/es/voices/es_voice.safetensors"
                )
            try expect(
                FileManager.default.fileExists(atPath: languageVoice.path),
                "language asset should appear only after install"
            )
        },
        TestCase(name: "removing local registration leaves user files") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }
            let local = fixture.rootURL.appendingPathComponent("Local Kokoro", isDirectory: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try Data(#"{"istftnet":{},"plbert":{}}"#.utf8)
                .write(to: local.appendingPathComponent("config.json"))
            try Data([0x01]).write(to: local.appendingPathComponent("weights.safetensors"))

            try await fixture.library.registerLocalModel(at: local)
            let location = try await fixture.library.location(for: .local)
            try expectEqual(
                location,
                .local(local),
                "local location"
            )

            try await fixture.library.remove(.local)
            let state = await fixture.library.storageState(for: .local)

            try expect(
                FileManager.default.fileExists(atPath: local.path),
                "local files must remain"
            )
            try expectEqual(
                state,
                .notInstalled,
                "local registration removed"
            )
        },
        TestCase(name: "local model detection accepts Qwen CustomVoice") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }
            let local = fixture.rootURL.appendingPathComponent("Local Qwen", isDirectory: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try Data(
                #"{"model_type":"qwen3_tts","tts_model_type":"custom_voice"}"#.utf8
            ).write(to: local.appendingPathComponent("config.json"))
            try Data([0x01]).write(to: local.appendingPathComponent("model.safetensors"))

            try await fixture.library.registerLocalModel(at: local)

            let profile = try await fixture.library.runtimeProfile(for: .local)
            try expectEqual(profile, .qwen3CustomVoice, "local runtime kind")
        },
        TestCase(name: "local model detection rejects Qwen Base") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }
            let local = fixture.rootURL.appendingPathComponent("Local Qwen Base", isDirectory: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try Data(
                #"{"model_type":"qwen3_tts","tts_model_type":"base"}"#.utf8
            ).write(to: local.appendingPathComponent("config.json"))
            try Data([0x01]).write(to: local.appendingPathComponent("model.safetensors"))

            do {
                try await fixture.library.registerLocalModel(at: local)
                throw TestFailure(description: "Qwen Base should fail")
            } catch let error as ModelLibraryError {
                try expectEqual(error, .unsupportedLocalModel, "local error")
            }
        },
        TestCase(name: "local model detection accepts Chatterbox Turbo") {
            let fixture = try ModelLibraryFixture(validHash: true)
            defer { fixture.remove() }
            let local = fixture.rootURL.appendingPathComponent(
                "Local Chatterbox Turbo",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try Data(#"{"model_type":"chatterbox_turbo"}"#.utf8)
                .write(to: local.appendingPathComponent("config.json"))
            try Data([0x01]).write(to: local.appendingPathComponent("model.safetensors"))

            try await fixture.library.registerLocalModel(at: local)

            let profile = try await fixture.library.runtimeProfile(for: .local)
            try expectEqual(profile, .chatterboxTurbo, "local runtime kind")
        },
    ]
}

private final class ModelLibraryFixture {
    let rootURL: URL
    let bundledKokoroURL: URL
    let managedModelsURL: URL
    let downloadsURL: URL
    let library: ModelLibrary

    init(
        validHash: Bool,
        availableBytes: Int64? = nil,
        validator: any ModelDirectoryValidating = NoOpModelDirectoryValidator(),
        downloadBehavior: FixtureModelDownloader.Behavior = .success,
        createStaleDownload: Bool = false
    ) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        bundledKokoroURL = rootURL.appendingPathComponent("BundledKokoro", isDirectory: true)
        managedModelsURL = rootURL.appendingPathComponent("Models", isDirectory: true)
        downloadsURL = rootURL.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundledKokoroURL,
            withIntermediateDirectories: true
        )
        let bundledConfig = Data("{}".utf8)
        try bundledConfig.write(to: bundledKokoroURL.appendingPathComponent("config.json"))

        let config = Data(#"{"model_type":"kokoro"}"#.utf8)
        let languageVoice = Data([0x01, 0x02, 0x03])
        let digest = SHA256.hash(data: config).map { String(format: "%02x", $0) }.joined()
        let languageDigest = SHA256.hash(data: languageVoice)
            .map { String(format: "%02x", $0) }
            .joined()
        let asset = ModelAssetDefinition(
            relativePath: "config.json",
            byteCount: Int64(config.count),
            sha256: validHash ? digest : String(repeating: "0", count: 64)
        )
        let bundledDigest = SHA256.hash(data: bundledConfig)
            .map { String(format: "%02x", $0) }
            .joined()
        let bundled = CuratedModelDefinition(
            id: .kokoro,
            displayName: "Kokoro",
            repository: "example/kokoro",
            revision: "bundled-1",
            distribution: .bundled,
            runtimeProfile: .kokoro,
            downloadSize: 0,
            requiredAssets: [
                ModelAssetDefinition(
                    relativePath: "config.json",
                    byteCount: Int64(bundledConfig.count),
                    sha256: bundledDigest
                )
            ],
            languages: [],
            defaultVoiceID: nil,
            defaultLanguageCode: nil,
            defaultSynthesisSpeed: 1
        )
        let downloadable = CuratedModelDefinition(
            id: .fixture,
            displayName: "Fixture",
            repository: "example/fixture",
            revision: "revision-1",
            distribution: .downloadable,
            runtimeProfile: .kokoro,
            downloadSize: Int64(config.count),
            requiredAssets: [asset],
            languages: [
                ModelLanguageDefinition(
                    code: "es",
                    displayName: "Spanish",
                    distribution: .downloadable,
                    requiredAssets: [
                        ModelAssetDefinition(
                            relativePath: "voices/es_voice.safetensors",
                            byteCount: Int64(languageVoice.count),
                            sha256: languageDigest
                        )
                    ],
                    voices: [
                        ModelVoiceDefinition(
                            id: "es_voice",
                            displayName: "Spanish",
                            languageCode: "e"
                        )
                    ]
                )
            ],
            defaultVoiceID: nil,
            defaultLanguageCode: nil,
            defaultSynthesisSpeed: 1
        )
        let catalog = try CuratedModelCatalog(models: [bundled, downloadable])
        let paths = ModelLibraryPaths(
            managedModelsURL: managedModelsURL,
            downloadsURL: downloadsURL,
            localRegistrationURL: rootURL.appendingPathComponent("local-model.json")
        )
        if createStaleDownload {
            let stale = downloadsURL.appendingPathComponent("stale", isDirectory: true)
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: stale.appendingPathComponent("partial.bin"))
        }
        library = ModelLibrary(
            catalog: catalog,
            paths: paths,
            bundledModels: [.kokoro: bundledKokoroURL],
            downloader: FixtureModelDownloader(
                dataByFilename: [
                    "config.json": config,
                    "es_voice.safetensors": languageVoice,
                ],
                behavior: downloadBehavior
            ),
            diskSpaceProvider: availableBytes.map {
                FixtureDiskSpaceProvider(availableBytes: $0)
            } ?? DefaultModelDiskSpaceProvider(),
            validator: validator
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private extension ModelID {
    static let fixture = ModelID(rawValue: "fixture")
}
