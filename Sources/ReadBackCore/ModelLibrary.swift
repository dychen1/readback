import CryptoKit
import Foundation

private struct ModelInstallJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let modelID: ModelID
    let revision: String

    init(modelID: ModelID, revision: String) {
        schemaVersion = 1
        self.modelID = modelID
        self.revision = revision
    }
}

public protocol ModelDiskSpaceProviding: Sendable {
    func availableBytes(at url: URL) throws -> Int64
}

public struct DefaultModelDiskSpaceProvider: ModelDiskSpaceProviding {
    public init() {}

    public func availableBytes(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}

public protocol ModelDirectoryValidating: Sendable {
    func validateModel(at directory: URL, runtimeKind: SpeechRuntimeKind) async throws
}

public struct NoOpModelDirectoryValidator: ModelDirectoryValidating {
    public init() {}

    public func validateModel(at directory: URL, runtimeKind: SpeechRuntimeKind) async throws {}
}

public struct ModelLibraryPaths: Equatable, Sendable {
    public let managedModelsURL: URL
    public let downloadsURL: URL
    public let localRegistrationURL: URL

    public init(
        managedModelsURL: URL,
        downloadsURL: URL,
        localRegistrationURL: URL
    ) {
        self.managedModelsURL = managedModelsURL.standardizedFileURL
        self.downloadsURL = downloadsURL.standardizedFileURL
        self.localRegistrationURL = localRegistrationURL.standardizedFileURL
    }
}

public enum ModelLocation: Equatable, Sendable {
    case bundled(URL)
    case managed(URL)
    case local(URL)

    public var directoryURL: URL {
        switch self {
        case .bundled(let url), .managed(let url), .local(let url): url
        }
    }
}

public enum ModelStorageState: Equatable, Sendable {
    case bundled
    case notInstalled
    case downloading(progress: Double)
    case installed
    case localAvailable
    case localMissing
    case invalid(reason: String)
}

public enum ModelLibraryError: Error, Equatable, Sendable {
    case unknownModel(ModelID)
    case notInstalled(ModelID)
    case bundledModelCannotBeRemoved
    case activeDownload
    case localDirectoryMissing
    case unsupportedLocalModel
    case integrityCheckFailed(ModelID, path: String)
    case invalidDownloadURL(ModelID, path: String)
    case downloadCleanupFailed(ModelID)
    case insufficientDiskSpace(required: Int64, available: Int64)
}

public protocol ModelLibraryProtocol: Sendable {
    func storageState(for id: ModelID) async -> ModelStorageState
    func location(for id: ModelID) async throws -> ModelLocation
    func runtimeProfile(for id: ModelID) async throws -> MLXRuntimeProfile
    func displayName(for id: ModelID) async -> String?
    func isLanguageInstalled(_ code: String, for id: ModelID) async -> Bool
    func install(_ id: ModelID) async throws
    func install(
        _ id: ModelID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws
    func cancelInstallation() async
    func installLanguage(_ code: String, for id: ModelID) async throws
    func registerLocalModel(at directory: URL) async throws
    func remove(_ id: ModelID) async throws
}

public extension ModelLibraryProtocol {
    func displayName(for id: ModelID) async -> String? { nil }

    func install(
        _ id: ModelID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        try await install(id)
        await progress(1)
    }

    func cancelInstallation() async {}
}

public actor ModelLibrary: ModelLibraryProtocol {
    private let catalog: CuratedModelCatalog
    private let paths: ModelLibraryPaths
    private let bundledModels: [ModelID: URL]
    private let downloader: any ModelAssetDownloading
    private let diskSpaceProvider: any ModelDiskSpaceProviding
    private let validator: any ModelDirectoryValidating
    private let fileManager: FileManager
    private let localStore: LocalModelRegistrationStore
    private var activeDownloadID: ModelID?
    private var activeDownloadProgress = 0.0
    private var accessedLocalURL: URL?

    public init(
        catalog: CuratedModelCatalog,
        paths: ModelLibraryPaths,
        bundledModels: [ModelID: URL],
        downloader: any ModelAssetDownloading = URLSessionModelAssetDownloader(),
        diskSpaceProvider: any ModelDiskSpaceProviding = DefaultModelDiskSpaceProvider(),
        validator: any ModelDirectoryValidating = NoOpModelDirectoryValidator(),
        fileManager: FileManager = .default
    ) {
        self.catalog = catalog
        self.paths = paths
        self.bundledModels = bundledModels.mapValues(\.standardizedFileURL)
        self.downloader = downloader
        self.diskSpaceProvider = diskSpaceProvider
        self.validator = validator
        self.fileManager = fileManager
        localStore = LocalModelRegistrationStore(fileURL: paths.localRegistrationURL)
        Self.reconcileDownloadOperations(
            catalog: catalog,
            paths: paths,
            fileManager: fileManager
        )
    }

    public func storageState(for id: ModelID) async -> ModelStorageState {
        if id == .local {
            do {
                guard let directory = try localStore.resolve() else { return .notInstalled }
                return fileManager.fileExists(atPath: directory.path)
                    ? .localAvailable
                    : .localMissing
            } catch {
                return .invalid(reason: error.localizedDescription)
            }
        }
        guard let model = try? catalog.model(id: id) else { return .notInstalled }
        if model.distribution == .bundled {
            guard let directory = bundledModels[id] else { return .notInstalled }
            return assetsExist(model.requiredAssets, under: directory)
                ? .bundled
                : .notInstalled
        }
        if activeDownloadID == id {
            return .downloading(progress: activeDownloadProgress)
        }
        let directory = managedDirectory(for: model)
        return assetsExist(model.requiredAssets, under: directory) ? .installed : .notInstalled
    }

    public func location(for id: ModelID) async throws -> ModelLocation {
        if id == .local {
            let registration = try localStore.load()
            guard let directory = try localStore.resolve() else {
                throw ModelLibraryError.notInstalled(id)
            }
            guard fileManager.fileExists(atPath: directory.path) else {
                throw ModelLibraryError.localDirectoryMissing
            }
            if registration?.usesSecurityScope == true, accessedLocalURL != directory {
                accessedLocalURL?.stopAccessingSecurityScopedResource()
                guard directory.startAccessingSecurityScopedResource() else {
                    throw ModelLibraryError.localDirectoryMissing
                }
                accessedLocalURL = directory
            }
            return .local(directory)
        }
        let model: CuratedModelDefinition
        do {
            model = try catalog.model(id: id)
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
        if model.distribution == .bundled {
            guard let directory = bundledModels[id],
                  assetsExist(model.requiredAssets, under: directory)
            else { throw ModelLibraryError.notInstalled(id) }
            return .bundled(directory)
        }
        let directory = managedDirectory(for: model)
        guard assetsExist(model.requiredAssets, under: directory) else {
            throw ModelLibraryError.notInstalled(id)
        }
        return .managed(directory)
    }

    public func runtimeProfile(for id: ModelID) async throws -> MLXRuntimeProfile {
        if id == .local {
            guard let registration = try localStore.load() else {
                throw ModelLibraryError.notInstalled(id)
            }
            return registration.runtimeProfile
        }
        do {
            return try catalog.model(id: id).runtimeProfile
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
    }

    public func displayName(for id: ModelID) async -> String? {
        guard id == .local else { return nil }
        return try? localStore.load()?.displayName
    }

    public func isLanguageInstalled(_ code: String, for id: ModelID) async -> Bool {
        guard let model = try? catalog.model(id: id),
              let language = model.languages.first(where: { $0.code == code })
        else { return false }
        switch language.distribution {
        case .bundled, .includedWithModel:
            return true
        case .downloadable:
            let root = managedDirectory(for: model)
                .appendingPathComponent("Languages", isDirectory: true)
                .appendingPathComponent(code, isDirectory: true)
            return assetsExist(language.requiredAssets, under: root)
        }
    }

    public func install(_ id: ModelID) async throws {
        try await install(id) { _ in }
    }

    public func install(
        _ id: ModelID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let model: CuratedModelDefinition
        do {
            model = try catalog.model(id: id)
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
        guard model.distribution == .downloadable else { return }
        guard activeDownloadID == nil else { throw ModelLibraryError.activeDownload }
        try fileManager.createDirectory(at: paths.downloadsURL, withIntermediateDirectories: true)
        let operation = try resumableOperation(for: model)
        let operationURL = operation.url
        let stagedModelURL = operationURL.appendingPathComponent("model", isDirectory: true)
        let remainingBytes = model.requiredAssets.reduce(Int64(0)) { total, asset in
            let assetURL = stagedModelURL.appendingPathComponent(asset.relativePath)
            return total + ((try? validate(asset, at: assetURL)) == true ? 0 : asset.byteCount)
        }
        let availableBytes = try diskSpaceProvider.availableBytes(at: paths.downloadsURL)
        let requiredBytes = remainingBytes + max(model.downloadSize / 10, 500_000_000)
        guard availableBytes >= requiredBytes else {
            if operation.isNew {
                try? fileManager.removeItem(at: operationURL)
            }
            throw ModelLibraryError.insufficientDiskSpace(
                required: requiredBytes,
                available: availableBytes
            )
        }
        activeDownloadID = id
        activeDownloadProgress = 0
        defer {
            activeDownloadID = nil
            activeDownloadProgress = 0
        }

        do {
            try await download(
                model.requiredAssets,
                for: model,
                to: stagedModelURL,
                progress: { [weak self] value in
                    guard let self else { return }
                    await self.updateDownloadProgress(value, handler: progress)
                }
            )
        } catch {
            if error is CancellationError || Self.isNonResumableDownloadError(error) {
                try? fileManager.removeItem(at: operationURL)
            }
            throw error
        }
        do {
            try await validator.validateModel(
                at: stagedModelURL,
                runtimeKind: model.runtimeKind
            )
            let destination = managedDirectory(for: model)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: stagedModelURL, to: destination)
            try fileManager.removeItem(at: operationURL)
            guard !fileManager.fileExists(atPath: operationURL.path) else {
                throw ModelLibraryError.downloadCleanupFailed(id)
            }
        } catch {
            try? fileManager.removeItem(at: operationURL)
            throw error
        }
        await updateDownloadProgress(1, handler: progress)
    }

    public func cancelInstallation() async {
        await downloader.cancel()
    }

    public func installLanguage(_ code: String, for id: ModelID) async throws {
        let model: CuratedModelDefinition
        do {
            model = try catalog.model(id: id)
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
        guard let language = model.languages.first(where: { $0.code == code }) else {
            throw ModelLibraryError.unknownModel(id)
        }
        guard language.distribution == .downloadable else { return }
        do {
            _ = try await location(for: id)
        } catch {
            throw ModelLibraryError.notInstalled(id)
        }
        guard activeDownloadID == nil else { throw ModelLibraryError.activeDownload }
        activeDownloadID = id
        defer { activeDownloadID = nil }

        let operationURL = paths.downloadsURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let stagedURL = operationURL.appendingPathComponent("language", isDirectory: true)
        defer { try? fileManager.removeItem(at: operationURL) }
        try await download(
            language.requiredAssets,
            for: model,
            to: stagedURL,
            progress: { _ in }
        )

        let modelRoot = managedDirectory(for: model)
        let destination = modelRoot
            .appendingPathComponent("Languages", isDirectory: true)
            .appendingPathComponent(code, isDirectory: true)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedURL, to: destination)
        try publishLanguageVoices(from: destination, for: id)
    }

    public func registerLocalModel(at directory: URL) async throws {
        let resolved = directory.standardizedFileURL
        guard fileManager.fileExists(atPath: resolved.path) else {
            throw ModelLibraryError.localDirectoryMissing
        }
        let profile = try detectRuntimeProfile(in: resolved)
        accessedLocalURL?.stopAccessingSecurityScopedResource()
        accessedLocalURL = nil
        try localStore.save(directory: resolved, profile: profile)
    }

    public func remove(_ id: ModelID) async throws {
        if id == .local {
            accessedLocalURL?.stopAccessingSecurityScopedResource()
            accessedLocalURL = nil
            try localStore.remove()
            return
        }
        let model: CuratedModelDefinition
        do {
            model = try catalog.model(id: id)
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
        guard model.distribution != .bundled else {
            throw ModelLibraryError.bundledModelCannotBeRemoved
        }
        let directory = managedDirectory(for: model)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func managedDirectory(for model: CuratedModelDefinition) -> URL {
        paths.managedModelsURL
            .appendingPathComponent(model.id.rawValue, isDirectory: true)
            .appendingPathComponent(model.revision, isDirectory: true)
            .standardizedFileURL
    }

    private func publishLanguageVoices(from languageURL: URL, for id: ModelID) throws {
        guard let modelURL = bundledModels[id] else { return }
        let sourceURL = languageURL.appendingPathComponent("voices", isDirectory: true)
        guard let voices = try? fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let targetURL = modelURL.appendingPathComponent("voices", isDirectory: true)
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        for voice in voices where voice.pathExtension == "safetensors" {
            let target = targetURL.appendingPathComponent(voice.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.createSymbolicLink(at: target, withDestinationURL: voice)
        }
    }

    private func assetsExist(_ assets: [ModelAssetDefinition], under root: URL) -> Bool {
        guard fileManager.fileExists(atPath: root.path) else { return false }
        return assets.allSatisfy { asset in
            let url = root.appendingPathComponent(asset.relativePath)
            guard fileManager.fileExists(atPath: url.path),
                  let values = try? url.resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.fileSizeKey])
            else { return false }
            return Int64(values.fileSize ?? -1) == asset.byteCount
        }
    }

    private func download(
        _ assets: [ModelAssetDefinition],
        for model: CuratedModelDefinition,
        to root: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let totalBytes = assets.reduce(Int64(0)) { $0 + $1.byteCount }
        var completedBytes: Int64 = 0
        await progress(0)
        for asset in assets {
            let destination = root.appendingPathComponent(asset.relativePath)
            if (try? validate(asset, at: destination)) == true {
                completedBytes += asset.byteCount
                if totalBytes > 0 {
                    await progress(Double(completedBytes) / Double(totalBytes))
                }
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            let source = try sourceURL(for: asset, model: model)
            let completedBeforeAsset = completedBytes
            try await downloader.download(
                from: source,
                to: destination,
                progress: { assetProgress in
                    guard totalBytes > 0 else {
                        await progress(1)
                        return
                    }
                    let received = min(asset.byteCount, max(0, assetProgress.bytesReceived))
                    await progress(
                        Double(completedBeforeAsset + received) / Double(totalBytes)
                    )
                }
            )
            guard try validate(asset, at: destination) else {
                throw ModelLibraryError.integrityCheckFailed(
                    model.id,
                    path: asset.relativePath
                )
            }
            completedBytes += asset.byteCount
            if totalBytes > 0 {
                await progress(Double(completedBytes) / Double(totalBytes))
            }
        }
    }

    private func resumableOperation(
        for model: CuratedModelDefinition
    ) throws -> (url: URL, isNew: Bool) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: paths.downloadsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        for entry in entries {
            let journalURL = entry.appendingPathComponent("operation.json")
            guard let data = try? Data(contentsOf: journalURL),
                  let journal = try? decoder.decode(ModelInstallJournal.self, from: data),
                  journal == ModelInstallJournal(modelID: model.id, revision: model.revision)
            else { continue }
            return (entry, false)
        }

        let operationURL = paths.downloadsURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: operationURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(
            ModelInstallJournal(modelID: model.id, revision: model.revision)
        )
        try data.write(
            to: operationURL.appendingPathComponent("operation.json"),
            options: .atomic
        )
        return (operationURL, true)
    }

    private static func reconcileDownloadOperations(
        catalog: CuratedModelCatalog,
        paths: ModelLibraryPaths,
        fileManager: FileManager
    ) {
        try? fileManager.createDirectory(at: paths.downloadsURL, withIntermediateDirectories: true)
        let entries = (try? fileManager.contentsOfDirectory(
            at: paths.downloadsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        var retainedModels = Set<ModelID>()

        for entry in entries {
            let journalURL = entry.appendingPathComponent("operation.json")
            guard let data = try? Data(contentsOf: journalURL),
                  let journal = try? decoder.decode(ModelInstallJournal.self, from: data),
                  journal.schemaVersion == 1,
                  let model = try? catalog.model(id: journal.modelID),
                  model.distribution == .downloadable,
                  model.revision == journal.revision,
                  !retainedModels.contains(model.id)
            else {
                try? fileManager.removeItem(at: entry)
                continue
            }

            let destination = paths.managedModelsURL
                .appendingPathComponent(model.id.rawValue, isDirectory: true)
                .appendingPathComponent(model.revision, isDirectory: true)
            let finalIsComplete = model.requiredAssets.allSatisfy { asset in
                let url = destination.appendingPathComponent(asset.relativePath)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    return false
                }
                return Int64(size) == asset.byteCount
            }
            let stagedModel = entry.appendingPathComponent("model", isDirectory: true)
            guard !finalIsComplete, fileManager.fileExists(atPath: stagedModel.path) else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            retainedModels.insert(model.id)
        }
    }

    private static func isNonResumableDownloadError(_ error: Error) -> Bool {
        guard let libraryError = error as? ModelLibraryError else { return false }
        return switch libraryError {
        case .integrityCheckFailed, .invalidDownloadURL:
            true
        default:
            false
        }
    }

    private func updateDownloadProgress(
        _ value: Double,
        handler: @escaping @Sendable (Double) async -> Void
    ) async {
        activeDownloadProgress = min(1, max(0, value))
        await handler(activeDownloadProgress)
    }

    private func sourceURL(
        for asset: ModelAssetDefinition,
        model: CuratedModelDefinition
    ) throws -> URL {
        if let explicit = asset.downloadURL { return explicit }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(model.repository)/resolve/\(model.revision)/\(asset.relativePath)"
        guard let url = components.url else {
            throw ModelLibraryError.invalidDownloadURL(
                model.id,
                path: asset.relativePath
            )
        }
        return url
    }

    private func validate(_ asset: ModelAssetDefinition, at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == asset.byteCount else { return false }
        return try sha256(of: url) == asset.sha256.lowercased()
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func detectRuntimeProfile(in directory: URL) throws -> MLXRuntimeProfile {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ModelLibraryError.unsupportedLocalModel }
        let modelType = (object["model_type"] as? String)?.lowercased()
        let isKokoro = modelType == "kokoro"
            || (object["istftnet"] != nil && object["plbert"] != nil)
        let qwenMode = (object["tts_model_type"] as? String)?.lowercased()
        let isQwenCustomVoice = modelType == "qwen3_tts" && qwenMode == "custom_voice"
        let isChatterboxTurbo = modelType == "chatterbox_turbo"
        guard isKokoro || isQwenCustomVoice || isChatterboxTurbo else {
            throw ModelLibraryError.unsupportedLocalModel
        }
        guard containsWeights(in: directory) else {
            throw ModelLibraryError.unsupportedLocalModel
        }
        if isKokoro { return .kokoro }
        if isQwenCustomVoice { return .qwen3CustomVoice }
        return .chatterboxTurbo
    }

    private func containsWeights(in directory: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "safetensors" {
            return true
        }
        return false
    }
}
